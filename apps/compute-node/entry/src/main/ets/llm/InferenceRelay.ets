import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, ClusterInfo, WireMessage, InferenceMetrics } from '../protocol/ChatProtocol';
import { ComputeRouter, DispatchEntry } from '../cluster/ComputeRouter';
import { PoolNode, clusterLoad, meetsCapabilities, pickAvailableFor } from '../cluster/DevicePool';
import { stableSystem, taskHead } from './SessionReuse';
import { classifyFromMessages } from '../cluster/TaskRules';

/** Time the hub keeps for relaying; the worker gets the requester's budget minus this. */
const RELAY_MARGIN_MS = 5000;
const MIN_FORWARD_BUDGET_MS = 10000;

/** The hub's own inference host, as seen by the relay. */
export interface RelayLocal {
  handle(message: WireMessage, epoch: number): void;
  hasRequest?(requestId: string, epoch: number): boolean;
}

/** Task-card observers for requests that run on another device. */
export class RelayEvents {
  phase: (requestId: string, chatEpoch: number, phase: string) => void =
    (_requestId: string, _chatEpoch: number, _phase: string): void => {};
  metrics: (requestId: string, chatEpoch: number, metrics: InferenceMetrics) => void =
    (_requestId: string, _chatEpoch: number, _metrics: InferenceMetrics): void => {};
  begin: (requestId: string, chatEpoch: number, workerEpoch: number, messages: ChatMessage[], label: string) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _messages: ChatMessage[], _label: string): void => {};
  delta: (requestId: string, chatEpoch: number, answer: string) => void =
    (_requestId: string, _chatEpoch: number, _answer: string): void => {};
  end: (requestId: string, chatEpoch: number, answer: string, failed: boolean) => void =
    (_requestId: string, _chatEpoch: number, _answer: string, _failed: boolean): void => {};
  forward: (requestId: string, chatEpoch: number, workerEpoch: number, request: WireMessage) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _request: WireMessage): void => {};
}

/**
 * Compute-hub router for agent `infer.*` traffic.
 *
 * One chat request goes to exactly one ready device: the hub itself (handled by
 * its own host) or another compute device (forwarded under a hub-generated
 * forwardId). Replies are matched on forwardId, the worker is identified by its
 * link epoch, and the payload is passed through unchanged except for requestId,
 * so the requester's seq/length/sha256 checks keep covering the real output.
 *
 * A request that was never accepted is safe to re-issue (BUSY / WORKER_LOST are
 * retryable); once the worker has answered infer.accepted it is not.
 */
interface AffinityEntry { epoch: number; at: number; }
const AFFINITY_TTL_MS = 180000;
const AFFINITY_MAX = 16;
/** A request whose device was lost or failed before any output reached the requester is re-issued this many times. */
const MAX_REISSUE = 2;
/** Worker errors that mean "this device did not complete it", not "the request is bad". */
const REISSUE_CODES: string[] = ['CANCELLED', 'WORKER_LOST', 'MODEL_EXECUTION_FAILED'];

/** Same system part and task section (see SessionReuse) means the same run. */
function runFingerprint(message: WireMessage): string {
  const messages = message.messages;
  if (messages === undefined || messages.length !== 2) return '';
  const system = stableSystem(messages[0].content);
  const head = taskHead(messages[1].content);
  if (system.length === 0 || head.length === 0) return '';
  let hash = 0;
  const text = system + '\u0001' + head;
  for (let i = 0; i < text.length; i++) {
    hash = (hash * 31 + text.charCodeAt(i)) % 2147483647;
  }
  return hash.toString() + ':' + text.length.toString();
}

export class InferenceRelay {
  private router: ComputeRouter;
  private nodes: () => PoolNode[];
  private chats: () => number[];
  private local: RelayLocal;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private events: RelayEvents;
  private lastPublished: string = '';
  private speedCost: (epoch: number) => number = (_epoch: number): number => -1;
  private affinityOn: () => boolean = (): boolean => false;
  /** Run fingerprint -> the worker that served its last round. */
  private affinity: Map<string, AffinityEntry> = new Map();

