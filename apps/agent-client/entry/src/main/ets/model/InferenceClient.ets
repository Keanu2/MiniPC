import { hilog } from '@kit.PerformanceAnalysisKit';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { ChatMessage, ClusterInfo, InferProfile, TaskSnapshot, validTaskSnapshot, WireMessage } from '../protocol/ChatProtocol';
import { sha256Hex, utf8Bytes } from './InferenceWire';
import { repairUtf8FromSource } from './Utf8Repair';

const NEGOTIATE_MS = 10000;
const ACCEPTED_MS = 10000;
/**
 * 每个近场分片（480 字节）额外给的受理预算。
 * 带图请求约 50+ 分片 → 超时约 10s + 20s，避免"上传还没完就先判算力端未确认"。
 */
const ACCEPTED_PER_FRAME_MS = 400;
// Budget granted to the compute host. It stops generating and reports
// infer.error inside this window; DELIVERY_GRACE_MS covers that report's trip.
const DEADLINE_MS = 170000;
const DELIVERY_GRACE_MS = 15000;
// A cancelled request still occupies the host until it acknowledges the stop.
const STOP_ACK_MS = 8000;
// A request refused before acceptance (no idle device) may be re-issued; this bounds the waiting.
const RETRY_INTERVAL_MS = 1500;
const BUSY_WAIT_MS = 120000;
export const INFERENCE_STOPPED = '已停止生成';
const LINK_LOST = '连接已中断，请连接后重新发送。';
const BUSY_TEXT = '算力繁忙，请稍后重试';

/** Per-request observers; nothing global survives into the next request. */
export interface InferHooks {
  onStart?: () => void;
  onDelta?: (text: string) => void;
  /** The device that actually runs the request (compute hub reports it on acceptance). */
  onAccepted?: (device: string) => void;
  /**
   * 算力端的请求级阶段（`infer.status` 的 state：queued/loading/prefill/generating）。
   * 用来覆盖"加载权重 + prefill"那段静默 —— 真机实测文本路径首字要等约 30s。
   */
  onPhase?: (state: string) => void;
  /** Requests sharing an owner can be cancelled together without touching other owners. */
  owner?: string;
  /** Caption shown on the compute device's task card (≤64 chars). */
  label?: string;
  taskId?: string;
  subtaskId?: string;
}

interface TaskDelivery { snapshot: TaskSnapshot; epoch: number; attempts: number; }

/** Developer/user split of one ReAct prompt (loop-react-split-v1). */
export interface InferSplit {
  system: string;
  user: string;
}

class StreamState {
  requestId: string = '';
  prompt: string = '';
  owner: string = '';
  epoch: number = -1;
  next: number = 1;
  text: string = '';
  accepted: boolean = false;
  /** Start of the current attempt; the post-acceptance deadline counts from here. */
  started: number = 0;
  /** First dispatch, bounding how long a refused request may keep waiting for an idle device. */
  firstStarted: number = 0;
  hooks: InferHooks = {};
  messages: ChatMessage[] | undefined = undefined;
  /** 本轮附图（裸 base64）；重试沿用同一张图，故存在 state 上而非一次性参数。 */
  image: string = '';
  outputTokens: number = 0;
  resolve: ((value: string) => void) | null = null;
  reject: ((error: Error) => void) | null = null;
  timer: number = -1;
  /** Refused before acceptance; a retry timer owns the request until it is re-sent. */
  waiting: boolean = false;
  queuedSince: number = 0;
  retryTimer: number = -1;
}

class StopState {
  epoch: number = -1;
  timer: number = -1;
}

class InferenceClient {
  private profile: InferProfile | null = null;
  private profileEpoch: number = -1;
  private cluster: ClusterInfo | null = null;
  private negotiateId: string = '';
  private negotiateEpoch: number = -1;
  private negotiateTimer: number = -1;
  private negotiateWait: ((value: string) => void) | null = null;
  private negotiatePromise: Promise<string> | null = null;
  private serial: number = 1;
  // Request IDs must stay unique across app restarts: the host may still hold an old one.
  private instance: string = Date.now().toString(36) + Math.floor(Math.random() * 1679616).toString(36);
  /** Dispatched requests by their current wire id. */
  private calls: Map<string, StreamState> = new Map();
  /** Requests held back until the host acknowledged earlier stops. */
  private queued: StreamState[] = [];
  private stopping: Map<string, StopState> = new Map();
  /** Refused before acceptance (no idle device); re-sent later under a new wire id. */
  private waitingCalls: StreamState[] = [];
  private linkListener: (() => void) | null = null;
  private loadListener: (() => void) | null = null;
  private status: string = '正在检查模型能力';
  private broken: boolean = false;
  private taskEpochs: Map<string, number> = new Map();
  private taskQueue: Map<string, TaskDelivery> = new Map();
  private deliveringTasks: boolean = false;
  private taskDeliveryGeneration: number = 0;

