import { common } from '@kit.AbilityKit';
import { ComposioConfig } from '../composio/ComposioConfig';
import { ComposioSessionClient } from '../composio/ComposioSessionClient';
import { ComposioTool } from '../composio/ComposioTool';
import { SandboxFileWriteTool } from '../file/SandboxFileWriteTool';
import { SandboxFileReadTool } from '../file/SandboxFileReadTool';
import { SandboxListTool } from '../file/SandboxDirectoryTools';
import { ModelScopeConfig } from '../modelscope/ModelScopeConfig';
import { ModelScopeDirectClient } from '../modelscope/ModelScopeDirectClient';
import { ModelScopeTool } from '../modelscope/ModelScopeTool';
import { SkillReadTool } from '../skill/SkillReadTool';
import { SkillSnapshot } from '../skill/SkillSnapshot';
import { AgentTool, ToolExecutionPolicy, ToolMetadata, ToolResult, ToolExecutionContext, normalizeToolResult } from './AgentTool';
import { summarizeA2uiObservation } from './A2uiObservationDigest';
import { MapSearchTool } from './MapSearchTool';
import { AirQualityTool, WeatherTool } from './OpenMeteoTool';
import { TrainSearchTool } from './TrainSearchTool';
import { CalculatorTool, DateCalculatorTool, SandboxSearchTool, UnitConvertTool } from './LocalUtilityTools';
import { ToolContract, ToolContractCatalog } from './ToolContract';

export type ToolRegistryCloseHandler = () => Promise<void>;
interface ActiveInvocation {
  context: ToolExecutionContext;
  tool: AgentTool;
  settled: boolean;
  cancelled: boolean;
  timer: number;
  resolve: (value: string | ToolResult) => void;
}

class TimeTool implements AgentTool {
  contract(): ToolContract {
    return { version: '1', inputFormat: 'none', inputSchema: { type: 'object', additionalProperties: false }, outputSchema: { type: 'string', minLength: 1 } };
  }
  name(): string {
    return 'time';
  }

  description(): string {
    return 'Returns the device\'s local date and time.';
  }

  async run(_input: string): Promise<string> {
    return new Date().toLocaleString();
  }
}

interface QueuedWrite { callId: string; skipped: boolean; }

export class ToolRegistry {
  private closed: boolean = false;
  private invocationSerial: number = 0;
  private activeInvocations: Map<string, ActiveInvocation> = new Map();
  private contractCatalog: ToolContractCatalog = new ToolContractCatalog();
  contracts(): ToolContractCatalog { return this.contractCatalog; }
  private tools: Map<string, AgentTool> = new Map();
  private policies: Map<string, ToolExecutionPolicy> = new Map();
  private closeHandlers: ToolRegistryCloseHandler[] = [];

  constructor() {
    this.register(new TimeTool(), { readOnly: true, supportsParallel: true, cacheable: false, risk: 'low' });
  }

  register(tool: AgentTool, policy?: ToolExecutionPolicy, contract?: ToolContract): void {
    if (this.closed) { throw new Error('Tool registry is closed'); }
    if (policy?.timeoutMs !== undefined && (!Number.isInteger(policy.timeoutMs) || policy.timeoutMs < 1 || policy.timeoutMs > 300000)) { throw new Error('Invalid tool timeoutMs'); }
    this.contractCatalog.register(tool.name(), contract ?? tool.contract?.());
    this.tools.set(tool.name(), tool);
    // Registration, not a tool name/description or returned payload, owns policy.
    // Re-registering without policy must revoke previously granted privileges.
    const readOnly = policy?.readOnly === true;
    const lowRisk = policy?.risk === 'low';
    this.policies.set(tool.name(), {
      readOnly: readOnly, supportsParallel: readOnly && lowRisk && policy?.supportsParallel === true,
      cacheable: readOnly && lowRisk && policy?.cacheable === true, risk: policy?.risk ?? 'high', timeoutMs: policy?.timeoutMs ?? 60000
    });
  }