  constructor(router: ComputeRouter, nodes: () => PoolNode[], chats: () => number[], local: RelayLocal,
    sender: (message: WireMessage, epoch: number) => Promise<boolean>, events: RelayEvents) {
    this.router = router;
    this.nodes = nodes;
    this.chats = chats;
    this.local = local;
    this.sender = sender;
    this.events = events;
  }

  /** Soft affinity: send the next round of a run to the device that holds its session, if idle. */
  setAffinity(enabled: () => boolean): void {
    this.affinityOn = enabled;
  }

  /** Measured cost per device (lower = faster, -1 = unknown); faster idle devices are preferred. */
  setSpeed(cost: (epoch: number) => number): void {
    this.speedCost = cost;
  }

  load(): ClusterInfo {
    // This profile feeds the chat client's text-Agent splitter, not a device inventory.
    const load = clusterLoad(this.nodes().filter((node: PoolNode): boolean => meetsCapabilities(node, ['text'])));
    return { idle: load.idle, total: load.total };
  }

  /** Message from a chat phone: infer.request, infer.cancel, infer.capabilities.get. */
  handleFromChat(message: WireMessage, chatEpoch: number): void {
    if (message.type === 'infer.request') {
      this.route(message, chatEpoch);
      return;
    }
    if (message.type === 'infer.cancel') {
      this.cancel(message, chatEpoch);
      return;
    }
    this.local.handle(message, chatEpoch);
  }

  /** Reply from a compute device that was handed a forwarded request. */
  handleFromWorker(message: WireMessage, workerEpoch: number): void {
    const forwardId = message.requestId || '';
    const entry = this.router.getByForwardId(forwardId);
    if (entry === undefined || !entry.infer || entry.workerEpoch !== workerEpoch) {
      return;
    }
    const origin = entry.originRequestId;
    if (message.metrics !== undefined) {
      try { this.events.metrics(origin, entry.originEpoch, message.metrics); } catch (_) { /* display only */ }
    }
    if (message.type === 'infer.accepted') {
      entry.accepted = true;
      this.events.phase(origin, entry.originEpoch, message.state === 'queued' ? 'queued' : 'running');
      this.toChat({ type: 'infer.accepted', version: 2, requestId: origin, state: message.state,
        device: entry.workerName }, entry);
      return;
    }
    if (message.type === 'infer.status') {
      if (['queued', 'preparing', 'loading', 'prefill', 'generating'].includes(message.state || '')) {
        this.events.phase(origin, entry.originEpoch, message.state === 'queued' ? 'queued' : 'running');
      }
      this.toChat({ type: 'infer.status', version: 2, requestId: origin, state: message.state }, entry);
      return;
    }
    if (message.type === 'infer.delta') {
      const text = message.text || '';
      entry.answer += text;
      this.toChat({ type: 'infer.delta', version: 2, requestId: origin, seq: message.seq, text: text,
        metrics: message.metrics }, entry);
      this.events.delta(origin, entry.originEpoch, entry.answer);
      return;
    }
    if (message.type === 'infer.done') {
      this.router.finishForward(forwardId);
      this.sendToChat({ type: 'infer.done', version: 2, requestId: origin, lastSeq: message.lastSeq,
        outputUtf8Bytes: message.outputUtf8Bytes, outputSha256: message.outputSha256,
        finishReason: message.finishReason, source: message.source, metrics: message.metrics }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, false);
      this.publishLoad();
      return;
    }
    if (message.type === 'infer.error') {
      this.router.finishForward(forwardId);
      if (REISSUE_CODES.includes(message.code || '') && this.reissue(entry, 'error ' + (message.code || ''))) return;
      this.sendToChat({ type: 'infer.error', version: 2, requestId: origin, code: message.code,
        message: message.message, retryable: message.retryable }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, true);
      this.publishLoad();
    }
  }