  /** Bounded, coalesced display snapshots; never block or retry inference work. */
  publishTask(snapshot: TaskSnapshot): void {
    if (!validTaskSnapshot(snapshot) || !this.isReady() || this.profileEpoch < 0) return;
    let epoch = this.taskEpochs.get(snapshot.id);
    if (epoch === undefined) {
      epoch = this.profileEpoch;
      if (this.taskEpochs.size >= 64) this.taskEpochs.delete(Array.from(this.taskEpochs.keys())[0]);
      this.taskEpochs.set(snapshot.id, epoch);
    }
    if (epoch !== this.profileEpoch) return;
    this.taskQueue.set(snapshot.id, { snapshot: snapshot, epoch: epoch, attempts: 0 });
    this.deliverTasks();
  }

  private async deliverTasks(): Promise<void> {
    if (this.deliveringTasks) return;
    this.deliveringTasks = true;
    const generation = this.taskDeliveryGeneration;
    try {
      while (this.taskQueue.size > 0 && generation === this.taskDeliveryGeneration) {
        const id = Array.from(this.taskQueue.keys())[0];
        const delivery = this.taskQueue.get(id);
        this.taskQueue.delete(id);
        if (delivery === undefined || delivery.epoch !== this.profileEpoch) continue;
        let sent = false;
        try {
          sent = await nearbyChannel.send({ type: 'infer.task', version: 2, requestId: id, task: delivery.snapshot }, delivery.epoch);
        } catch (_error) { /* A display failure cannot fail a model request. */ }
        if (!sent && generation === this.taskDeliveryGeneration && delivery.attempts === 0 && delivery.epoch === this.profileEpoch && !this.taskQueue.has(id)) {
          delivery.attempts++;
          this.taskQueue.set(id, delivery);
        }
      }
    } finally { if (generation === this.taskDeliveryGeneration) this.deliveringTasks = false; }
  }

  /** Notified after the inference link state changed (for status chrome only). */
  setLinkListener(listener: (() => void) | null): void {
    this.linkListener = listener;
  }

  /** Notified when the compute cluster reports a different idle/total count. */
  setLoadListener(listener: (() => void) | null): void {
    this.loadListener = listener;
  }

  /** Idle/total modelled devices behind the compute hub; a single device when the host does not say. */
  clusterLoad(): ClusterInfo {
    if (this.cluster !== null) {
      return { idle: this.cluster.idle, total: this.cluster.total };
    }
    const ready = this.isReady();
    return { idle: ready && this.calls.size === 0 ? 1 : 0, total: ready ? 1 : 0 };
  }

  cancel(): void {
    this.cancelActive();
  }

  /** Stops every request of this client. */
  cancelActive(): void {
    if (this.negotiatePromise !== null) {
      this.finishNegotiate(INFERENCE_STOPPED);
    }
    this.cancelMatching((_state: StreamState): boolean => true);
  }

  /** Stops only the requests started by one owner (one sub-task's model). */
  cancelOwner(owner: string): void {
    this.cancelMatching((state: StreamState): boolean => state.owner === owner);
  }

  private cancelMatching(match: (state: StreamState) => boolean): void {
    const held = this.queued.filter(match);
    this.queued = this.queued.filter((state: StreamState): boolean => !match(state));
    for (const state of held) {
      state.reject?.(new Error(INFERENCE_STOPPED));
    }
    for (const state of Array.from(this.calls.values()).concat(this.waitingCalls).filter(match)) {
      // A refused request holds nothing on the host, so only dispatched ones need a stop.
      const hostHolds = !state.waiting;
      // Settle locally first: a disconnected channel must not strand callers.
      this.fail(state, INFERENCE_STOPPED);
      if (hostHolds) {
        this.requestHostStop(state);
      }
    }
  }