  metadata(name: string): ToolMetadata {
    const tool = this.tools.get(name);
    const policy = this.policies.get(name);
    return { name: name, description: tool?.description() ?? '',
      readOnly: policy?.readOnly ?? false, supportsParallel: policy?.supportsParallel ?? false,
      cacheable: policy?.cacheable ?? false, risk: policy?.risk ?? 'high', timeoutMs: policy?.timeoutMs ?? 60000,
      version: this.contractCatalog.get(name)?.version };
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  registerCloseHandler(handler: ToolRegistryCloseHandler): void {
    if (this.closed) { try { handler().catch((_error: Error): void => {}); } catch (_error) {} return; }
    this.closeHandlers.push(handler);
  }

  describeToolsBrief(): string {
    let description = '';
    this.tools.forEach((tool: AgentTool) => {
      description += `- ${tool.name()}: ${tool.description().replace(/\s+/g, " ").trim()}\n`;
      const schema = this.contractCatalog.get(tool.name())?.inputSchema;
      if (schema !== undefined) { description += "  Schema: " + JSON.stringify(schema) + "\n"; }
    });
    return description;
  }

  describeTools(compact: boolean = false): string {
    let description = compact ? 'Output Execution: serial|parallel, then Action: exact_tool_name[<input>]. JSON inputs are one object, never an array or input: wrapper. Required strings cannot be empty.\n' : 'Tool-call format (required):\n';
    if (!compact) {
      description += 'Execution: serial\n';
      description += 'Action: exact_tool_name[<input>]\n';
      description += 'Execution must contain only serial or parallel; put every tool call on an Action line. ';
      description += 'When a tool requires Input JSON, place exactly one JSON object inside the Action brackets, ';
      description += 'without an extra array or an input: label. Required string fields must not be empty.\n';
    }
    description += 'Available tools:\n';
    this.tools.forEach((tool: AgentTool) => {
      description += `- ${tool.name()}: ${compact ? tool.description().replace(/\s+/g, ' ').trim() : tool.description()}\n`;
      const declaration = this.contractCatalog.get(tool.name());
      if (declaration !== undefined) {
        description += '  Input format: ' + declaration.inputFormat + '. Schema: ' + JSON.stringify(declaration.inputSchema ?? {}) + '\n';
        // These are executor-side answer checks, not tool input/permission constraints.
        // Actual returned facts are provided with observations after a call completes.
        if (!compact && (declaration.evidenceFields ?? []).length > 0) { const scope = declaration.answerScopeFields ?? []; description += '  Answer evidence: ' + JSON.stringify(declaration.evidenceFields) + (scope.length > 0 ? '. Scope fields: ' + JSON.stringify(scope) : '') + '\n'; }
      }
    });
    return description;
  }

  private callSequence: number = 0;
  private writeChain: Promise<void> = Promise.resolve();
  private queuedWrites: QueuedWrite[] = [];

  /**
   * Read-only tools run concurrently. Anything that may change state runs one at a time across
   * every caller sharing this registry (parallel sub-tasks), in arrival order, and is skipped
   * if its caller is stopped while it waits.
   */
  async run(name: string, input: string, callId: string = ''): Promise<ToolResult> {
    const id = callId.length > 0 ? callId : 'dispatch-' + (++this.callSequence).toString();
    const declared = this.metadata(name);
    if (declared.readOnly === true || !this.tools.has(name)) { return this.runNow(name, input, id); }
    const entry: QueuedWrite = { callId: id, skipped: false };
    const previous = this.writeChain;
    let release: () => void = (): void => {};
    this.writeChain = new Promise<void>((resolve: () => void): void => { release = resolve; });
    this.queuedWrites.push(entry);
    try {
      await previous;
      if (entry.skipped || this.closed) {
        return { callId: id, status: 'unavailable', raw: '', displayText: '已停止工具调用', metadata: declared, returned: false, stop: true };
      }
      return await this.runNow(name, input, id);
    } finally {
      this.queuedWrites.splice(this.queuedWrites.indexOf(entry), 1);
      release();
    }
  }

  private async runNow(name: string, input: string, id: string): Promise<ToolResult> {
    const tool = this.tools.get(name);
    const metadata = this.metadata(name);
    if (this.closed) { return { callId: id, status: 'unavailable', raw: '', displayText: 'Tool registry is closed.', metadata: metadata, returned: false, stop: true }; }
    if (tool === undefined) {
      return { callId: id, status: 'unavailable', raw: `Unknown tool: ${name}`,
        displayText: `Unknown tool: ${name}`, metadata: metadata, returned: false };
    }
    const inputIssues = this.contractCatalog.validateInput({ name: name, input: input });
    if (inputIssues.length > 0) {
      const text = 'Tool input does not satisfy its contract: ' + inputIssues.join('; ');
      return { callId: id, status: 'failed', raw: text, displayText: text, metadata: metadata, returned: false };
    }
    try {
      const value = await this.invoke(tool, input ?? '', id, metadata);
      const declaration = this.contractCatalog.get(name);
      const result = normalizeToolResult(value, id, metadata, declaration?.legacyStatus);
      if (result.status === 'success' && declaration !== undefined) {
        result.data = result.data ?? declaration.legacyData?.(result.raw) ?? (declaration.outputSchema?.type === 'string' ? result.raw : undefined);
        if (declaration.outputSchema !== undefined || (declaration.evidenceFields ?? []).length > 0) {
          const outputIssues = this.contractCatalog.validateOutput(name, result.data);
          if (outputIssues.length > 0) {
            result.status = 'failed'; result.displayText = 'Tool output does not satisfy its contract: ' + outputIssues.join('; ');
            if (metadata.readOnly !== true) { result.stop = true; }
          }
        }
      }
      // Only legacy strings require the old A2UI protocol adapter. Explicit
      // typed status/stop flags are authoritative, never inferred from content.
      if (typeof value === 'string') {
        const digest = summarizeA2uiObservation(value);
        if (digest.isA2ui) {
          // Keep raw JSONL for diagnostics only; the model and trace receive the
          // bounded digest/finalText rather than protocol envelopes or credentials.
          result.displayText = digest.text;
          result.finalText = digest.finalText.length > 0 ? digest.finalText : undefined;
        }
        if (digest.shouldStop) { result.status = 'unavailable'; result.stop = true; }
      }
      return result;
    } catch (error) {
      const text = error instanceof Error ? error.message : `${error}`;
      return { callId: id, status: 'failed', raw: text, displayText: text, metadata: metadata, returned: false, stop: metadata.readOnly !== true };
    }
  }

  private invoke(tool: AgentTool, input: string, callId: string, metadata: ToolMetadata): Promise<string | ToolResult> {
    const token = 'invocation-' + (++this.invocationSerial).toString();
    const timeout = metadata.timeoutMs ?? 60000;
    return new Promise<string | ToolResult>((resolve: (value: string | ToolResult) => void, reject: (error: Error) => void): void => {
      const state: ActiveInvocation = { tool: tool, settled: false, cancelled: false, timer: -1, resolve: resolve,
        context: { callId: callId, invocationId: token, deadlineAt: Date.now() + timeout, isCancelled: (): boolean => false } };
      state.context.isCancelled = (): boolean => state.cancelled;
      this.activeInvocations.set(token, state);
      state.timer = setTimeout((): void => this.interruptInvocation(state, '工具调用超时；已开始的外部操作未必可撤销。', metadata.readOnly !== true), timeout);
      Promise.resolve().then((): Promise<string | ToolResult> => {
        if (state.settled) { return Promise.reject(new Error('Tool invocation was already cancelled')); }
        return tool.run(input, state.context);
      }).then((value: string | ToolResult): void => {
        if (state.settled) { return; }
        state.settled = true; clearTimeout(state.timer); this.activeInvocations.delete(token); resolve(value);
      }, (error: Error): void => {
        if (state.settled) { return; }
        state.settled = true; clearTimeout(state.timer); this.activeInvocations.delete(token); reject(error);
      });
    });
  }

  private interruptInvocation(state: ActiveInvocation, message: string, stop: boolean): void {
    if (state.settled) { return; }
    // Settle before calling provider cancellation: a throwing/disconnected
    // cancel hook must never strand the local caller or touch a later invocation.
    state.settled = true; state.cancelled = true; clearTimeout(state.timer);
    this.activeInvocations.delete(state.context.invocationId);
    const outcome: ToolResult = { callId: state.context.callId, status: 'failed', raw: message, displayText: message, returned: false, stop: stop };
    state.resolve(outcome);
    try { state.tool.cancel?.(state.context); } catch (_error) {
    }
  }

  cancelActive(callIdPrefix?: string): void {
    for (const queued of this.queuedWrites) {
      if (callIdPrefix === undefined || queued.callId.startsWith(callIdPrefix)) { queued.skipped = true; }
    }
    for (const state of Array.from(this.activeInvocations.values())) {
      if (callIdPrefix === undefined || state.context.callId.startsWith(callIdPrefix)) { this.interruptInvocation(state, '已停止工具调用', true); }
    }
  }

  async close(): Promise<void> {
    if (this.closed) { return; }
    this.closed = true;
    this.cancelActive();
    for (let index = 0; index < this.closeHandlers.length; index++) {
      try {
        await this.closeHandlers[index]();
      } catch (_error) {
      }
    }
  }
}

export async function createConfiguredLoopToolRegistry(
  context: common.UIAbilityContext,
  skillSnapshot?: SkillSnapshot | null
): Promise<ToolRegistry> {
  const registry = createLoopToolRegistry(skillSnapshot);
  const readPolicy: ToolExecutionPolicy = { readOnly: true, supportsParallel: true, cacheable: true, risk: 'low' };
  const serialReadPolicy: ToolExecutionPolicy = { readOnly: true, supportsParallel: false, cacheable: true, risk: 'low' };
  registry.register(new SandboxFileReadTool(context), serialReadPolicy);
  registry.register(new SandboxListTool(context), readPolicy);
  registry.register(new TrainSearchTool(), readPolicy);
  registry.register(new MapSearchTool(context), readPolicy);
  registry.register(new WeatherTool(), readPolicy);
  registry.register(new AirQualityTool(), readPolicy);
  registry.register(new CalculatorTool(), readPolicy);
  registry.register(new DateCalculatorTool(), { readOnly: true, supportsParallel: true, cacheable: false, risk: 'low' });
  registry.register(new UnitConvertTool(), readPolicy);
  registry.register(new SandboxSearchTool(context), serialReadPolicy);
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SandboxFileWriteTool(context));
  }
  const client = new ComposioSessionClient(await ComposioConfig.fromContext(context));
  try {
    await client.initialize();
  } catch (_error) {
    // Optional integrations must not prevent local/public tools from loading.
  }
  registry.register(new ComposioTool(client));
  registry.registerCloseHandler(async (): Promise<void> => client.close());
  const modelScopeConfig = await ModelScopeConfig.fromContext(context);
  const modelScopeClient = new ModelScopeDirectClient(modelScopeConfig);
  try {
    await modelScopeClient.initialize();
  } catch (_error) {
    // Optional MCP discovery must degrade to a truthful unavailable tool.
  }
  registry.register(new ModelScopeTool(modelScopeClient));
  return registry;
}

export function createLoopToolRegistry(skillSnapshot?: SkillSnapshot | null): ToolRegistry {
  const registry = new ToolRegistry();
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SkillReadTool(skillSnapshot));
  }
  return registry;
}
