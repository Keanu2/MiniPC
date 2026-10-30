import { ConversationContext } from '../agent/ConversationContext';
import { LocalModel } from './LocalModel';
import { requireTextCompletion } from './TextCompletionResponse';
import { skillLogInfo, skillLogInfoChunks, skillLogWarn } from '../skill/SkillLog';

/**
 * 本地 LLM 原生绑定接口。
 *
 * PRODUCTION TODO: 实际的 .so 绑定在 entry 侧实现:
 *   import libLlm from 'libllm.so';
 *   const binding: LlmNativeBinding = {
 *     createSession: (a) => libLlm.llmCreateSession(a),
 *     destroySession: (s) => libLlm.llmDestroySession(s),
 *     submitRequest: (s, r, cb) => libLlm.llmSubmitRequest(s, r, cb),
 *     abortRequest: (s, r) => libLlm.llmAbortRequest(s, r),
 *     enableCollaboration: (info) => libLlm.llmEnableCollaboration(info),
 *     disableCollaboration: () => libLlm.llmDisableCollaboration()
 *   };
 * HAR 库 (agent_core) 不直接 import .so, 由 entry 注入。
 */
interface SessionResultInterface {
  session: number;
  error: number;
}

interface RequestResultInterface {
  request: number;
  error: number;
}

export interface LlmNativeBinding {
  createSession(attributes: string): SessionResultInterface;
  destroySession(session: number): number;
  submitRequest(
    session: number,
    request: string,
    callback: (response: string) => void
  ): RequestResultInterface;
  abortRequest(session: number, request: number): number;
  enableCollaboration(info: string): number;
  disableCollaboration(): number;
  isCollaborationSupported(): boolean;
}

export interface LlmMessage {
  role: string;
  content: string;
}

/**
 * PRODUCTION TODO: 回调 response 的 JSON 格式预留。
 * 当前假设为 {"content":"增量文本","finish_reason":null}。
 * 生产环境如字段名不同, 只改 parseResponseChunk 方法。
 */
export interface ResponseChunk {
  content: string;
  finish_reason: string | null;
}

interface ResponseChoiceEnvelope {
  delta?: ResponseMessageEnvelope;
  message?: ResponseMessageEnvelope;
  finish_reason?: string | null;
}

interface ResponseChunkEnvelope {
  error?: Object | string;
  content?: string;
  finish_reason?: string | null;
  message?: ResponseMessageEnvelope;
  choices?: ResponseChoiceEnvelope[];
}

interface ResponseMessageEnvelope {
  tool_calls?: Object;
  function_call?: Object;
  role?: string;
  content?: string;
}

export interface SessionBackedModelOptions {
  attributes?: string;
  stream?: boolean;
  requestType?: string;
  /**
   * Leave the native Session owned by Gewu when this model stops using it.
   * The next prepareSession() creates a new Session and receives a new ID.
   */
  retainNativeSessionOnClose?: boolean;
  /** Observe the moment a request is submitted to the native LLM runtime. */
  requestListener?: (requestId: number) => void;
  /** Observe each raw response delivered by the native inference callback. */
  responseListener?: (response: string, requestId: number) => void;
  /**
   * Native runtimes may report finish_reason before their request thread has
   * finished writing the session KV cache. Keep the next request queued for
   * this long after a completed/failed submission. Zero disables the drain.
   */
  requestDrainMs?: number;
}

interface LocalGenerationOptions {
  temperature: number;
  max_tokens: number;
}

interface LocalRequestPayload {
  type: string;
  messages: LlmMessage[];
  stream: boolean;
  temperature?: number;
  max_tokens?: number;
}

export type LocalLlmBackend = 'knpu' | 'cpu' | 'mlir';

export interface LocalLlmParallelSettings {
  caller: number;
  isCo: boolean;
}

export interface LocalLlmSessionSettings {
  backend?: LocalLlmBackend;
  maxContext?: number;
  parallel?: LocalLlmParallelSettings;
}

export interface LocalLlmCollaborationSettings {
  isMaster: boolean;
  masterIP: string;
  masterPort: number;
}

