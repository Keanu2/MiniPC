/**
 * Idle-device selection for the compute hub. Pure logic: the caller supplies a
 * snapshot whose `inflight` already counts requests the hub has handed out but
 * the device has not yet reported, so two requests arriving in the same tick can
 * prefer different idle devices. Gewu can also run concurrent sessions on a busy device.
 */

export class PoolNode {
  epoch: number = 0;
  label: string = '';
  isSelf: boolean = false;
  /** Has a deployed model and is able to accept work. */
  ready: boolean = false;
  inflight: number = 0;
  memAvail: number = -1;
  /**
   * 该节点模型可提供的能力（如 ['text','vision']）。
   * 未声明按纯文本处理 —— 与 ComputeRouter.ScheduleNode 的约定保持一致。
   */
  capabilities: string[] = ['text'];
  /** 部署模型声明的最高强度档位 1-2（1 弱、2 强）；老对端/未声明 → 2 强档（同 ScheduleNode）。 */
  modelTier: number = 2;
}

export class ClusterLoad {
  idle: number = 0;
  total: number = 0;
}

function memOf(node: PoolNode): number {
  return node.memAvail < 0 ? 0 : node.memAvail;
}

export function idleNodes(nodes: PoolNode[]): PoolNode[] {
  return nodes.filter((node: PoolNode): boolean => node.ready && node.inflight <= 0);
}

/**
 * More free memory wins; on a tie the hub itself runs the work (no forwarding hop).
 * A preferred epoch (the device that already holds this run's session) wins whenever it
 * is idle; when it is busy the request goes to any other idle device, never waits for it.
 */
export function pickIdle(nodes: PoolNode[], preferEpoch: number = -1,
  cost: (epoch: number) => number = (_epoch: number): number => -1): PoolNode | null {
  if (preferEpoch >= 0) {
    for (const node of idleNodes(nodes)) {
      if (node.epoch === preferEpoch) return node;
    }
  }
  let best: PoolNode | null = null;
  for (const node of idleNodes(nodes)) {
    if (best === null || better(node, best, cost)) best = node;
  }
  return best;
}

/** Prefer idle devices, then admit another session on the least-loaded ready device. */
export function pickAvailable(nodes: PoolNode[], preferEpoch: number = -1,
  cost: (epoch: number) => number = (_epoch: number): number => -1): PoolNode | null {
  const idle = pickIdle(nodes, preferEpoch, cost);
  if (idle !== null) return idle;
  let best: PoolNode | null = null;
  for (const node of nodes) {
    if (!node.ready) continue;
    if (best === null || node.inflight < best.inflight ||
      (node.inflight === best.inflight && (node.epoch === preferEpoch ||
        (best.epoch !== preferEpoch && better(node, best, cost))))) {
      best = node;
    }
  }
  return best;
}

/**
 * Measured speed decides among idle devices (lower cost = faster). A device with no measurement yet
 * is tried first so it gets measured. Speeds within SPEED_TOLERANCE of each other count as equal and
 * fall back to free memory, then to the hub itself.
 */
export const SPEED_TOLERANCE = 0.15;

function better(a: PoolNode, b: PoolNode, cost: (epoch: number) => number): boolean {
  const ca = cost(a.epoch);
  const cb = cost(b.epoch);
  if ((ca < 0) !== (cb < 0)) return ca < 0;
  if (ca >= 0 && cb >= 0 && Math.abs(ca - cb) > SPEED_TOLERANCE * Math.min(ca, cb)) return ca < cb;
  if (memOf(a) !== memOf(b)) return memOf(a) > memOf(b);
  return a.isSelf && !b.isSelf;
}

/** 能力是硬门槛：needs 的每一项都必须在节点声明的 capabilities 里。 */
export function meetsCapabilities(node: PoolNode, needs: string[]): boolean {
  if (needs.length === 0) return node.capabilities.indexOf('text') >= 0;
  for (const need of needs) {
    if (node.capabilities.indexOf(need) < 0) return false;
  }
  return true;
}

