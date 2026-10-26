import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage as WireChatMessage, ClusterInfo, InferProfile, WireMessage, InferenceMetrics } from '../protocol/ChatProtocol';
import { ChatBackend, ChatMessage, ChatUpdate } from './LocalChat';
import { LlmTransport } from './LlmTransport';
import { QwenVlManager } from './QwenVlManager';
import { RelayLocal } from './InferenceRelay';
import { sha256Hex, splitUtf8, utf8Bytes } from './InferenceWire';
import { sanitizeModelOutput } from './Utf8Repair';

// Must equal the native session max_ctx in gewu_probe.cpp.
const MAX_CONTEXT = 32768;
// 播报给聊天端的输出上限：按云端后端（CloudChat 钳 8192、约 75s 生成）定；
// 本地 GEWU 在 LocalChat 内自钳 2048，不受影响。
const MAX_OUTPUT = 4096;
const MAX_PROMPT_BYTES = 32768;
// Time reserved after native generation stops to abort, tear down and still
// deliver infer.error before the requester's own deadline expires.
const REPORT_MARGIN_MS = 10000;
const MIN_WAIT_SECONDS = 10;

/** Mirrors one accepted infer request onto the compute task rail. */
export class InferCardHooks {
  phase: (requestId: string, epoch: number, phase: string) => void =
    (_requestId: string, _epoch: number, _phase: string): void => {};
  metrics: (requestId: string, epoch: number, metrics: InferenceMetrics) => void =
    (_requestId: string, _epoch: number, _metrics: InferenceMetrics): void => {};
  begin: (requestId: string, epoch: number, prompt: string, label: string) => void =
    (_requestId: string, _epoch: number, _prompt: string, _label: string): void => {};
  delta: (requestId: string, epoch: number, answer: string, outputAt?: number) => void =
    (_requestId: string, _epoch: number, _answer: string, _outputAt?: number): void => {};
  end: (requestId: string, epoch: number, answer: string, failed: boolean) => void =
    (_requestId: string, _epoch: number, _answer: string, _failed: boolean): void => {};
}

function requestMessages(message: WireMessage): ChatMessage[] {
  const split: WireChatMessage[] | undefined = message.messages;
  if (split !== undefined && split.length > 0) {
    return split.map((item: WireChatMessage): ChatMessage => ({ role: item.role, content: item.content }));
  }
  return [{ role: 'user', content: message.prompt || '' }];
}

function messageBytes(messages: ChatMessage[]): number {
  let total = 0;
  for (const message of messages) {
    total += utf8Bytes(message.content).length;
  }
  return total;
}

/** Native wait derived from the requester's deadline; 0 keeps the native default. */
function waitSeconds(deadlineMs: number | undefined): number {
  if (typeof deadlineMs !== 'number' || !Number.isInteger(deadlineMs) || deadlineMs <= 0) {
    return 0;
  }
  return Math.max(MIN_WAIT_SECONDS, Math.floor((deadlineMs - REPORT_MARGIN_MS) / 1000));
}

class HostRequest {
  metrics?: InferenceMetrics;
  key: string = '';
  requestId: string = '';
  epoch: number = 0;
  modelRequestId: string = '';
  seq: number = 0;
  answer: string = '';
  promptText: string = '';
  cancelled: boolean = false;
  dropped: boolean = false;
  startedAt: number = Date.now();
  statusSent: boolean = false;
  vision: boolean = false;
}

export class InferenceHost implements RelayLocal {
  private model: ChatBackend;
  private vision: LlmTransport | null = null;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private card: InferCardHooks;
  private requests: Map<string, HostRequest> = new Map();
  private requestSerial: number = 0;
  private clusterProvider: (() => ClusterInfo | null) | null = null;
  private deviceProvider: (() => string) | null = null;

  constructor(model: ChatBackend, sender: (message: WireMessage, epoch: number) => Promise<boolean>,
    card: InferCardHooks) {
    this.model = model;
    this.sender = sender;
    this.card = card;
  }