  bind(): void {
    nearbyChannel.setInferenceHandler((message: WireMessage, epoch: number): void => {
      this.onMessage(message, epoch);
    });
    nearbyChannel.setInferenceLinkHandler((droppedEpoch: number): void => {
      this.onLinkDropped(droppedEpoch);
    });
  }

  reset(): void {
    this.taskQueue.clear();
    this.taskDeliveryGeneration++;
    this.deliveringTasks = false;
    // Keep bounded epoch tombstones: a late cancelled run must not publish onto a new link.
    this.finishNegotiate(LINK_LOST);
    this.profile = null;
    this.profileEpoch = -1;
    this.cluster = null;
    this.broken = false;
    this.status = '正在检查模型能力';
    for (const state of Array.from(this.calls.values()).concat(this.waitingCalls)) {
      this.fail(state, LINK_LOST);
    }
    const held = this.queued;
    this.queued = [];
    for (const state of held) {
      state.reject?.(new Error(LINK_LOST));
    }
    this.clearAllStopping();
  }

  isReady(): boolean {
    return this.profile !== null && this.profile.ready;
  }

  /** True while a cancelled request has not yet been released by the host. */
  isStopping(): boolean {
    return this.stopping.size > 0;
  }

  promptBudgetBytes(): number {
    if (this.profile === null || !Number.isInteger(this.profile.maxPromptBytes) ||
      this.profile.maxPromptBytes <= 0) {
      throw new Error('算力端尚未提供有效的输入预算');
    }
    return Math.min(32768, this.profile.maxPromptBytes);
  }

  failed(): boolean {
    return this.broken;
  }

  statusText(): string {
    return this.status;
  }

  ensureReady(): Promise<string> {
    if (!nearbyChannel.inferenceReady()) {
      this.broken = true;
      this.status = '算力端版本不支持';
      return Promise.resolve(this.status);
    }
    if (this.isReady()) {
      this.status = '已就绪';
      return Promise.resolve('');
    }
    if (this.negotiatePromise !== null) {
      return this.negotiatePromise;
    }
    const requestId = this.nextId('cap');
    this.negotiateId = requestId;
    this.negotiateEpoch = nearbyChannel.readyEpoch();
    this.status = '正在检查模型能力';
    this.broken = false;
    const result = new Promise<string>((resolve: (value: string) => void) => {
      this.negotiateWait = resolve;
    });
    this.negotiatePromise = result;
    this.negotiateTimer = setTimeout(() => {
      this.finishNegotiate('算力端版本不支持');
    }, NEGOTIATE_MS);
    this.deliver({ type: 'infer.capabilities.get', version: 2, requestId: requestId }, this.negotiateEpoch,
      (): void => {
        if (this.negotiateId === requestId) {
          this.finishNegotiate(LINK_LOST);
        }
      });
    return result;
  }

  /**
   * Sends one completion. A request issued while an earlier one is still
   * being stopped waits for the host's acknowledgement instead of being
   * rejected as busy. Several requests may be in flight at once.
   */
  complete(prompt: string, hooks: InferHooks = {}, split: InferSplit | null = null,
    image: string = ''): Promise<string> {
    if (!this.isReady() || this.profile === null) {
      return Promise.reject(new Error('算力端版本不支持'));
    }
    const profile = this.profile;
    // ReAct turns need room for a multi-line Action/Final. Respect the negotiated
    // capacity, with a conservative upper bound against unbounded generation
    // (4096：云侧推理模型思考占预算，2048 会截断复杂回答；4096 ≈ 75s 生成，
    // 留在配置的 120s 读超时与 170s 客户端死线之内)。
    const outputTokens = Math.min(4096, profile.maxOutputTokens);
    hilog.info(0, 'NearbyChat', 'infer prompt chars=%{public}d ctx=%{public}d',
      prompt.length, profile.maxContextTokens);
    const messages: ChatMessage[] | undefined = profile.splitMessages === true && split !== null ?
      [{ role: 'developer', content: split.system }, { role: 'user', content: split.user }] : undefined;
    const promptBytes = messages === undefined ? utf8Bytes(prompt).length :
      utf8Bytes(messages[0].content).length + utf8Bytes(messages[1].content).length;
    const promptBudget = this.promptBudgetBytes();
    if (promptBytes > promptBudget) {
      return Promise.reject(new Error('本轮必要输入超过传输限制（' + promptBytes.toString() +
        '/' + promptBudget.toString() + ' bytes），未发送请求，请缩小任务或文件范围'));
    }
    const state = new StreamState();
    state.prompt = prompt;
    state.owner = hooks.owner !== undefined ? hooks.owner : '';
    state.hooks = hooks;
    state.messages = messages;
    state.image = image;
    state.outputTokens = outputTokens;
    const result = new Promise<string>((resolve: (value: string) => void, reject: (error: Error) => void) => {
      state.resolve = resolve;
      state.reject = reject;
    });
    if (this.stopping.size > 0) {
      this.queued.push(state);
      return result;
    }
    this.start(state);
    return result;
  }

