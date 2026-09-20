/**
 * 算力选点与在途派发。对齐 modelshare ChatProxyService：
 * 负载 = 采样请求数 + 在途派发；有模型的节点里选负载最低、内存更大者。
 * MiniPC 本机可多路 session，因此满载仍可选本机，只有没有任何模型时才返回 null。
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
  workerEpoch: number = 0;
  workerName: string = '';
}

export function nodeLoad(node: ScheduleNode): number {
  return node.requests < 0 ? 0 : node.requests;
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

export class ComputeRouter {
  private dispatches: Map<string, DispatchEntry> = new Map();
  private inflightByEpoch: Map<number, number> = new Map();
  private selfInflight: number = 0;

  selfLoad(sampled: number): number {
    return (sampled < 0 ? 0 : sampled) + this.selfInflight;
  }

  workerLoad(epoch: number, sampled: number): number {
    return (sampled < 0 ? 0 : sampled) + (this.inflightByEpoch.get(epoch) ?? 0);
  }

  beginSelf(): void { this.selfInflight++; }
  endSelf(): void { this.selfInflight = Math.max(0, this.selfInflight - 1); }

  beginDispatch(id: string, entry: DispatchEntry): void {
    this.dispatches.set(id, entry);
    this.inflightByEpoch.set(entry.workerEpoch, (this.inflightByEpoch.get(entry.workerEpoch) ?? 0) + 1);
  }

  getDispatch(id: string): DispatchEntry | undefined {
    return this.dispatches.get(id);
  }

  finishDispatch(id: string): DispatchEntry | undefined {
    const entry = this.dispatches.get(id);
    if (entry === undefined) return undefined;
    this.dispatches.delete(id);
    const next = (this.inflightByEpoch.get(entry.workerEpoch) ?? 0) - 1;
    if (next > 0) this.inflightByEpoch.set(entry.workerEpoch, next);
    else this.inflightByEpoch.delete(entry.workerEpoch);
    return entry;
  }

  dropWorker(epoch: number): DispatchEntry[] {
    const dropped: DispatchEntry[] = [];
    const ids: string[] = [];
    this.dispatches.forEach((entry, id) => {
      if (entry.workerEpoch === epoch) ids.push(id);
    });
    for (const id of ids) {
      const entry = this.finishDispatch(id);
      if (entry !== undefined) dropped.push(entry);
    }
    return dropped;
  }

  dropOrigin(epoch: number): string[] {
    const ids: string[] = [];
    this.dispatches.forEach((entry, id) => {
      if (entry.originEpoch === epoch) ids.push(id);
    });
    for (const id of ids) this.finishDispatch(id);
    return ids;
  }
}