  /** Compute hub only: lets capabilities report the whole cluster, not just this device. */
  setClusterProvider(provider: (() => ClusterInfo | null) | null): void {
    this.clusterProvider = provider;
  }

  setDeviceProvider(provider: () => string): void { this.deviceProvider = provider; }

  setVisionTransport(transport: LlmTransport | null): void { this.vision = transport; }

  /** True from acceptance until the terminal infer.done / infer.error. */
  isActive(): boolean {
    return this.requests.size > 0;
  }

  activeCount(): number { return this.requests.size; }

  hasRequest(requestId: string, epoch: number): boolean {
    return this.requests.has(epoch.toString() + ':' + requestId);
  }

  handle(message: WireMessage, epoch: number): void {
    if (message.type === 'infer.capabilities.get') {
      this.replyCapabilities(message.requestId || '', epoch);
      return;
    }
    if (message.type === 'infer.request') {
      this.acceptRequest(message, epoch);
      return;
    }
    if (message.type === 'infer.cancel') {
      const request = this.requests.get(epoch.toString() + ':' + (message.requestId || ''));
      if (request !== undefined) { this.cancel(request); }
    }
  }

  /** The requester can no longer receive output: stop generating for it. */
  peerDropped(epoch: number): void {
    for (const request of Array.from(this.requests.values())) {
      if (request.epoch !== epoch) continue;
      hilog.warn(0, 'NearbyChat', 'infer peer dropped request=%{public}s epoch=%{public}d', request.requestId, epoch);
      request.dropped = true;
      this.cancel(request);
    }
  }

  private cancel(request: HostRequest): void {
    if (this.requests.get(request.key) !== request || request.cancelled) return;
    request.cancelled = true;
    if (request.vision) { this.vision?.cancel(request.modelRequestId); }
    else { this.model.cancel(request.modelRequestId); }
  }

  private send(message: WireMessage, epoch: number, onFailure?: () => void): void {
    let pending: Promise<boolean>;
    try {
      pending = this.sender(message, epoch);
    } catch (_error) {
      pending = Promise.resolve(false);
    }
    pending.then((sent: boolean): void => {
      if (sent) {
        return;
      }
      hilog.warn(0, 'NearbyChat', 'infer send failed type=%{public}s request=%{public}s',
        message.type, message.requestId || '');
      if (onFailure !== undefined) {
        onFailure();
      }
    }).catch((_error: Error): void => {
      if (onFailure !== undefined) {
        onFailure();
      }
    });
  }

  private replyCapabilities(requestId: string, epoch: number): void {
    const missing = this.model.readinessError();
    const cluster = this.clusterProvider === null ? null : this.clusterProvider();
    // The hub can serve through another device even when its own model is unavailable.
    const ready = missing.length === 0 || (this.vision !== null && this.vision.readinessError().length === 0) ||
      (cluster !== null && cluster.total > 0);
    const profile: InferProfile = {
      modelId: 'qwen25-7b-instruct-q4',
      modelRevision: 'admission-open',
      promptFormat: 'loop-react-split-v1',
      maxContextTokens: MAX_CONTEXT,
      maxOutputTokens: MAX_OUTPUT,
      maxPromptBytes: MAX_PROMPT_BYTES,
      maxWireBytes: 65536,
      tokenBudgetMode: 'certified-conservative',
      streaming: true,
      cancellation: true,
      ready: ready,
      readinessReason: ready ? '不按上下文长度拒绝请求，Gate B 尚未认证' : missing,
      maxCtx: MAX_CONTEXT,
      gateBPassed: false,
      splitMessages: true
    };
    if (cluster !== null) {
      profile.cluster = cluster;
    }
    this.send({
      type: 'infer.capabilities', version: 2, requestId: requestId, profiles: [profile]
    }, epoch);
  }