  /** The chat phone is gone: nothing can be delivered, so stop the remote work. */
  chatDropped(chatEpoch: number): void {
    for (const entry of this.router.dispatchesFromOrigin(chatEpoch)) {
      if (!entry.infer) continue;
      entry.cancelRequested = true;
      this.router.finishForward(entry.forwardId);
      this.sender({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
        .catch((_error: Error): void => {});
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** A compute device disappeared: fail what ran on it, retryable only if never accepted. */
  workerDropped(workerEpoch: number): void {
    for (const entry of this.router.dispatchesFor(workerEpoch)) {
      if (!entry.infer) continue;
      this.router.finishForward(entry.forwardId);
      if (this.reissue(entry, 'worker lost')) continue;
      this.sendToChat({ type: 'infer.error', version: 2, requestId: entry.originRequestId, code: 'WORKER_LOST',
        message: '执行设备 ' + entry.workerName + ' 已断开', retryable: !entry.accepted }, entry.originEpoch, null);
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** Pushes infer.status to every chat phone, only when the numbers changed. */
  publishLoad(): void {
    const load = this.load();
    const key = String(load.idle) + '/' + String(load.total);
    if (key === this.lastPublished) return;
    this.lastPublished = key;
    for (const epoch of this.chats()) {
      this.sender({ type: 'infer.status', version: 2, requestId: 'cluster', cluster: load }, epoch)
        .catch((_error: Error): void => {});
    }
  }

  private route(message: WireMessage, chatEpoch: number): void {
    const id = message.requestId || '';
    if (this.router.getDispatch(id, chatEpoch) !== undefined || this.local.hasRequest?.(id, chatEpoch) === true) {
      this.refuse(id, chatEpoch, 'DUPLICATE_REQUEST', '请求编号重复', false);
      return;
    }
    // 从请求本身推导能力需求（不改协议：infer.request 的白名单没变）。
    // 带图 ⇒ 执行节点必须具备 vision；否则按纯文本。
    const needs: string[] = message.image !== undefined && message.image.length > 0 ?
      ['vision'] : ['text'];
    const messages: ChatMessage[] = message.messages !== undefined ? message.messages :
      [{ role: 'user', content: message.prompt || '' }];
    // 档位与执行端同规则重算：消息经 forwardCopy 逐字转发，两侧输入一致、结果
    // 一致——hub 用它选设备，执行端用它选本机模型目录（预算不参与定档，见 TaskRules）。
    const profile = classifyFromMessages(messages, needs.indexOf('vision') >= 0);
    const pool = this.nodes();
    const fingerprint = this.affinityOn() ? runFingerprint(message) : '';
    const preferred = fingerprint.length > 0 ? this.affinity.get(fingerprint) : undefined;
    const target = pickAvailableFor(pool, needs, profile.tier,
      preferred !== undefined && Date.now() - preferred.at < AFFINITY_TTL_MS ? preferred.epoch : -1, this.speedCost);
    if (target !== null && fingerprint.length > 0) this.remember(fingerprint, target.epoch);
    if (target === null) {
      // 区分「没有具备该能力的节点」（重试无意义）与「有但都忙」（可重试）。
      const capable = pool.some((item: PoolNode): boolean => meetsCapabilities(item, needs));
      hilog.info(0, 'NearbyChat', 'infer route miss request=%{public}s tier=%{public}d capable=%{public}s',
        id, profile.tier, String(capable));
      if (capable) {
        this.refuse(id, chatEpoch, 'BUSY', '算力繁忙，请稍后重试', true);
      } else {
        this.refuse(id, chatEpoch, 'MODEL_UNAVAILABLE', '没有可执行该任务的算力设备', false);
      }
      return;
    }
    this.dispatch(message, chatEpoch, target, [], 0);
  }

  /** Hands the request to the chosen device: this hub itself, or a worker under a new forwardId. */
  private dispatch(message: WireMessage, chatEpoch: number, target: PoolNode, tried: number[], attempts: number): void {
    const id = message.requestId || '';
    const messages: ChatMessage[] = message.messages !== undefined ? message.messages :
      [{ role: 'user', content: message.prompt || '' }];
    const profile = classifyFromMessages(messages, !!message.image);
    hilog.info(0, 'NearbyChat', 'infer route request=%{public}s chat=%{public}d device=%{public}s worker=%{public}d load=%{public}d',
      id, chatEpoch, target.label, target.epoch, target.inflight);
    if (target.isSelf) {
      hilog.info(0, 'NearbyChat', 'infer local request=%{public}s tier=%{public}d nodeTier=%{public}d',
        id, profile.tier, target.modelTier);
      this.local.handle(message, chatEpoch);
      this.publishLoad();
      return;
    }
    const entry = new DispatchEntry();
    entry.originEpoch = chatEpoch;
    entry.originRequestId = id;
    entry.workerEpoch = target.epoch;
    entry.workerName = target.label;
    entry.infer = true;
    entry.request = message;
    entry.tried = tried.concat([target.epoch]);
    entry.attempts = attempts;
    // Count before sending so the next request sees the updated load.
    const dispatch = this.router.beginDispatch(id, entry);
    const forwarded = this.forwardCopy(message, dispatch.forwardId);
    this.events.begin(id, chatEpoch, target.epoch, messages, message.label !== undefined ? message.label : '');
    this.events.forward(id, chatEpoch, target.epoch, forwarded);
    hilog.info(0, 'NearbyChat', 'infer relay request=%{public}s forward=%{public}s worker=%{public}d',
      id, dispatch.forwardId, target.epoch);
    this.sender(forwarded, target.epoch).then((sent: boolean): void => {
      if (!sent) this.forwardFailed(dispatch);
    }).catch((_error: Error): void => this.forwardFailed(dispatch));
    // This is hub admission, not worker execution. It stops the chat's upload-only
    // timeout while the second hop is still in flight. Never mark entry.accepted here:
    // worker-loss/reissue safety continues to depend on the worker's own reply.
    this.toChat({ type: 'infer.accepted', version: 2, requestId: id, state: 'queued',
      device: target.label }, dispatch);
    this.publishLoad();
  }

  /**
   * The device lost or failed this request before any output reached the requester. Inference has no
   * side effects, so it is safe to run again on another ready device that has not been tried.
   * Returns false (and does nothing) when that is not possible; the caller then reports the failure.
   */
  private reissue(entry: DispatchEntry, why: string): boolean {
    const request = entry.request as WireMessage | undefined;
    if (request === undefined || entry.cancelRequested || entry.answer.length > 0 || entry.attempts >= MAX_REISSUE) {
      return false;
    }
    const needs: string[] = request.image ? ['vision'] : ['text'];
    const profile = classifyFromMessages(request.messages || [{role: 'user', content: request.prompt || ''}], !!request.image);
    const target = pickAvailableFor(this.nodes().filter((node: PoolNode): boolean => !entry.tried.includes(node.epoch)),
      needs, profile.tier, -1, this.speedCost);
    if (target === null) return false;
    hilog.warn(0, 'NearbyChat', 'infer relay reissue request=%{public}s after %{public}s from=%{public}s to=%{public}s attempt=%{public}d',
      entry.originRequestId, why, entry.workerName, target.label, entry.attempts + 1);
    // The lost attempt's card closes as failed; the new attempt opens its own.
    this.events.end(entry.originRequestId, entry.originEpoch, '', true);
    this.dispatch(request, entry.originEpoch, target, entry.tried, entry.attempts + 1);
    return true;
  }

  private remember(fingerprint: string, epoch: number): void {
    this.affinity.delete(fingerprint);
    this.affinity.set(fingerprint, { epoch: epoch, at: Date.now() });
    while (this.affinity.size > AFFINITY_MAX) {
      const oldest = this.affinity.keys().next();
      if (oldest.done === true) break;
      this.affinity.delete(oldest.value as string);
    }
  }

  /** The send to the worker failed: the request never started there, so it is retryable. */
  private forwardFailed(dispatch: DispatchEntry): void {
    if (this.router.finishForward(dispatch.forwardId) === undefined) return;
    this.sendToChat({ type: 'infer.error', version: 2, requestId: dispatch.originRequestId, code: 'WORKER_LOST',
      message: '无法联系执行设备 ' + dispatch.workerName, retryable: !dispatch.accepted }, dispatch.originEpoch, null);
    this.events.end(dispatch.originRequestId, dispatch.originEpoch, dispatch.answer, true);
    this.publishLoad();
  }

  private cancel(message: WireMessage, chatEpoch: number): void {
    const entry = this.router.getDispatch(message.requestId || '', chatEpoch);
    if (entry === undefined || !entry.infer) {
      this.local.handle(message, chatEpoch);
      return;
    }
    entry.cancelRequested = true;
    // The worker answers with infer.error CANCELLED, which flows back through handleFromWorker.
    this.sender({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
      .then((sent: boolean): void => {
        if (!sent) this.forwardFailed(entry);
      }).catch((_error: Error): void => this.forwardFailed(entry));
  }

  private refuse(requestId: string, chatEpoch: number, code: string, text: string, retryable: boolean): void {
    this.sender({ type: 'infer.error', version: 2, requestId: requestId, code: code, message: text,
      retryable: retryable }, chatEpoch).catch((_error: Error): void => {});
  }

  private toChat(message: WireMessage, entry: DispatchEntry): void {
    this.sendToChat(message, entry.originEpoch, entry);
  }

  /** A lost reply makes the stream undeliverable, so stop the worker instead of letting it run on. */
  private sendToChat(message: WireMessage, chatEpoch: number, live: DispatchEntry | null): void {
    const failed = (): void => {
      if (live === null) return;
      if (this.router.finishForward(live.forwardId) === undefined) return;
      this.sender({ type: 'infer.cancel', version: 2, requestId: live.forwardId }, live.workerEpoch)
        .catch((_error: Error): void => {});
      this.events.end(live.originRequestId, live.originEpoch, live.answer, true);
      this.publishLoad();
    };
    let pending: Promise<boolean>;
    try {
      pending = this.sender(message, chatEpoch);
    } catch (_error) {
      failed();
      return;
    }
    pending.then((sent: boolean): void => {
      if (!sent) failed();
    }).catch((_error: Error): void => failed());
  }

  private forwardCopy(message: WireMessage, forwardId: string): WireMessage {
    const copy: WireMessage = { type: 'infer.request', version: 2, requestId: forwardId };
    if (message.clientInstanceId !== undefined) copy.clientInstanceId = message.clientInstanceId;
    if (message.agentRunId !== undefined) copy.agentRunId = message.agentRunId;
    if (message.modelId !== undefined) copy.modelId = message.modelId;
    if (message.modelRevision !== undefined) copy.modelRevision = message.modelRevision;
    if (message.promptFormat !== undefined) copy.promptFormat = message.promptFormat;
    if (message.prompt !== undefined) copy.prompt = message.prompt;
    if (message.messages !== undefined) copy.messages = message.messages;
    if (message.image !== undefined) copy.image = message.image;
    if (message.label !== undefined) copy.label = message.label;
    if (message.taskId !== undefined) copy.taskId = message.taskId;
    if (message.subtaskId !== undefined) copy.subtaskId = message.subtaskId;
    if (message.origin !== undefined) copy.origin = message.origin;
    if (message.maxOutputTokens !== undefined) copy.maxOutputTokens = message.maxOutputTokens;
    if (typeof message.deadlineBudgetMs === 'number') {
      copy.deadlineBudgetMs = Math.max(MIN_FORWARD_BUDGET_MS, message.deadlineBudgetMs - RELAY_MARGIN_MS);
    }
    return copy;
  }
}
