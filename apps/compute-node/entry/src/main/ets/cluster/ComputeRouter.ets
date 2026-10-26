/**
 * 算力选点与在途派发。对齐 modelshare ChatProxyService：
 * 负载 = 采样请求数与在途派发的较大者；有模型的节点里选负载最低、内存更大者。
 * MiniPC 本机可多路 session，因此满载仍可选本机，只有没有任何模型时才返回 null。
 *
 * 能力是硬门槛：请求 needs 的每一项都必须在节点 capabilities 里，不满足的节点
 * 直接出局，排在空闲/负载/内存/本机之前；没有任何合格节点返回 null（fail closed，
 * 绝不把请求降级给不具备能力的设备）。
 *
 * 强度档位是质量偏好（fail open）：节点 modelTier（1-2：1 弱、2 强，缺省 2）与
 * 任务 taskTier 的贴近程度只在负载平手时决胜（贴近再平手 → 档位就高不就低），然后才
 * 是内存与本机。它绝不排除节点、绝不改变可用性语义——强档忙时自然降档到空闲
 * 低档，全部合格节点都忙时行为与无档位完全一致。taskTier = 0（未分类）时所有
 * 档位比较恒平，选点与旧版逐字节等价。
 *
 * 任务分档（taskTier 的来源；规则本体在 TaskRules.ets，此处摘录备忘）：
 * 只看最后一条 user 消息（历史不参与，防止问过一次代码后连"你好"都判复杂），先剥掉
 * agent 脚手架标记，带图直接复杂档。先查复杂证据（H1-H5，任一命中 → 2）：
 * - H1 代码围栏（```）；
 * - H2 强代码词单个命中（写代码/函数/算法/递归/调试/报错…）；
 * - H2b 生成动词 × 代码名词共现（写/生成/实现… × 代码/快排/排序…，补短语级强代码词
 *   被定语隔开的缺口，如"生成Python快排代码"）；
 * - H3 弱代码词不同词 ≥2（import/def/python/sql…，单个不够复杂但足以否决简单）；
 * - H4 数学推理单个命中（证明/推导/解方程/微积分/架构设计…）；
 * - H5 长文生成（加权长度 ≥600 且含 总结/翻译/续写…）。
 * 再验简单条件（L1-L3 全过才是 1）：L1 加权长度 ≤160（ASCII 记 1、其余记 2）；
 * L2 无任何代码/数学/生成痕迹；L3 对话轮数 ≤3。其余一律 2（fail open：不确定按
 * 复杂处理，最坏是强模型答简单题，绝不反过来）。输出预算不参与定档。
 *
 * 派发身份分两层：
 * - originKey（来源会话 + 客户端 requestId）是这张卡片的身份，用来找回任务、回信给来源方；
 * - forwardId 是发给执行设备的 requestId。执行设备只会把它收到的 id 原样回传，
 *   所以回包必须按 forwardId 索引，不能按客户端 id——两个来源方用同一个 id 时就分不开了。
 */

export class ScheduleNode {
  epoch: number = 0;
  name: string = '';
  isSelf: boolean = false;
  model: string = '';
  /** 该节点模型可提供的能力（如 ['text', 'vision']）；未声明按纯文本处理。 */
  capabilities: string[] = ['text'];
  /** 部署模型声明的最高强度档位 1-2（1 弱、2 强）；老对端/未声明 → 2 强档。 */
  modelTier: number = 2;
  requests: number = -1;
  memAvail: number = -1;
}

export class DispatchEntry {
  originEpoch: number = 0;
  originRequestId: string = '';
  /** requestId actually sent to the worker; uniquely identifies this hand-off. */
  forwardId: string = '';
  workerEpoch: number = 0;
  workerName: string = '';
  /** True for an agent infer.* hand-off; false for the legacy chat request flow. */
  infer: boolean = false;
  /** The worker answered infer.accepted: the request is no longer safe to re-issue. */
  accepted: boolean = false;
  /** Streamed text so far, for the task card. */
  answer: string = '';
  /** The original request, kept so a lost hand-off can be re-issued to another device. */
  request: Object | undefined = undefined;
  /** Devices already tried for this request (never picked again), and how many re-issues happened. */
  tried: number[] = [];
  attempts: number = 0;
  /** The requester asked to stop (or went away): a cancellation is then not a failure to retry. */
  cancelRequested: boolean = false;
}

export function nodeLoad(node: ScheduleNode): number {
  return node.requests < 0 ? 0 : node.requests;
}

export function originKeyOf(epoch: number, requestId: string): string {
  return String(epoch) + ':' + requestId;
}

/**
 * Dispatch identity is the requesting session plus the wire request id. Two chat
 * devices (or one device that reconnected) can legitimately send the same id, and
 * keying the map on the id alone made one request overwrite the other.
 */