  private acceptRequest(message: WireMessage, epoch: number): void {
    const requestId = message.requestId || '';
    if (this.hasRequest(requestId, epoch)) {
      this.fail(requestId, epoch, 'DUPLICATE_REQUEST', '请求编号重复', false);
      return;
    }
    const messages = requestMessages(message);
    const prompt = messages[messages.length - 1].content;
    const image = message.image || '';
    const vision = this.vision;
    // The VL engine is single-session and shares memory with the text engine.
    if (Array.from(this.requests.values()).some((item: HostRequest): boolean => item.vision) ||
      (image.length > 0 && this.model.hasPendingNativeJobs()) || QwenVlManager.getInstance().isBusy()) {
      this.fail(requestId, epoch, 'BUSY', '算力繁忙，请稍后重试', true);
      return;
    }
    if (messageBytes(messages) > MAX_PROMPT_BYTES) {
      this.fail(requestId, epoch, 'PAYLOAD_TOO_LARGE', '本轮输入超过传输限制', false);
      return;
    }
    if (image.length > 0) {
      // 带图必须走多模态通道：VL 权重未部署时 fail closed，绝不降级给纯文本引擎。
      if (vision === null) {
        this.fail(requestId, epoch, 'MODEL_UNAVAILABLE', '本地模型不支持图片理解。', true);
        return;
      }
      const visionMissing = vision.readinessError();
      if (visionMissing.length > 0) {
        this.fail(requestId, epoch, 'MODEL_UNAVAILABLE', visionMissing, true);
        return;
      }
    } else {
      // 任务切到纯文本：先卸载驻留的 VL 权重（约 5.3GB）。否则 GEWU 再加载 5.8GB 文本模型
      // 会超过本机内存，被系统低内存杀手杀掉进程（真机实测 LOW_MEMORY_KILL）。
      QwenVlManager.getInstance().unloadIfIdle();
      const missing = this.model.readinessError();
      if (missing.length > 0) {
        this.fail(requestId, epoch, 'MODEL_UNAVAILABLE', missing, true);
        return;
      }
    }
    const request = new HostRequest();
    request.key = epoch.toString() + ':' + requestId;
    request.requestId = requestId;
    request.epoch = epoch;
    request.modelRequestId = 'infer:' + (++this.requestSerial).toString();
    request.promptText = messages.map((item: ChatMessage): string => item.content).join('\n');
    request.vision = image.length > 0;
    this.requests.set(request.key, request);
    hilog.info(0, 'NearbyChat', 'infer begin request=%{public}s epoch=%{public}d native=%{public}s active=%{public}d',
      requestId, epoch, request.modelRequestId, this.requests.size);
    try {
      this.card.begin(requestId, epoch, prompt, message.label !== undefined ? message.label : '');
    } catch (_error) {
      hilog.warn(0, 'NearbyChat', 'infer card begin failed request=%{public}s', requestId);
    }
    this.send({ type: 'infer.accepted', version: 2, requestId: requestId, state: 'preparing',
      device: this.deviceProvider === null ? undefined : this.deviceProvider() }, epoch,
      (): void => this.cancel(request));
    this.send({ type: 'infer.status', version: 2, requestId: requestId, state: 'loading' }, epoch);
    let error = '';
    try {
      if (image.length > 0 && vision !== null) {
        error = vision.start(messages, (update: ChatUpdate): void => this.onUpdate(request, update),
          request.modelRequestId, image);
      } else {
        error = this.model.start(messages, (update: ChatUpdate): void => {
          this.onUpdate(request, update);
        }, request.modelRequestId, {
          maxTokens: message.maxOutputTokens,
          waitSeconds: waitSeconds(message.deadlineBudgetMs)
        });
      }
    } catch (_error) {
      error = '无法启动模型，请确认模型文件已部署。';
    }
    if (error.length === 0) {
      try { this.card.phase(requestId, epoch, 'running'); } catch (_) { /* display only */ }
    }
    if (error.length > 0) {
      this.finishError(request, 'MODEL_EXECUTION_FAILED', error, true);
    }
  }