  /**
   * 受理超时：**随请求载荷缩放**。
   *
   * 原先固定 `ACCEPTED_MS`（10s），但带图请求要传约 24000 字符 base64（≈50+ 分片），
   * 而算力端只有在**完整重组出请求之后**才会回 `infer.accepted` —— 上传一旦超过 10s，
   * 聊天端就先判「算力端未确认本次请求」并放弃，而算力端浑然不知地跑完推理，
   * 结果没有任何人展示（真机实测）。这里按分片数给传输留预算。
   */
  private acceptanceMs(state: StreamState): number {
    let bytes = state.image.length;
    if (state.messages !== undefined) {
      for (const item of state.messages) {
        bytes += utf8Bytes(item.content).length;
      }
    } else {
      bytes += utf8Bytes(state.prompt).length;
    }
    const frames = Math.ceil((bytes + 256) / 480);   // 分片 480 字节，与 ChatProtocol 对齐
    return ACCEPTED_MS + ACCEPTED_PER_FRAME_MS * frames;
  }

  /** First dispatch of a call: fires onStart once, then sends. */
  private start(state: StreamState): void {
    state.firstStarted = Date.now();
    if (!this.send(state)) {
      return;
    }
    const begin = state.hooks.onStart;
    if (begin !== undefined) {
      begin();
    }
  }

  /** Sends (or re-sends) one attempt under a fresh wire id. Returns false when it failed immediately. */
  private send(state: StreamState): boolean {
    const profile = this.profile;
    if (profile === null) {
      this.fail(state, '算力端版本不支持');
      return false;
    }
    if (state.waiting) this.publishWaiting(state, false);
    if (state.requestId.length > 0) {
      this.calls.delete(state.requestId);
    }
    const requestId = this.nextId('req');
    state.requestId = requestId;
    state.epoch = nearbyChannel.readyEpoch();
    state.started = Date.now();
    state.next = 1;
    state.text = '';
    state.accepted = false;
    state.waiting = false;
    this.calls.set(requestId, state);
    clearTimeout(state.timer);
    state.timer = setTimeout(() => {
      this.expire(requestId);
    }, this.acceptanceMs(state));
    const request: WireMessage = {
      type: 'infer.request', version: 2, requestId: requestId,
      clientInstanceId: 'loopchat', agentRunId: this.nextId('run'),
      modelId: profile.modelId, modelRevision: profile.modelRevision, promptFormat: profile.promptFormat,
      maxOutputTokens: state.outputTokens, deadlineBudgetMs: DEADLINE_MS
    };
    if (state.hooks.label !== undefined && state.hooks.label.length > 0) {
      request.label = state.hooks.label.substring(0, 64);
    }
    if (state.hooks.taskId !== undefined && state.hooks.subtaskId !== undefined) {
      request.taskId = state.hooks.taskId;
      request.subtaskId = state.hooks.subtaskId;
    }
    if (state.messages !== undefined) {
      request.messages = state.messages;
    } else {
      request.prompt = state.prompt;
    }
    // 附图（裸 base64）只在确有图片时挂字段：值为空串也会成为键，
    // 会被算力端 validInference 的 hasOnly 判为未知字段而拒收。
    if (state.image.length > 0) {
      request.image = state.image;
    }
    return this.deliver(request, state.epoch, (): void => {
      if (this.calls.get(requestId) === state) {
        this.fail(state, LINK_LOST);
      }
    });
  }