export function dispatchKey(entry: DispatchEntry): string {
  return originKeyOf(entry.originEpoch, entry.originRequestId);
}

/** 空需求沿用旧协议的文字请求语义；否则每一项都要在节点能力表里。 */
export function meetsNeeds(node: ScheduleNode, needs: string[]): boolean {
  if (needs.length === 0) return node.capabilities.indexOf('text') >= 0;
  for (const need of needs) {
    if (node.capabilities.indexOf(need) < 0) return false;
  }
  return true;
}

/** 档位归一：1 原样，其余（2 与旧构建上报的 3）→ 2 强档。 */
function tierOf(value: number): number {
  return value === 1 ? 1 : 2;
}

/**
 * 负载平手时的档位决胜：-1 = node 更优 / 0 = 平 / 1 = 更差。
 * 先比贴近（|档位 - taskTier| 最小），贴近再平手 → 档位就高不就低。
 * taskTier < 1（未分类）恒平，等价于无档位参与。
 */
function compareTier(node: ScheduleNode, best: ScheduleNode, taskTier: number): number {
  if (taskTier < 1) return 0;
  const nodeTier = tierOf(node.modelTier);
  const bestTier = tierOf(best.modelTier);
  const nodeClose = Math.abs(nodeTier - taskTier);
  const bestClose = Math.abs(bestTier - taskTier);
  if (nodeClose !== bestClose) return nodeClose < bestClose ? -1 : 1;
  if (nodeTier !== bestTier) return nodeTier > bestTier ? -1 : 1;
  return 0;
}

export function pickNode(nodes: ScheduleNode[], needs: string[] = [], taskTier: number = 0): ScheduleNode | null {
  let best: ScheduleNode | null = null;
  let bestLoad: number = Number.MAX_VALUE;
  for (const node of nodes) {
    if (node.model.length === 0 || !meetsNeeds(node, needs)) continue;
    const load = nodeLoad(node);
    if (best !== null && load >= 1 && bestLoad < 1) continue;
    if (best === null || load < bestLoad) {
      best = node;
      bestLoad = load;
      continue;
    }
    if (load > bestLoad) continue;
    // 负载平手：档位贴近决胜（贴近再平手 → 就高），仍平手回落内存/本机。
    const byTier = compareTier(node, best, taskTier);
    if (byTier < 0 || (byTier === 0 && (memAvailOf(node) > memAvailOf(best) ||
      (memAvailOf(node) === memAvailOf(best) && node.isSelf)))) {
      best = node;
      bestLoad = load;
    }
  }
  return best;
}

function memAvailOf(node: ScheduleNode): number {
  return node.memAvail < 0 ? 0 : node.memAvail;
}

/**
 * Experiment override. auto keeps pickNode. pin1/pin2 force this hub or the
 * other modeled compute. split sends the caller-chosen side: preferSelf is
 * decided by the hub so each chat stays on one device for the whole run.
 * needs gates the scan itself: a pinned side without the capability yields
 * null; split falls back to the other capable side.
 * 档位只参与 auto/默认分支：pin1/pin2/split 保持档位盲，实验纯净性不受声明影响。
 */
export function pickRoute(nodes: ScheduleNode[], mode: string, preferSelf: boolean,
  needs: string[] = [], taskTier: number = 0): ScheduleNode | null {
  if (mode === 'auto' || mode.length === 0) return pickNode(nodes, needs, taskTier);
  let self: ScheduleNode | null = null;
  let peer: ScheduleNode | null = null;
  for (const node of nodes) {
    if (node.model.length === 0 || !meetsNeeds(node, needs)) continue;
    if (node.isSelf) {
      self = node;
      continue;
    }
    if (peer === null || memAvailOf(node) > memAvailOf(peer)) peer = node;
  }
  if (mode === 'pin1') return self;
  if (mode === 'pin2') return peer;
  if (mode === 'split') {
    if (preferSelf) return self !== null ? self : peer;
    return peer !== null ? peer : self;
  }
  return pickNode(nodes, needs);
}

export class ComputeRouter {
  private byOrigin: Map<string, DispatchEntry> = new Map();
  /** Forwarded request id -> origin key. The worker echoes forwardId verbatim. */
  private byForward: Map<string, string> = new Map();
  private inflightByEpoch: Map<number, number> = new Map();
  private selfInflight: number = 0;
  private forwardSeq: number = 0;

  selfLoad(sampled: number): number {
    const live = sampled < 0 ? 0 : sampled;
    return live > this.selfInflight ? live : this.selfInflight;
  }

