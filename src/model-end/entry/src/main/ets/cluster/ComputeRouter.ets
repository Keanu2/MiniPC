/**
 * 算力选点与在途派发。对齐 modelshare ChatProxyService：
 * 负载 = 采样请求数与在途派发的较大者；有模型的节点里选负载最低、内存更大者。
 * MiniPC 本机可多路 session，因此满载仍可选本机，只有没有任何模型时才返回 null。
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

export function pickNode(nodes: ScheduleNode[]): ScheduleNode | null {
  let best: ScheduleNode | null = null;
  let bestLoad: number = Number.MAX_VALUE;
  for (const node of nodes) {
    if (node.model.length === 0) continue;
    const load = nodeLoad(node);
    if (best !== null && load >= 1 && bestLoad < 1) continue;
    if (best === null || load < bestLoad ||
      (load === bestLoad && (memAvailOf(node) > memAvailOf(best) ||
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
 */
export function pickRoute(nodes: ScheduleNode[], mode: string, preferSelf: boolean): ScheduleNode | null {
  if (mode === 'auto' || mode.length === 0) return pickNode(nodes);
  let self: ScheduleNode | null = null;
  let peer: ScheduleNode | null = null;
  for (const node of nodes) {
    if (node.model.length === 0) continue;
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
  return pickNode(nodes);
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