  /** Returns false when the send failed synchronously (failure already handled). */
  private deliver(message: WireMessage, epoch: number, onFailure: () => void): boolean {
    let sent: Promise<boolean>;
    try {
      sent = epoch >= 0 ? nearbyChannel.send(message, epoch) : nearbyChannel.send(message);
    } catch (_error) {
      onFailure();
      return false;
    }
    Promise.resolve(sent).then((value: boolean): void => {
      if (value === false) {
        hilog.warn(0, 'NearbyChat', 'infer send failed type=%{public}s', message.type);
        onFailure();
      }
    }).catch((_error: Error): void => onFailure());
    return true;
  }

  /** Asks the host to stop and holds new requests until it confirms. */
  private requestHostStop(state: StreamState): void {
    const requestId = state.requestId;
    if (requestId.length === 0) {
      return;
    }
    this.clearStopping(requestId);
    const queued = this.deliver({ type: 'infer.cancel', version: 2, requestId: requestId }, state.epoch,
      (): void => {
        this.clearStopping(requestId);
      });
    if (!queued) {
      return;
    }
    const stop = new StopState();
    stop.epoch = state.epoch;
    stop.timer = setTimeout(() => {
      this.clearStopping(requestId);
    }, STOP_ACK_MS);
    this.stopping.set(requestId, stop);
  }

  private clearStopping(requestId: string): void {
    const stop = this.stopping.get(requestId);
    if (stop !== undefined) {
      clearTimeout(stop.timer);
      this.stopping.delete(requestId);
    }
    this.releaseQueued();
  }

  private clearAllStopping(): void {
    for (const stop of Array.from(this.stopping.values())) {
      clearTimeout(stop.timer);
    }
    this.stopping.clear();
    this.releaseQueued();
  }

  private releaseQueued(): void {
    if (this.stopping.size > 0 || this.queued.length === 0) {
      return;
    }
    const held = this.queued;
    this.queued = [];
    for (const state of held) {
      this.start(state);
    }
  }

  private onLinkDropped(epoch: number): void {
    for (const state of Array.from(this.calls.values())) {
      if (state.epoch < 0 || state.epoch === epoch) {
        this.fail(state, LINK_LOST);
      }
    }
    if (this.negotiatePromise !== null && (this.negotiateEpoch < 0 || this.negotiateEpoch === epoch)) {
      this.finishNegotiate(LINK_LOST);
    }
    for (const entry of Array.from(this.stopping.entries())) {
      if (entry[1].epoch < 0 || entry[1].epoch === epoch) {
        this.clearStopping(entry[0]);
      }
    }
    if (this.profile !== null && (this.profileEpoch < 0 || this.profileEpoch === epoch)) {
      // The next link may reach a different host build; negotiate again.
      this.profile = null;
      this.profileEpoch = -1;
      this.cluster = null;
      this.broken = false;
      this.status = '正在检查模型能力';
    }
    const listener = this.linkListener;
    if (listener !== null) {
      listener();
    }
  }