/** 档位归一：1 原样，其余（2 与旧构建上报的 3）→ 2 强档。与 ComputeRouter.tierOf
 * 同款成对重复（两模块都必须保持零 import，裸 vm 可加载）。 */
function tierOf(value: number): number {
  return value === 1 ? 1 : 2;
}

/** 负载无从谈起（只有空闲节点参与），直接比档位贴近 → 就高 → 内存 → 本机。 */
function compareTier(node: PoolNode, best: PoolNode, taskTier: number): number {
  if (taskTier < 1) return 0;
  const nodeTier = tierOf(node.modelTier);
  const bestTier = tierOf(best.modelTier);
  const nodeClose = Math.abs(nodeTier - taskTier);
  const bestClose = Math.abs(bestTier - taskTier);
  if (nodeClose !== bestClose) return nodeClose < bestClose ? -1 : 1;
  if (nodeTier !== bestTier) return nodeTier > bestTier ? -1 : 1;
  return 0;
}

/**
 * 带能力门槛的空闲节点选择 —— **infer 转发路径必须用它**。
 *
 * 背景：infer 通路原先直接用 `pickIdle`（只按空闲与可用内存挑），完全不看能力，
 * 真机实测因此出现三种错配：
 *   1. 文本请求被转给只有 VL 权重的节点；
 *   2. 带图请求被转给纯文本节点；
 *   3. hub 自己被选中后**本地服务**一个它根本不具备能力的请求
 *      （图片落到纯文本 hub → 回「VL 模型未部署」）。
 * nearby-chat 通路本来就有同义门槛（`ComputeRouter.meetsNeeds`），这里把 infer 侧补齐。
 *
 * taskTier ≥ 1 时在空闲能力合格节点里按档位贴近选（贴近平手 → 就高 → 内存 → 本机）；
 * 有空闲的低档节点就降档接客，只有全部合格节点都忙才返回 null（BUSY 语义不变，
 * 档位绝不构成可用性门槛）。taskTier = 0 与旧版完全等价。
 */
export function pickIdleFor(nodes: PoolNode[], needs: string[], taskTier: number = 0): PoolNode | null {
  const capable = nodes.filter((node: PoolNode): boolean => meetsCapabilities(node, needs));
  if (taskTier < 1) return pickIdle(capable);
  let best: PoolNode | null = null;
  for (const node of idleNodes(capable)) {
    if (best === null) {
      best = node;
      continue;
    }
    const byTier = compareTier(node, best, taskTier);
    if (byTier < 0) {
      best = node;
      continue;
    }
    if (byTier > 0) continue;
    if (memOf(node) > memOf(best) || (memOf(node) === memOf(best) && node.isSelf && !best.isSelf)) {
      best = node;
    }
  }
  return best;
}

/** Keep capability/tier routing while allowing GEWU text sessions to overlap. */
export function pickAvailableFor(nodes: PoolNode[], needs: string[], taskTier: number = 0,
  preferEpoch: number = -1,
  cost: (epoch: number) => number = (_epoch: number): number => -1): PoolNode | null {
  const capable = nodes.filter((node: PoolNode): boolean => node.ready && meetsCapabilities(node, needs));
  const idle = idleNodes(capable);
  const candidates = idle.length > 0 ? idle : capable;
  // The VL engine has one session; only text inference supports busy-node admission.
  if (idle.length === 0 && needs.indexOf('vision') >= 0) return null;
  let best: PoolNode | null = null;
  for (const node of candidates) {
    if (best === null) { best = node; continue; }
    if (idle.length === 0 && node.inflight !== best.inflight) {
      if (node.inflight < best.inflight) best = node;
      continue;
    }
    const byTier = compareTier(node, best, taskTier);
    if (byTier !== 0) { if (byTier < 0) best = node; continue; }
    if (node.epoch === preferEpoch || (best.epoch !== preferEpoch && better(node, best, cost))) best = node;
  }
  return best;
}

export function clusterLoad(nodes: PoolNode[]): ClusterLoad {
  const load = new ClusterLoad();
  for (const node of nodes) {
    if (!node.ready) continue;
    load.total++;
    if (node.inflight <= 0) load.idle++;
  }
  return load;
}