interface LocalEvalSettings {
  backend: LocalLlmBackend;
  max_ctx: number;
}

interface LocalParallelSettings {
  caller: number;
  is_co: boolean;
}

interface LocalSessionAttributes {
  model: string;
  eval_settings?: LocalEvalSettings;
  parallel_settings?: LocalParallelSettings;
}

interface CollaborationAttributes {
  isMaster: boolean;
  masterIP: string;
  masterPort: number;
}

export const DEFAULT_LOCAL_LLM_BACKEND: LocalLlmBackend = 'knpu';
// The Mate 70 Gewu KNPU session rejects larger max_ctx values with error 401.
// This is the supported context window, not a decode/output-token limit.
export const DEFAULT_LOCAL_LLM_MAX_CONTEXT: number = 2048;

export function normalizeLocalLlmBackend(value?: string): LocalLlmBackend {
  const normalized = value?.trim().toLowerCase() ?? '';
  if (normalized === 'cpu') {
    return 'cpu';
  }
  if (normalized === 'mlir') {
    return 'mlir';
  }
  return DEFAULT_LOCAL_LLM_BACKEND;
}

export function normalizeLocalLlmMaxContext(value?: number): number {
  if (value === undefined || !Number.isFinite(value) || value <= 0) {
    return DEFAULT_LOCAL_LLM_MAX_CONTEXT;
  }
  return Math.floor(value);
}

export function buildLocalSessionAttributes(
  localModelPath: string,
  settings?: LocalLlmSessionSettings
): string | undefined {
  const trimmedPath = localModelPath.trim();
  if (trimmedPath.length === 0) {
    return undefined;
  }
  const attributes: LocalSessionAttributes = {
    model: trimmedPath
  };
  if (settings !== undefined) {
    attributes.eval_settings = {
      backend: normalizeLocalLlmBackend(settings.backend),
      max_ctx: normalizeLocalLlmMaxContext(settings.maxContext)
    };
    const parallel = settings.parallel;
    if (parallel !== undefined && Number.isFinite(parallel.caller) && parallel.caller >= 0) {
      attributes.parallel_settings = {
        caller: Math.floor(parallel.caller),
        is_co: parallel.isCo
      };
    }
  }
  return JSON.stringify(attributes);
}

export function buildLocalCollaborationInfo(settings: LocalLlmCollaborationSettings): string | undefined {
  const masterIP = settings.masterIP.trim();
  if (masterIP.length === 0 || !Number.isFinite(settings.masterPort) ||
    settings.masterPort < 1 || settings.masterPort > 65535) {
    return undefined;
  }
  const attributes: CollaborationAttributes = {
    isMaster: settings.isMaster,
    masterIP: masterIP,
    masterPort: Math.floor(settings.masterPort)
  };
  return JSON.stringify(attributes);
}