  private onMessage(message: WireMessage, epoch?: number): void {
    if (message.type === 'infer.capabilities' && this.negotiateId.length > 0 &&
      message.requestId === this.negotiateId) {
      const profiles = message.profiles;
      // Keep a structurally compatible but not-yet-ready profile so its
      // readinessReason remains visible to callers instead of being flattened
      // into the unrelated version-unsupported error.
      const compatible = profiles === undefined ? [] : profiles.filter((candidate: InferProfile): boolean =>
        candidate.promptFormat === 'loop-react-split-v1' &&
        Number.isInteger(candidate.maxPromptBytes) && candidate.maxPromptBytes > 0 &&
        Number.isInteger(candidate.maxOutputTokens) && candidate.maxOutputTokens > 0 &&
        Number.isInteger(candidate.maxContextTokens) && candidate.maxContextTokens > 0);
      const profile = compatible.find((candidate: InferProfile): boolean => candidate.ready === true) ?? compatible[0];
      if (profile === undefined) {
        this.finishNegotiate('算力端版本不支持');
        return;
      }
      this.profile = profile;
      this.profileEpoch = epoch !== undefined ? epoch : this.negotiateEpoch;
      this.cluster = profile.cluster !== undefined ? profile.cluster : null;
      this.broken = !profile.ready;
      const reason = typeof profile.readinessReason === 'string' && profile.readinessReason.length > 0 ?
        profile.readinessReason : '算力端尚未就绪';
      this.status = profile.ready ? '已就绪' : reason;
      this.finishNegotiate(profile.ready ? '' : reason);
      this.notifyLoad();
      return;
    }
    if (message.type === 'infer.status') {
      if (message.cluster !== undefined && (epoch === undefined || this.profileEpoch < 0 || epoch === this.profileEpoch)) {
        this.cluster = message.cluster;
        this.notifyLoad();
        this.retryWaiting();
      }
      // 请求级阶段：只派发给发起该请求的调用，用于直播气泡的阶段文案。
      // （infer.status 也被通道当作集群信息载体，那种帧没有 requestId，自然被这里忽略。）
      if (typeof message.state === 'string' && typeof message.requestId === 'string') {
        const pending = this.calls.get(message.requestId);
        if (pending !== undefined && pending.hooks.onPhase !== undefined) {
          pending.hooks.onPhase(message.state);
        }
      }
      return;
    }
    const requestId = message.requestId || '';
    if (this.stopping.has(requestId) && (message.type === 'infer.error' || message.type === 'infer.done')) {
      this.clearStopping(requestId);
      return;
    }
    const call = this.calls.get(requestId);
    if (call === undefined) {
      return;
    }
    // A reconnect gets a new epoch; output addressed to the old link is stale.
    if (epoch !== undefined && call.epoch >= 0 && epoch !== call.epoch) {
      return;
    }
    if (message.type === 'infer.accepted') {
      call.accepted = true;
      this.arm(call);
      const accepted = call.hooks.onAccepted;
      if (accepted !== undefined && typeof message.device === 'string' && message.device.length > 0) {
        accepted(message.device);
      }
      return;
    }
    if (message.type === 'infer.delta' && typeof message.seq === 'number' && typeof message.text === 'string') {
      if (message.seq !== call.next) {
        this.fail(call, '链路无法完整交付结果');
        this.requestHostStop(call);
        return;
      }
      call.text += message.text;
      call.next += 1;
      this.arm(call);
      const preview = call.hooks.onDelta;
      const shown = repairUtf8FromSource(call.text, call.prompt);
      if (preview !== undefined && shown.length > 0) {
        preview(shown);
      }
      return;
    }
    if (message.type === 'infer.done') {
      const bytes = utf8Bytes(call.text);
      const hash = sha256Hex(bytes);
      if (message.lastSeq !== call.next - 1 || message.outputUtf8Bytes !== bytes.length ||
        message.outputSha256 !== hash || call.text.trim().length === 0) {
        this.fail(call, '链路无法完整交付结果');
        return;
      }
      if (message.finishReason !== undefined && message.finishReason !== 'stop' &&
        message.finishReason !== 'end_turn' && message.finishReason !== 'eos' && message.finishReason !== 'completed') {
        this.fail(call, '回复未完整生成，未执行本轮新工具操作');
        return;
      }
      this.succeed(call, repairUtf8FromSource(call.text, call.prompt));
      return;
    }
    if (message.type === 'infer.error') {
      // Refused before acceptance because no device was idle: nothing ran, so waiting and
      // re-issuing is safe. Anything after acceptance may have run tools and is never replayed.
      const refused = !call.accepted && message.retryable === true &&
        (message.code === 'BUSY' || message.code === 'WORKER_LOST');
      if (refused && Date.now() - call.firstStarted < BUSY_WAIT_MS) {
        this.wait(call);
        return;
      }
      this.fail(call, refused ? BUSY_TEXT : (message.message || '模型加载、提交或清理失败'));
    }
  }

  private notifyLoad(): void {
    const listener = this.loadListener;
    if (listener !== null) {
      listener();
    }
  }

  /** Parks a refused request; it is re-sent on the next idle report or after RETRY_INTERVAL_MS. */
  private wait(state: StreamState): void {
    clearTimeout(state.timer);
    state.waiting = true;
    if (state.queuedSince === 0) state.queuedSince = Date.now();
    this.calls.delete(state.requestId);
    clearTimeout(state.retryTimer);
    state.retryTimer = setTimeout(() => {
      this.resend(state);
    }, RETRY_INTERVAL_MS);
    this.waitingCalls.push(state);
    this.publishWaiting(state, true);
  }

