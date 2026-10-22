import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage as WireChatMessage, ClusterInfo, InferProfile, WireMessage } from '../protocol/ChatProtocol';
import { ChatBackend, ChatMessage, ChatUpdate } from './LocalChat';
import { LlmTransport } from './LlmTransport';
import { QwenVlManager } from './QwenVlManager';
import { RelayLocal } from './InferenceRelay';
import { sha256Hex, splitUtf8, utf8Bytes } from './InferenceWire';
import { repairUtf8FromSource } from './Utf8Repair';

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
  begin: (requestId: string, epoch: number, prompt: string, label: string) => void =
    (_requestId: string, _epoch: number, _prompt: string, _label: string): void => {};
  delta: (requestId: string, epoch: number, answer: string) => void = (_requestId: string, _epoch: number, _answer: string): void => {};
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

function outputBudget(requested: number | undefined): number {
  return typeof requested === 'number' && Number.isInteger(requested) && requested > 0 ?
    Math.min(MAX_OUTPUT, requested) : MAX_OUTPUT;
}

/** Native wait derived from the requester's deadline; 0 keeps the native default. */
function waitSeconds(deadlineMs: number | undefined): number {
  if (typeof deadlineMs !== 'number' || !Number.isInteger(deadlineMs) || deadlineMs <= 0) {
    return 0;
  }
  return Math.max(MIN_WAIT_SECONDS, Math.floor((deadlineMs - REPORT_MARGIN_MS) / 1000));
}

export class InferenceHost implements RelayLocal {
  private model: ChatBackend;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private card: InferCardHooks;
  private activeId: string = '';
  private activeEpoch: number = 0;
  private seq: number = 0;
  private answer: string = '';
  /** 本请求是否已报过 generating（每请求重置一次，避免刷屏）。 */
  private statusSent: boolean = false;
  private promptText: string = '';
  private clusterProvider: (() => ClusterInfo | null) | null = null;
  /** 可缺省的多模态通道；为 null 时带图请求 fail closed，绝不降级给纯文本引擎。 */
  private vision: LlmTransport | null = null;

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

  /** 由页面注入多模态通道；未部署 VL 权重时传 null。 */
  setVisionTransport(transport: LlmTransport | null): void {
    this.vision = transport;
  }

  /** True from acceptance until the terminal infer.done / infer.error. */
  isActive(): boolean {
    return this.activeId.length > 0;
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
    if (message.type === 'infer.cancel' && message.requestId === this.activeId) {
      this.model.cancel(this.activeId);
    }
  }

  /** The requester can no longer receive output: stop generating for it. */
  peerDropped(epoch: number): void {
    if (this.activeId.length === 0 || this.activeEpoch !== epoch) {
      return;
    }
    hilog.warn(0, 'NearbyChat', 'infer peer dropped request=%{public}s epoch=%{public}d', this.activeId, epoch);
    this.model.cancel(this.activeId);
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
    const ready = missing.length === 0 || (cluster !== null && cluster.total > 0);
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
    const messages = requestMessages(message);
    const prompt = messages[messages.length - 1].content;
    const image = message.image !== undefined ? message.image : '';
    const vision = this.vision;
    if (this.model.isBusy() || this.activeId.length > 0) {
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
    this.activeId = requestId;
    this.activeEpoch = epoch;
    this.seq = 0;
    this.answer = '';
    this.promptText = messages.map((item: ChatMessage): string => item.content).join('\n');
    this.card.begin(requestId, epoch, prompt, message.label !== undefined ? message.label : '');
    this.send({ type: 'infer.accepted', version: 2, requestId: requestId, state: 'preparing' }, epoch);
    // 请求级阶段上报：受理后先报 loading，首个 delta 到达时报 generating。
    // 目的是覆盖"加载权重 + prefill"那段静默（真机实测 GEWU 每步约 30s 才出首字）。
    // 注：warm 的 VL 引擎并不需要加载，这里会短暂多报一次 loading；待会话复用（P4）落地后，
    // 可由引擎的 warm 标志把它变成精确值。
    this.statusSent = false;
    this.send({ type: 'infer.status', version: 2, requestId: requestId, state: 'loading' }, epoch);
    let error: string;
    if (image.length > 0 && vision !== null) {
      error = vision.start(messages, (update: ChatUpdate) => {
        this.onUpdate(requestId, update);
      }, requestId, image);
    } else {
      error = this.model.start(messages, (update: ChatUpdate) => {
        this.onUpdate(requestId, update);
      }, requestId, {
        maxTokens: outputBudget(message.maxOutputTokens),
        waitSeconds: waitSeconds(message.deadlineBudgetMs)
      });
    }
    if (error.length > 0) {
      this.activeId = '';
      this.fail(requestId, epoch, 'MODEL_EXECUTION_FAILED', error, true);
    }
  }

  private onUpdate(requestId: string, update: ChatUpdate): void {
    if (requestId !== this.activeId) {
      return;
    }
    if (update.kind === 'delta') {
      if (!this.statusSent) {
        this.statusSent = true;
        this.send({ type: 'infer.status', version: 2, requestId: requestId, state: 'generating' }, this.activeEpoch);
      }
      const pieces = splitUtf8(update.text, 1024);
      for (const piece of pieces) {
        this.seq += 1;
        this.answer += piece;
        // A lost delta makes the stream undeliverable; generating further is wasted work.
        this.send({
          type: 'infer.delta', version: 2, requestId: requestId, seq: this.seq, text: piece
        }, this.activeEpoch, (): void => {
          if (this.activeId === requestId) {
            this.model.cancel(requestId);
          }
        });
      }
      this.card.delta(requestId, this.activeEpoch, repairUtf8FromSource(this.answer, this.promptText));
      return;
    }
    const epoch = this.activeEpoch;
    this.activeId = '';
    if (update.error || update.finishReason === 'cancelled' || this.answer.trim().length === 0 || this.seq < 1) {
      const cancelled = update.finishReason === 'cancelled';
      this.fail(requestId, epoch, cancelled ? 'CANCELLED' : 'MODEL_EXECUTION_FAILED',
        cancelled ? '已停止；已开始的外部操作未必可撤销' : (update.error || '模型加载、提交或清理失败'), !cancelled);
      return;
    }
    const reason = update.finishReason === 'length' ? 'length' : 'stop';
    const bytes = utf8Bytes(this.answer);
    hilog.info(0, 'NearbyChat', 'infer done request=%{public}s bytes=%{public}d reason=%{public}s',
      requestId, bytes.length, reason);
    this.card.end(requestId, epoch, repairUtf8FromSource(this.answer, this.promptText), false);
    this.send({
      type: 'infer.done', version: 2, requestId: requestId, lastSeq: this.seq,
      outputUtf8Bytes: bytes.length, outputSha256: sha256Hex(bytes), finishReason: reason, source: 'mate70-local'
    }, epoch);
  }

  private fail(requestId: string, epoch: number, code: string, text: string, retryable: boolean): void {
    hilog.warn(0, 'NearbyChat', 'infer error code=%{public}s request=%{public}s', code, requestId);
    this.card.end(requestId, epoch, repairUtf8FromSource(this.answer, this.promptText), true);
    this.send({
      type: 'infer.error', version: 2, requestId: requestId, code: code, message: text, retryable: retryable
    }, epoch);
  }
}