  private onUpdate(request: HostRequest, update: ChatUpdate): void {
    if (this.requests.get(request.key) !== request) {
      return;
    }
    if (update.metrics !== undefined) {
      request.metrics = update.metrics;
      try { this.card.metrics(request.requestId, request.epoch, update.metrics); } catch (_) { /* display only */ }
    }
    if (update.kind === 'delta') {
      if (request.cancelled) return;
      if (update.text.length === 0) return;
      if (request.seq === 0) {
        hilog.info(0, 'NearbyChat', 'infer output request=%{public}s epoch=%{public}d elapsedMs=%{public}d chars=%{public}d',
          request.requestId, request.epoch, Date.now() - request.startedAt, update.text.length);
      }
      if (!request.statusSent) {
        request.statusSent = true;
        this.send({ type: 'infer.status', version: 2, requestId: request.requestId, state: 'generating' }, request.epoch);
      }
      const pieces = splitUtf8(sanitizeModelOutput(update.text, request.promptText), 1024);
      for (const piece of pieces) {
        request.seq += 1;
        request.answer += piece;
        // A lost delta makes the stream undeliverable; generating further is wasted work.
        this.send({
          type: 'infer.delta', version: 2, requestId: request.requestId, seq: request.seq, text: piece,
          metrics: request.seq === 1 ? request.metrics : undefined
        }, request.epoch, (): void => this.cancel(request));
      }
      try {
        this.card.delta(request.requestId, request.epoch, sanitizeModelOutput(request.answer, request.promptText), update.outputAt);
      } catch (_error) {
        hilog.warn(0, 'NearbyChat', 'infer card delta failed request=%{public}s', request.requestId);
      }
      return;
    }
    if (update.error || request.cancelled || update.finishReason === 'cancelled' || request.answer.trim().length === 0 || request.seq < 1) {
      const cancelled = request.cancelled || update.finishReason === 'cancelled';
      this.finishError(request, cancelled ? 'CANCELLED' : 'MODEL_EXECUTION_FAILED',
        cancelled ? '已停止；已开始的外部操作未必可撤销' : (update.error || '模型加载、提交或清理失败'), !cancelled);
      return;
    }
    const reason = update.finishReason === 'length' ? 'length' : 'stop';
    const bytes = utf8Bytes(request.answer);
    hilog.info(0, 'NearbyChat', 'infer done request=%{public}s bytes=%{public}d reason=%{public}s',
      request.requestId, bytes.length, reason);
    this.requests.delete(request.key);
    this.send({
      type: 'infer.done', version: 2, requestId: request.requestId, lastSeq: request.seq,
      outputUtf8Bytes: bytes.length, outputSha256: sha256Hex(bytes), finishReason: reason, source: 'mate70-local',
      metrics: request.metrics
    }, request.epoch);
    this.endCard(request, false);
  }

  private finishError(request: HostRequest, code: string, text: string, retryable: boolean): void {
    if (this.requests.get(request.key) !== request) return;
    this.requests.delete(request.key);
    if (!request.dropped) { this.fail(request.requestId, request.epoch, code, text, retryable); }
    this.endCard(request, true);
  }

  private endCard(request: HostRequest, failed: boolean): void {
    try {
      this.card.end(request.requestId, request.epoch, sanitizeModelOutput(request.answer, request.promptText), failed);
    } catch (_error) {
      hilog.warn(0, 'NearbyChat', 'infer card end failed request=%{public}s', request.requestId);
    }
  }

  private fail(requestId: string, epoch: number, code: string, text: string, retryable: boolean): void {
    hilog.warn(0, 'NearbyChat', 'infer error code=%{public}s request=%{public}s', code, requestId);
    this.send({
      type: 'infer.error', version: 2, requestId: requestId, code: code, message: text, retryable: retryable
    }, epoch);
  }
}
