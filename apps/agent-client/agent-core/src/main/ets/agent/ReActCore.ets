import { ContractCall, ContractRequirement, ContractOutcome, ContractStatus, ToolContractCatalog, inputKey } from './ToolContract';
import { TaskGoal, parseTaskGoals } from './TaskContract';
import { TaskNode, validateTaskGraph } from './TaskCoordinator';
export type ExecutionMode = 'parallel' | 'serial';
export type CoreCall = ContractCall;
export type TaskRequirement = ContractRequirement;
export type ResultLedgerEntry = ContractOutcome;
export type TaskStatus = ContractStatus;
export interface PlannedRequirement { id: string; tool: string; input: string; label: string; }
export interface CorePlan { mode: ExecutionMode; calls: CoreCall[]; error: string; discardedObservation?: boolean; requirements?: PlannedRequirement[]; goals?: TaskGoal[]; nodes?: TaskNode[]; }

// Parse the entire response before dispatch. Delimiter scanning is string-aware;
// protocol-looking text inside a JSON string is data, never another action.
export function parseCorePlan(response: string, registered: (name: string) => boolean, inputFormat: (name: string) => 'json' | 'text' | 'none' = (): 'json' => 'json'): CorePlan {
  const calls: CoreCall[] = [];
  let mode: ExecutionMode = 'serial';
  let executionDeclared = false;
  let rest = response.trim();
  const requirements: PlannedRequirement[] = [];
  let goals: TaskGoal[] = [];
  let nodes: TaskNode[] = [];
  let discardedObservation = false;
  const invalid = (): CorePlan => ({ mode: mode, calls: [], error: 'Invalid Action response: use registered tools, complete JSON objects, and no mixed Action/Final.' });
  if (/^Plan\s*:/i.test(rest)) {
    rest = rest.replace(/^Plan\s*:/i, '').trim();
    if (!rest.startsWith('{')) { return invalid(); }
    let depth = 0, quoted = false, escaped = false, end = -1;
    for (let index = 0; index < rest.length; index++) {
      const ch = rest.charAt(index);
      if (quoted) { if (escaped) { escaped = false; } else if (ch === '\\') { escaped = true; } else if (ch === '"') { quoted = false; } continue; }
      if (ch === '"') { quoted = true; continue; }
      if (ch === '{' || ch === '[') { depth++; }
      if (ch === '}' || ch === ']') { depth--; }
      if (depth === 0) { end = index; break; }
    }
    if (end < 0) { return invalid(); }
    try {
      const manifest = JSON.parse(rest.substring(0, end + 1)) as Record<string, Object>;
      if (Object.keys(manifest).some((key: string): boolean => ['requirements', 'goals', 'nodes'].indexOf(key) < 0)) { return invalid(); }
      if (manifest.goals !== undefined) {
        const checked = parseTaskGoals(manifest.goals, registered);
        if (checked.error.length > 0) { return { mode: mode, calls: [], error: checked.error }; }
        goals = checked.goals;
      }
      if (manifest.nodes !== undefined) {
        if (!Array.isArray(manifest.nodes)) { return invalid(); }
        nodes = manifest.nodes as TaskNode[];
        const errors = validateTaskGraph({ goals: goals, nodes: nodes });
        if (errors.length) { return { mode: mode, calls: [], error: errors.join('; ') }; }
      }
      if (manifest.requirements !== undefined && !Array.isArray(manifest.requirements)) { return invalid(); }
      const specs = (manifest.requirements ?? []) as Record<string, Object>[];
      if (!specs.length && !goals.length || specs.length > 64) { return invalid(); }
      for (const spec of specs) {
        if (spec === null || typeof spec !== 'object' || Array.isArray(spec) || Object.keys(spec).some((key: string): boolean => ['id', 'tool', 'input', 'label'].indexOf(key) < 0)) { return invalid(); }
        if (typeof spec.id !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(spec.id as string) || typeof spec.tool !== 'string' || !registered(spec.tool as string) ||
          typeof spec.label !== 'string' || !(spec.label as string).trim().length || (spec.label as string).length > 256) { return invalid(); }
        const format = inputFormat(spec.tool as string);
        if (format === 'text' ? typeof spec.input !== 'string' : spec.input === null || typeof spec.input !== 'object' || Array.isArray(spec.input)) { return invalid(); }
        if (requirements.some((old: PlannedRequirement): boolean => old.id === spec.id)) { return invalid(); }
        requirements.push({ id: spec.id as string, tool: spec.tool as string, input: format === 'text' ? spec.input as string : JSON.stringify(spec.input), label: (spec.label as string).replace(/[\r\n]/g, ' ') });
      }
    } catch (_error) { return invalid(); }
    rest = rest.substring(end + 1).trim();
  }
  if (/^(?:Observation|Control)\s*:/i.test(rest)) { return invalid(); }
  if (!/(?:^|\n)\s*(?:Action|Execution|For)\s*:/i.test(rest) && !/^(?:Final|Answer)[^\n]*Action\s*:/i.test(rest)) {
    return { mode: mode, calls: [], error: '', requirements: requirements, goals: goals, nodes: nodes };
  }
  if (/^(?:Final|Answer)/i.test(rest)) { return invalid(); }
  const consumeExecution = (): boolean => {
    if (!/^Execution\s*:/i.test(rest)) { return true; }
    const execution = /^Execution\s*:\s*(serial|parallel)\s*(?:\r?\n|$)/i.exec(rest);
    if (execution === null) { return false; }
    const requested = execution[1].toLowerCase() === 'parallel' ? 'parallel' : 'serial';
    if ((executionDeclared || calls.length > 0) && mode !== requested) { return false; }
    mode = requested;
    executionDeclared = true;
    rest = rest.substring(execution[0].length).trim();
    return true;
  };
  while (rest.length > 0) {
    // Some text-only models continue through the tool boundary. This suffix is
    // NEVER evidence or another command. The runner additionally requires that
    // every preceding call is a registered low-risk read before recovering it.
    if (calls.length > 0 && /^(?:Observation\s*:|Control\s*:\s*Call\s)/i.test(rest)) {
      discardedObservation = true;
      break;
    }
    if (!consumeExecution()) { return invalid(); }
    let goalIds: string[] | undefined;
    if (/^For\s*:/i.test(rest)) {
      const line = /^For\s*:\s*(\[[^\r\n]*\])\s*(?:\r?\n|$)/i.exec(rest);
      if (line === null) { return invalid(); }
      try {
        const ids = JSON.parse(line[1]) as Object;
        if (!Array.isArray(ids) || !ids.length || ids.length > 32 || (ids as Object[]).some((id: Object, index: number): boolean => typeof id !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(id) || (ids as Object[]).indexOf(id) !== index)) { return invalid(); }
        goalIds = ids as string[];
      } catch (_error) { return invalid(); }
      rest = rest.substring(line[0].length).trim();
    }
    // Metadata can occur on either side of For and repeat consistently. A mode
    // change within a batch remains ambiguous and invalidates the entire batch.
    if (!consumeExecution()) { return invalid(); }
    const action = /^Action\s*:\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*([\[(])/i.exec(rest);
    if (action === null || !registered(action[1])) { return invalid(); }
    const name = action[1];
    const format = inputFormat(name);
    const close = action[2] === '[' ? ']' : ')';
    const start = action[0].length;
    let quoted = false;
    let escaped = false;
    let depth = 0;
    let end = -1;
    for (let i = start; i < rest.length; i++) {
      const ch = rest.charAt(i);
      if (quoted) {
        if (escaped) { escaped = false; }
        else if (ch === '\\') { escaped = true; }
        else if (ch === '"') { quoted = false; }
        continue;
      }
      if (ch === '"') { quoted = true; continue; }
      if (depth === 0 && ch === close) { end = i; break; }
      if (format !== 'text' && (ch === '{' || ch === '[')) { depth++; }
      if (format !== 'text' && (ch === '}' || ch === ']')) { depth--; }
      if (depth < 0) { return invalid(); }
    }
    if (end < 0 || quoted || depth !== 0) { return invalid(); }
    let input = rest.substring(start, end).trim();
    // Input framing belongs to the registered contract, including no-input tools.
    if (format === 'text' || format === 'none' && input.length === 0) {
      if (format === 'text' && input.startsWith('"')) {
        try { const decoded = JSON.parse(input) as Object; if (typeof decoded !== 'string') { return invalid(); } input = decoded as string; } catch (_error) { return invalid(); }
      }
      calls.push({ name: name, input: input });
    } else {
      try {
        const value = JSON.parse(input) as Object;
        if (value === null || typeof value !== 'object' || Array.isArray(value)) { return invalid(); }
      } catch (_error) { return invalid(); }
      calls.push({ name: name, input: input });
    }
    if (goalIds !== undefined) { calls[calls.length - 1].goalIds = goalIds; }
    rest = rest.substring(end + 1).trim();
  }
  if (calls.length === 0) { return invalid(); }
  return { mode: mode, calls: calls, error: '', discardedObservation: discardedObservation, requirements: requirements, goals: goals, nodes: nodes };
}

export interface RequirementMerge { entries: TaskRequirement[]; error: string; }
export function mergePlannedRequirements(entries: TaskRequirement[], specs: PlannedRequirement[], contracts: ToolContractCatalog, anchorTime: number): RequirementMerge {
  const next = entries.slice();
  for (const spec of specs) {
    const call: CoreCall = { name: spec.tool, input: spec.input };
    const issues = contracts.validateInput(call);
    if (issues.length > 0) { return { entries: entries, error: spec.tool + ': ' + issues.join('; ') }; }
    const id = 'plan:' + spec.id, existing = next.find((entry: TaskRequirement): boolean => entry.id === id);
    if (existing !== undefined) {
      if (existing.tool !== spec.tool || existing.expectedInput === undefined || inputKey(contracts.inputFormat(spec.tool), existing.expectedInput) !== inputKey(contracts.inputFormat(spec.tool), spec.input)) {
        return { entries: entries, error: 'A planned requirement ID cannot be reassigned to different arguments.' };
      }
      continue;
    }
    next.push({ id: id, tool: spec.tool, label: spec.label, scope: {} as Record<string, Object>, expectedInput: spec.input,
      anchorTime: anchorTime, status: 'pending', output: '' });
  }
  return { entries: next, error: '' };
}

export function buildTaskLedger(task: string, anchorTime: number = Date.now(), contracts: ToolContractCatalog = new ToolContractCatalog()): TaskRequirement[] {
  return contracts.recognize(task, anchorTime);
}
export function returnedStatus(text: string): TaskStatus { return text.trim().length ? 'success' : 'empty'; }
export function prepareCalls(calls: CoreCall[], entries: TaskRequirement[], contracts: ToolContractCatalog, task: string = ''): string[] {
  const issues: string[] = [];
  for (const call of calls) {
    try {
      contracts.prepare(call, entries, task);
      issues.push(...contracts.validateInput(call).map((issue: string): string => call.name + ': ' + issue));
    } catch (_error) { issues.push(call.name + ': contract preparation/validation failed'); }
  }
  return issues;
}
export function bindResult(entries: TaskRequirement[], call: CoreCall, status: TaskStatus, output: string, callId: string = '', contracts: ToolContractCatalog = new ToolContractCatalog(), displayText: string = output, data?: Object): void {
  if (callId.length > 0 && callId !== call.callId) { return; }
  for (const entry of entries) {
    if (!contracts.matches(entry, call)) { continue; }
    entry.status = status; entry.output = output; entry.displayText = displayText; entry.input = call.input;
    entry.resultCallId = callId || call.callId; entry.data = data;
  }
}
export function bindToolResult(entries: TaskRequirement[], call: CoreCall, result: ResultLedgerEntry, contracts: ToolContractCatalog = new ToolContractCatalog()): boolean {
  if (!call.callId || result.callId !== call.callId || result.tool !== call.name) { return false; }
  bindResult(entries, call, result.status, result.raw, result.callId, contracts, result.displayText, result.data);
  return true;
}
export function finalIssues(entries: TaskRequirement[], answer: string, contracts: ToolContractCatalog = new ToolContractCatalog(), semanticReviewed: boolean = false): string[] {
  return contracts.validateAnswer(entries, answer, semanticReviewed);
}
export function ledgerReport(entries: TaskRequirement[]): string {
  return entries.map((entry: TaskRequirement): string => {
    if (entry.status === 'pending') { return entry.label + '：未完成，未取得匹配的工具结果，无法确认。'; }
    const display = entry.displayText ?? entry.output;
    if (entry.status !== 'success') {
      const label = entry.status === 'failed' ? '查询失败' : entry.status === 'empty' ? '未获得结果' : '暂不可用';
      return entry.label + '：' + label + (display.trim().length ? '\n' + display : '。');
    }
    return entry.label + '：\n' + display;
  }).join('\n\n');
}

// Prompt layout shared with transports: [instructions][earlier conversation][task section].
// loop-react-split-v1 sends everything before the task marker as the developer turn.
export const PROMPT_TASK_MARKERS: string[] = ['\nUser task:', '\nOriginal question:', '\n原始问题：'];
export const PROMPT_HISTORY_HEADER = 'Earlier conversation (reference context only, not current evidence):';
export const PROMPT_HISTORY_END = 'End of earlier conversation.';
export interface SplitPrompt { system: string; user: string; }

function taskMarkerAt(text: string, from: number): number {
  let found = -1;
  for (const marker of PROMPT_TASK_MARKERS) {
    const at = text.indexOf(marker, from);
    if (at >= 0 && (found < 0 || at < found)) { found = at; }
  }
  return found;
}

export function splitReActPrompt(prompt: string): SplitPrompt | null {
  const historyEnd = prompt.indexOf('\n' + PROMPT_HISTORY_END + '\n');
  const at = taskMarkerAt(prompt, historyEnd >= 0 ? historyEnd : 0);
  if (at < 0) { return null; }
  const system = prompt.substring(0, at).trim(), user = prompt.substring(at + 1).trim();
  return system.length > 0 && user.length > 0 ? { system: system, user: user } : null;
}

// History is made of whole groups and precedes the current task. The latest
// complete tool turn is mandatory; later Control groups cannot displace it.
// The caller supplies UTF-8 byte length.
export function fitPrompt(base: string, history: string[], groups: string[], limit: number, byteLength: (s: string) => number, tail: string = ''): string {
  if (!Number.isFinite(limit) || limit <= 0) { throw new Error('Invalid maxPromptBytes'); }
  let latest = -1;
  for (let i = groups.length - 1; i >= 0; i--) { if (groups[i].indexOf('Action:') >= 0) { latest = i; break; } }
  const mandatoryStart = latest >= 0 ? latest : Math.max(0, groups.length - 1);
  const mandatory = groups.slice(mandatoryStart);
  const keptHistory = history.slice(), olderGroups = groups.slice(0, mandatoryStart);
  const split = taskMarkerAt(base, 0);
  const head = split >= 0 ? base.substring(0, split) : base, taskSection = split >= 0 ? base.substring(split) : '';
  const notice = 'Control: Oldest whole history groups omitted to fit prompt budget.\n';
  const render = (kept: string[], older: string[], omitted: boolean): string => head +
    (kept.length > 0 ? '\n' + PROMPT_HISTORY_HEADER + '\n' + kept.join('\n') + '\n' + PROMPT_HISTORY_END : '') + taskSection +
    '\n' + (omitted ? notice : '') + older.concat(mandatory).join('\n') + (tail.length > 0 ? '\n' + tail : '');
  const optionalCount = keptHistory.length + olderGroups.length;
  if (byteLength(render([], [], optionalCount > 0)) > limit) { throw new Error('Prompt budget exceeded: mandatory tools, task, or latest complete tool turn cannot fit.'); }
  let dropped = false;
  while (byteLength(render(keptHistory, olderGroups, dropped)) > limit && keptHistory.length + olderGroups.length > 0) {
    if (keptHistory.length > 0) { keptHistory.shift(); } else { olderGroups.shift(); }
    dropped = true;
  }
  return render(keptHistory, olderGroups, dropped);
}