export function parseSessionResponseChunk(response: string): ResponseChunk {
  let json: ResponseChunkEnvelope;
  try {
    json = JSON.parse(response) as ResponseChunkEnvelope;
  } catch (_error) {
    if (/^\s*[\[{]/.test(response)) throw new Error('Malformed native response JSON.');
    return { content: response, finish_reason: null };
  }
  if (json === null || typeof json !== 'object' || Array.isArray(json)) {
    throw new Error('Invalid native response envelope.');
  }
  if (json.error !== undefined && json.error !== null) {
    throw new Error('Native provider error: ' + JSON.stringify(json.error));
  }
  if (json.choices !== undefined && !Array.isArray(json.choices)) throw new Error('Invalid native choices.');
  const choice = json.choices !== undefined && json.choices.length > 0 ? json.choices[0] : undefined;
  const message = json.message ?? choice?.delta ?? choice?.message;
  if (message?.tool_calls !== undefined || message?.function_call !== undefined) {
    throw new Error('Unsupported native tool_calls/function_call; text ReAct required.');
  }
  const content = json.content ?? message?.content ?? '';
  const reason = json.finish_reason ?? choice?.finish_reason ?? null;
  if (typeof content !== 'string' || (reason !== null && typeof reason !== 'string')) {
    throw new Error('Invalid native content or finish_reason.');
  }
  return { content: content, finish_reason: reason };
}

// A retry inside the same native/co-session cannot repair a broken data plane;
// recovery must rebuild both sides through CollaborationController.
const MAX_ATTEMPTS = 1;

// No token for this long means the native decode is stuck; the outer run deadline is much longer.
const NATIVE_IDLE_TIMEOUT_MS = 120000;

/** Same-token floods (NaN logits emit token 0 forever) and verbatim loops never reach EOS. */
function isDegenerateOutput(text: string): boolean {
  const head = text.trimStart();
  if (head.length >= 24 && '-=*_#~`.'.indexOf(head.charAt(0)) < 0) {
    let same = true;
    for (let i = 1; i < 24 && same; i++) same = head.charAt(i) === head.charAt(0);
    if (same) return true;
  }
  for (let unit = 1; unit <= 48; unit++) {
    if (text.length < unit * 4) break;
    const tail = text.substring(text.length - unit);
    if (tail.trim().length === 0) continue;
    let repeats = 1;
    let pos = text.length - unit;
    while (pos >= unit && repeats * unit < 160 && text.substring(pos - unit, pos) === tail) { repeats++; pos -= unit; }
    if (repeats >= 4 && repeats * unit >= 160) return true;
  }
  return false;
}

/**
 * 将本地 C++ LLM 推理服务适配为无状态的 LocalModel 接口。
 *
 * 核心策略 (prompt diff + messages 转换):
 * - ReAct 的 buildPrompt 每步全量重拼 flat prompt
 * - 适配层 diff 只提取尚未进入 Session 的新 observation
 * - developer 只在原生 Session 的首次正式请求中发送一次
 * - 后续请求只发送新增 user turn; Gewu Session 保留历史和模型 response
 * - 同一 session 复用, 底层 KV-cache 命中前缀, 只 prefill 增量
 *
 * 生命周期:
 * - 单次 ReAct run 内复用 session (KV-cache 在此生效)
 * - 协同模式下 run 结束只调 resetRunState(), 跨用户消息继续复用 session
 * - 只有 Clear/断连/销毁控制器时才由调用方 closeSession() 或 dispose()
 */
interface PromptText {
  userText: string;
}

interface SessionRequestLease {
  epoch: number;
  sequence: number;
  release: () => void;
}

function noOp(): void {
}

export class SessionBackedModel implements LocalModel {
  private binding: LlmNativeBinding;
  private sessionId: number | null = null;
  private messages: LlmMessage[] = [];
  private lastPrompt: string = '';
  private lastResponse: string = '';
  private options: SessionBackedModelOptions;
  private tokenStreamListener: ((token: string) => void) | null = null;
  private disposed = false;
  private activeRequestId: number | null = null;
  private activeRequestCancel: ((reason: string) => void) | null = null;
  private requestQueue: Promise<void> = Promise.resolve();
  private requestEpoch = 0;
  private requestSequence = 0;
  private nativeSubmissionSequence = 0;
  private sessionContextInitialized = false;

  constructor(binding: LlmNativeBinding, options?: SessionBackedModelOptions) {
    this.binding = binding;
    this.options = options ?? {};
  }

  setTokenStreamListener(listener: ((token: string) => void) | null): void {
    this.tokenStreamListener = listener;
  }

  setResponseListener(listener: ((response: string, requestId: number) => void) | null): void {
    this.options.responseListener = listener ?? undefined;
  }

  setRequestListener(listener: ((requestId: number) => void) | null): void {
    this.options.requestListener = listener ?? undefined;
  }

  /** Create the native session before submit so cooperating devices can align their lifecycle. */
  prepareSession(): boolean {
    if (this.disposed) {
      return false;
    }
    if (this.sessionId !== null) {
      return true;
    }
    try {
      const result = this.binding.createSession(this.options.attributes ?? '{}');
      if (result.error !== 0) {
        skillLogWarn('SessionBackedModel: prepareSession failed: error=' + result.error);
        return false;
      }
      this.sessionId = result.session;
      skillLogInfo('SessionBackedModel: prepareSession ok session=' + this.sessionId);
      return true;
    } catch (error) {
      skillLogWarn('SessionBackedModel: prepareSession exception: ' +
        (error instanceof Error ? error.message : String(error)));
      return false;
    }
  }

  /** End one cooperative run while keeping this model reusable for the next run. */
  closeSession(): void {
    if (this.disposed) {
      return;
    }
    // A queued request belongs to the session that existed when it entered the
    // queue. Do not let it silently create/use the replacement after Clear.
    this.requestEpoch += 1;
    const activeRequestCancel = this.activeRequestCancel;
    if (this.sessionId !== null && this.activeRequestId !== null) {
      try {
        this.binding.abortRequest(this.sessionId, this.activeRequestId);
      } catch (_error) {
        // best-effort cleanup
      }
    }
    // Gewu does not guarantee another callback after abortRequest(). Settle
    // the pending Promise ourselves so its finally block releases the serial
    // request lease instead of permanently blocking the replacement session.
    activeRequestCancel?.('Session closed while the request was active.');
    this.activeRequestId = null;
    this.activeRequestCancel = null;
    if (this.sessionId !== null) {
      const closedSession = this.sessionId;
      if (this.options.retainNativeSessionOnClose === true) {
        skillLogInfo('SessionBackedModel: retained native session=' + closedSession);
      } else {
        try {
          this.binding.destroySession(closedSession);
        } catch (error) {
          skillLogWarn('SessionBackedModel: closeSession destroySession failed: ' +
            (error instanceof Error ? error.message : String(error)));
        }
      }
      this.sessionId = null;
    }
    this.sessionContextInitialized = false;
    this.resetPromptState();
  }

  /**
   * Start a new agent turn without destroying the native Gewu session.
   *
   * GewuDemo keeps one master/co-session pair alive and submits multiple chat
   * requests through it. Clearing only the prompt-diff state preserves that
   * lifecycle while allowing each ReAct run to rebuild its own message list.
   */
  resetRunState(): void {
    if (this.disposed || this.activeRequestId !== null) {
      return;
    }
    this.resetPromptState();
  }

  /**
   * Verify that a prepared distributed session can complete one real tensor
   * exchange before Loopy submits the user's request.
   *
   * The timer applies only to this one-token health probe. A successful probe
   * is followed by the real request with no Prefill or Decode timeout.
   */
  async probeSession(timeoutMs: number): Promise<boolean> {
    if (this.disposed || this.sessionId === null || !Number.isFinite(timeoutMs) || timeoutMs < 1) {
      return false;
    }
    let lease: SessionRequestLease | null = null;
    try {
      lease = await this.acquireRequestLease();
      if (this.sessionId === null) {
        return false;
      }
      const session = this.sessionId;
      const requestJson = JSON.stringify({
        type: this.options.requestType ?? 'qwen2',
        messages: [{ role: 'user', content: 'ping' } as LlmMessage],
        stream: true,
        temperature: 0,
        max_tokens: 1
      });
      return await new Promise<boolean>((resolve) => {
        let settled = false;
        let requestId: number | null = null;
        let timer = -1;
        const finish = (healthy: boolean): void => {
          if (settled) {
            return;
          }
          settled = true;
          if (timer !== -1) {
            clearTimeout(timer);
            timer = -1;
          }
          if (this.activeRequestId === requestId) {
            this.activeRequestId = null;
          }
          this.activeRequestCancel = null;
          resolve(healthy);
        };
        this.activeRequestCancel = (_reason: string): void => {
          finish(false);
        };
        timer = setTimeout((): void => {
          if (requestId !== null) {
            try {
              this.binding.abortRequest(session, requestId);
            } catch (_error) {
              // The paired-session rebuild below is the authoritative recovery.
            }
          }
          skillLogWarn('SessionBackedModel: collaboration health probe stalled before completion');
          finish(false);
        }, timeoutMs);
        try {
          const result = this.binding.submitRequest(session, requestJson, (response: string): void => {
            if (settled) {
              return;
            }
            try {
              const chunk = this.parseResponseChunk(response);
              if (chunk.finish_reason !== null) {
                // A one-token health probe intentionally exhausts its budget.
                finish(chunk.finish_reason === 'stop' || chunk.finish_reason === 'length');
              }
            } catch (_error) {
              finish(false);
            }
          });
          if (result.error !== 0) {
            finish(false);
            return;
          }
          requestId = result.request;
          if (!settled) {
            this.activeRequestId = result.request;
          }
        } catch (_error) {
          finish(false);
        }
      });
    } catch (error) {
      skillLogWarn('SessionBackedModel: collaboration health probe could not acquire session: ' +
        (error instanceof Error ? error.message : String(error)));
      return false;
    } finally {
      if (lease !== null) {
        // CollaborationController already owns the proven probe drain before
        // it exposes session_ready. Release only the shared serial slot here.
        await this.releaseRequestLease(lease, false);
      }
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.closeSession();
    this.disposed = true;
  }

  async complete(prompt: string, _conversation?: ConversationContext): Promise<string> {
    // conversation 故意忽略: ReAct 的 buildPrompt 已把历史拼进 prompt 文本。
    // 若底层 service 再记历史会造成双重历史、模型混乱。
    return this.completeWithOptions(prompt);
  }

  /** Run one evaluator-controlled request without adding benchmark metadata to the model prompt. */
  async completeBenchmark(prompt: string, maxTokens: number, temperature: number = 0): Promise<string> {
    if (!Number.isFinite(maxTokens) || maxTokens < 1 || !Number.isFinite(temperature)) {
      throw new Error('Invalid benchmark generation options.');
    }
    return this.completeWithOptions(prompt, {
      temperature: temperature,
      max_tokens: Math.floor(maxTokens)
    });
  }

  private async completeWithOptions(prompt: string, generation?: LocalGenerationOptions): Promise<string> {
    const lease = await this.acquireRequestLease();
    try {
      let lastError = '';
      for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        try {
          return await this.completeOnce(prompt, generation);
        } catch (error) {
          lastError = error instanceof Error ? error.message : String(error);
          if (attempt + 1 >= MAX_ATTEMPTS || !this.isRetryableTransportError(lastError)) {
            throw new Error('LLM request failed: ' + lastError);
          }
          skillLogInfo('SessionBackedModel: retrying (attempt ' + (attempt + 2) + '/' + MAX_ATTEMPTS + ')');
        }
      }
      throw new Error('LLM request failed: ' + lastError);
    } finally {
      await this.releaseRequestLease(lease, true);
    }
  }

  /**
   * Serialize every native submission that uses this model instance.
   *
   * The queue promise itself never rejects: every holder releases it in a
   * finally block. The epoch prevents a request queued for an old Session from
   * crossing a Clear/close boundary and attaching itself to the replacement.
   */
  private async acquireRequestLease(): Promise<SessionRequestLease> {
    const epoch = this.requestEpoch;
    this.requestSequence += 1;
    const sequence = this.requestSequence;
    let release: () => void = noOp;
    const turn = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    const previousTurn = this.requestQueue;
    this.requestQueue = turn;
    skillLogInfo('SessionBackedModel: request queued sequence=' + sequence);
    await previousTurn;
    if (this.disposed || epoch !== this.requestEpoch) {
      release();
      throw new Error(this.disposed
        ? 'Model was disposed while request was queued.'
        : 'Session changed while request was queued.');
    }
    skillLogInfo('SessionBackedModel: request acquired sequence=' + sequence +
      ' session=' + (this.sessionId === null ? 'none' : this.sessionId));
    return { epoch: epoch, sequence: sequence, release: release };
  }

  private async releaseRequestLease(lease: SessionRequestLease, drain: boolean): Promise<void> {
    try {
      const drainMs = this.normalizedRequestDrainMs();
      if (drain && drainMs > 0 && !this.disposed && lease.epoch === this.requestEpoch) {
        skillLogInfo('SessionBackedModel: request draining sequence=' + lease.sequence +
          ' delayMs=' + drainMs);
        await this.delay(drainMs);
      }
    } finally {
      skillLogInfo('SessionBackedModel: request released sequence=' + lease.sequence);
      lease.release();
    }
  }

  private normalizedRequestDrainMs(): number {
    const value = this.options.requestDrainMs;
    if (value === undefined || !Number.isFinite(value) || value <= 0) {
      return 0;
    }
    return Math.floor(value);
  }

  private delay(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, milliseconds);
    });
  }

  private async completeOnce(prompt: string, generation?: LocalGenerationOptions): Promise<string> {
    this.updateMessages(prompt);

    if (this.sessionId === null) {
      const result = this.binding.createSession(this.options.attributes ?? '{}');
      if (result.error !== 0) {
        throw new Error('CreateSession failed: error=' + result.error);
      }
      this.sessionId = result.session;
    }

    const requestPayload: LocalRequestPayload = {
      type: this.options.requestType ?? 'qwen2',
      messages: this.messages,
      stream: this.options.stream ?? true,
      temperature: generation?.temperature,
      max_tokens: generation?.max_tokens
    };
    const requestJson = JSON.stringify(requestPayload);
    const formattedRequestJson = JSON.stringify(requestPayload, null, 2);
    skillLogInfo('GEWU sessionId：' + String(this.sessionId));
    skillLogInfoChunks('To GEWU llm：\n', formattedRequestJson);

    return new Promise<string>((resolve, reject) => {
      let buffer = '';
      let settled = false;

      let idleTimer: number = -1;
      const clearIdle = (): void => { if (idleTimer !== -1) { clearTimeout(idleTimer); idleTimer = -1; } };
      const armIdle = (): void => {
        clearIdle();
        idleTimer = setTimeout((): void => {
          if (settled) return;
          const abortId = this.activeRequestId;
          if (this.sessionId !== null && abortId !== null) {
            try { this.binding.abortRequest(this.sessionId, abortId); } catch (_error) { /* best effort */ }
          }
          finish(() => reject(new Error('Native model produced no output for ' + String(NATIVE_IDLE_TIMEOUT_MS / 1000) + 's.')));
        }, NATIVE_IDLE_TIMEOUT_MS);
      };

      const finish = (action: () => void): void => {
        if (settled) return;
        settled = true;
        clearIdle();
        this.activeRequestId = null;
        this.activeRequestCancel = null;
        action();
      };

      this.activeRequestCancel = (reason: string): void => {
        finish(() => reject(new Error(reason)));
      };

      this.nativeSubmissionSequence += 1;
      const requestId = this.nativeSubmissionSequence;
      try {
        try {
          this.options.requestListener?.(requestId);
        } catch (error) {
          skillLogWarn('SessionBackedModel: request listener failed: ' +
            (error instanceof Error ? error.message : String(error)));
        }
        const submitResult = this.binding.submitRequest(
          this.sessionId!,
          requestJson,
          (response: string) => {
            if (settled) return;
            armIdle();
            try {
              this.options.responseListener?.(response, requestId);
            } catch (error) {
              skillLogWarn('SessionBackedModel: response listener failed: ' +
                (error instanceof Error ? error.message : String(error)));
            }
            try {
              const chunk = this.parseResponseChunk(response);
              if (chunk.finish_reason !== null) requireTextCompletion(chunk.finish_reason);
              if (chunk.content.length > 0) {
                buffer += chunk.content;
                if (isDegenerateOutput(buffer)) {
                  if (this.sessionId !== null && this.activeRequestId !== null) {
                    try { this.binding.abortRequest(this.sessionId, this.activeRequestId); } catch (_error) { /* best effort */ }
                  }
                  throw new Error('Model output degenerated into repetition.');
                }
                try {
                  this.tokenStreamListener?.(chunk.content);
                } catch (_error) {
                  // Observers must not leave a native request unsettled.
                }
              }
              if (chunk.finish_reason !== null) {
                finish(() => {
                  const text = buffer.trim();
                  if (text.length === 0) {
                    reject(new Error('No message content returned.'));
                    return;
                  }
                  this.sessionContextInitialized = true;
                  this.lastPrompt = prompt;
                  this.lastResponse = text;
                  resolve(text);
                });
              }
            } catch (error) {
              finish(() => reject(error instanceof Error ? error : new Error(String(error))));
            }
          }
        );

        armIdle();
        if (submitResult.error !== 0) {
          finish(() => reject(new Error('SubmitRequest failed: error=' + submitResult.error)));
          return;
        }
        if (!settled) {
          this.activeRequestId = submitResult.request;
        }
      } catch (error) {
        finish(() => reject(error instanceof Error ? error : new Error(String(error))));
      }
    });
  }

  // --- Prompt -> Messages 转换 ---

  private updateMessages(prompt: string): void {
    if (this.messages.length === 0) {
      this.messages = this.parseInitialPrompt(prompt);
    } else {
      const diff = this.diffPrompt(prompt);
      if (diff !== null) {
        // The native Session already owns the previous user turn and generated
        // assistant response. Submit only the new ReAct observation.
        this.messages = [{ role: 'user', content: diff.userText }];
      } else {
        // Prompt reconstruction is application state, not a native Session
        // boundary. Replacing only the master's session here would desync the
        // paired Gewu session. Clear/teardown is the sole replacement path.
        skillLogWarn('SessionBackedModel: diff failed, resetting prompt state without replacing session');
        this.resetPromptState();
        this.messages = this.parseInitialPrompt(prompt);
      }
    }
  }

  private parseInitialPrompt(prompt: string): LlmMessage[] {
    const marker = '\nUser task:\n';
    const idx = prompt.indexOf(marker);
    if (idx < 0) {
      return [{ role: 'user', content: prompt }];
    }
    const systemContent = prompt.substring(0, idx + 1).trim();
    const userContent = prompt.substring(idx + marker.length).trim();
    if (this.sessionContextInitialized) {
      return [{ role: 'user', content: userContent }];
    }
    return [
      { role: 'developer', content: systemContent },
      { role: 'user', content: userContent }
    ];
  }

  private diffPrompt(prompt: string): PromptText | null {
    const strippedPrompt = this.stripDatetimeLine(prompt);
    const strippedLast = this.stripDatetimeLine(this.lastPrompt);

    if (!strippedPrompt.startsWith(strippedLast)) {
      return null;
    }

    const suffix = strippedPrompt.substring(strippedLast.length).trim();
    if (suffix.length === 0) {
      return null;
    }

    const lastResp = this.lastResponse.trim();
    if (!suffix.startsWith(lastResp)) {
      return null;
    }
    const userText = suffix.substring(lastResp.length).trim();
    return { userText: userText };
  }

  private stripDatetimeLine(text: string): string {
    const prefix = 'Current device local datetime: ';
    const startIdx = text.indexOf(prefix);
    if (startIdx < 0) return text;
    const lineEnd = text.indexOf('\n', startIdx);
    if (lineEnd < 0) return text;
    return text.substring(0, startIdx) + text.substring(lineEnd + 1);
  }

  private resetPromptState(): void {
    this.messages = [];
    this.lastPrompt = '';
    this.lastResponse = '';
  }

  // --- 响应解析 (PRODUCTION TODO: 可配置) ---

  /**
   * PRODUCTION TODO: 回调 response 格式预留。
   * 当前假设为 JSON: {"content":"增量文本","finish_reason":null}
   * 生产环境如字段名不同, 修改此方法即可。
   */
  private parseResponseChunk(response: string): ResponseChunk {
    return parseSessionResponseChunk(response);
  }

  private isRetryableTransportError(message: string): boolean {
    const lower = message.toLowerCase();
    if (lower.indexOf('http 4') >= 0 || lower.indexOf('http 5') >= 0) {
      return false;
    }
    return lower.indexOf('timeout') >= 0 ||
      lower.indexOf('connection') >= 0 ||
      lower.indexOf('network') >= 0;
  }
}