  /** Small optional display notice; old compute builds safely ignore it. */
  private publishWaiting(state: StreamState, queued: boolean): void {
    if (state.requestId.length === 0 || state.epoch < 0) return;
    try {
      nearbyChannel.send({ type: 'infer.status', version: 2, requestId: state.requestId,
        source: 'queue-display', state: queued ? 'queued' : 'cleared',
        text: String(Math.max(0, Date.now() - state.queuedSince)) }, state.epoch).catch((): void => {});
    } catch (_) { /* Display delivery never changes retry/cancellation behavior. */ }
  }

  private retryWaiting(): void {
    if (this.cluster === null || this.cluster.idle < 1) {
      return;
    }
    // Only as many as there are idle devices; the rest keep waiting for the next report.
    for (const state of this.waitingCalls.slice(0, this.cluster.idle)) {
      this.resend(state);
    }
  }

  private resend(state: StreamState): void {
    const index = this.waitingCalls.indexOf(state);
    if (index < 0 || !state.waiting) {
      return;
    }
    this.waitingCalls.splice(index, 1);
    clearTimeout(state.retryTimer);
    if (Date.now() - state.firstStarted >= BUSY_WAIT_MS) {
      this.publishWaiting(state, false);
      state.waiting = false;
      state.reject?.(new Error(BUSY_TEXT));
      return;
    }
    this.send(state);
  }

  private succeed(state: StreamState, text: string): void {
    if (this.calls.get(state.requestId) !== state) {
      return;
    }
    this.calls.delete(state.requestId);
    clearTimeout(state.timer);
    const sent = state.messages !== undefined ?
      'system=' + utf8Bytes(state.messages[0].content).length.toString() + ' user=' + utf8Bytes(state.messages[1].content).length.toString() :
      'prompt=' + utf8Bytes(state.prompt).length.toString();
    hilog.info(0, 'NearbyChat', 'infer complete bytes=%{public}d %{public}s elapsedMs=%{public}d',
      utf8Bytes(text).length, sent, Date.now() - state.firstStarted);
    state.resolve?.(text);
  }

  private fail(state: StreamState, text: string): void {
    const waiting = this.waitingCalls.indexOf(state);
    if (waiting >= 0) {
      this.waitingCalls.splice(waiting, 1);
    }
    const live = this.calls.get(state.requestId) === state;
    if (!live && !state.waiting) {
      return;
    }
    if (state.waiting) this.publishWaiting(state, false);
    this.calls.delete(state.requestId);
    state.waiting = false;
    clearTimeout(state.timer);
    clearTimeout(state.retryTimer);
    state.reject?.(new Error(text));
  }

  private expire(requestId: string): void {
    const call = this.calls.get(requestId);
    if (call === undefined) {
      return;
    }
    this.fail(call, call.accepted ? '本轮推理中断：算力端未在时限内返回结果，请重试' :
      '本轮推理中断：算力端未确认本次请求，请重试');
    this.requestHostStop(call);
  }

  private arm(state: StreamState): void {
    clearTimeout(state.timer);
    const remaining = Math.max(1000, DEADLINE_MS + DELIVERY_GRACE_MS - (Date.now() - state.started));
    const requestId = state.requestId;
    state.timer = setTimeout(() => {
      this.expire(requestId);
    }, remaining);
  }

  private finishNegotiate(text: string): void {
    this.clearNegotiate();
    const wait = this.negotiateWait;
    this.negotiateWait = null;
    this.negotiatePromise = null;
    this.negotiateId = '';
    this.negotiateEpoch = -1;
    if (text.length > 0) {
      this.broken = true;
      this.status = text;
    }
    if (wait !== null) {
      wait(text);
    }
  }

  private clearNegotiate(): void {
    if (this.negotiateTimer !== -1) {
      clearTimeout(this.negotiateTimer);
      this.negotiateTimer = -1;
    }
  }

  private nextId(prefix: string): string {
    const id = prefix + '-' + this.instance + '-' + String(this.serial);
    this.serial += 1;
    return id;
  }
}

export const inferenceClient: InferenceClient = new InferenceClient();