  workerLoad(epoch: number, sampled: number): number {
    const live = sampled < 0 ? 0 : sampled;
    const inflight = this.inflightByEpoch.get(epoch) ?? 0;
    return live > inflight ? live : inflight;
  }

  beginSelf(): void { this.selfInflight++; }
  endSelf(): void { this.selfInflight = Math.max(0, this.selfInflight - 1); }

  /** Unique per hand-off. Never a value the client itself chose. */
  nextForwardId(): string {
    this.forwardSeq++;
    return 'f' + String(this.forwardSeq) + '-' + String(this.forwardSeq * 2654435761 % 100000000);
  }

  /**
   * Record a hand-off. Re-dispatching the same origin request returns the existing
   * entry instead of adding a second one, so a retry cannot double-count load.
   */
  beginDispatch(id: string, entry: DispatchEntry): DispatchEntry {
    if (entry.originRequestId === undefined || entry.originRequestId.length === 0) entry.originRequestId = id;
    const key = dispatchKey(entry);
    const existing = this.byOrigin.get(key);
    if (existing !== undefined) return existing;
    if (entry.forwardId === undefined || entry.forwardId.length === 0) entry.forwardId = this.nextForwardId();
    this.byOrigin.set(key, entry);
    this.byForward.set(entry.forwardId, key);
    const epoch = entry.workerEpoch;
    this.inflightByEpoch.set(epoch, (this.inflightByEpoch.get(epoch) ?? 0) + 1);
    return entry;
  }

  /**
   * Lookup by wire id. With an epoch the composite key is exact. Without one the
   * id is only usable when it identifies exactly one live dispatch; an ambiguous
   * id resolves to undefined rather than silently picking an arbitrary origin.
   */
  getDispatch(id: string, originEpoch?: number): DispatchEntry | undefined {
    if (originEpoch !== undefined) return this.byOrigin.get(originKeyOf(originEpoch, id));
    const exact = this.byOrigin.get(id);
    if (exact !== undefined) return exact;
    let found: DispatchEntry | undefined = undefined;
    this.byOrigin.forEach((entry) => {
      if (entry.originRequestId !== id) return;
      if (found === undefined) found = entry;
      else if (found !== entry) found = undefined;
    });
    return found;
  }

  /** Reply routing: the id the worker echoed, which we generated. */
  getByForwardId(forwardId: string): DispatchEntry | undefined {
    const key = this.byForward.get(forwardId);
    return key === undefined ? undefined : this.byOrigin.get(key);
  }

  /** Dispatches issued on behalf of one origin session. */
  dispatchesFromOrigin(originEpoch: number): DispatchEntry[] {
    const found: DispatchEntry[] = [];
    this.byOrigin.forEach((entry) => {
      if (entry.originEpoch === originEpoch) found.push(entry);
    });
    return found;
  }

  /** Dispatches for one worker epoch, optionally narrowed to a wire request id. */
  dispatchesFor(workerEpoch: number, requestId: string = ''): DispatchEntry[] {
    const found: DispatchEntry[] = [];
    this.byOrigin.forEach((entry) => {
      if (entry.workerEpoch !== workerEpoch) return;
      if (requestId.length > 0 && entry.originRequestId !== requestId) return;
      found.push(entry);
    });
    return found;
  }

  finishDispatch(id: string, originEpoch?: number): DispatchEntry | undefined {
    let entry = originEpoch !== undefined ? this.byOrigin.get(originKeyOf(originEpoch, id)) :
      this.getDispatch(id);
    // A worker reply carries the forwarded id, not the client's, so accept it too.
    if (entry === undefined) entry = this.getByForwardId(id);
    if (entry === undefined) return undefined;
    return this.remove(entry);
  }

  /** Drop one hand-off by its forwarded id. Returns the entry, if it was live. */
  finishForward(forwardId: string): DispatchEntry | undefined {
    const entry = this.getByForwardId(forwardId);
    return entry === undefined ? undefined : this.remove(entry);
  }

  dropWorker(epoch: number): DispatchEntry[] {
    const dropped: DispatchEntry[] = [];
    for (const entry of this.dispatchesFor(epoch)) {
      const removed = this.remove(entry);
      if (removed !== undefined) dropped.push(removed);
    }
    return dropped;
  }

  private remove(entry: DispatchEntry): DispatchEntry {
    this.byOrigin.delete(dispatchKey(entry));
    if (entry.forwardId !== undefined && entry.forwardId.length > 0) this.byForward.delete(entry.forwardId);
    const epoch = entry.workerEpoch;
    const next = (this.inflightByEpoch.get(epoch) ?? 0) - 1;
    if (next > 0) this.inflightByEpoch.set(epoch, next);
    else this.inflightByEpoch.delete(epoch);
    return entry;
  }
}
