/**
 * 路由反馈记忆（上游 crates/state MemoryState 的移植）：键 → {样本数, 亲和模型,
 * 排除模型}，TTL 默认 300s、容量默认 1024 条。语义与上游逐条对齐：
 * - 每次上报都刷新 TTL（过期是唯一的自然清除路径）；
 * - 排除项只增不删（Ok 也不回收），过期整条清零重来；
 * - Ok→亲和模型；Overflow/Unavailable→追加排除；Rejected 只计数不改状态；
 * - 容量满时淘汰最旧键（上游以上限代替完整 LRU，FIFO 近似）。
 * 本环境 RoutingKey 退化为全局单键（单会话应用），键结构保留以便扩展。
 */

export interface StateView {
  /** 该键累计有效上报次数。 */
  sampleCount: number;
  /** 最近一次 Ok 的模型 id；空串表示尚无。 */
  affinity: string;
  /** 被排除的模型 id 列表。 */
  exclusions: string[];
}

interface MemoryEntry {
  view: StateView;
  expiresAt: number;
}

export class RouteMemory {
  private readonly ttlMs: number;
  private readonly maxEntries: number;
  private readonly now: () => number;
  private entries: Map<string, MemoryEntry> = new Map();
  private order: string[] = [];

  constructor(ttlMs: number = 300_000, maxEntries: number = 1024,
    now: () => number = (): number => Date.now()) {
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.now = now;
  }

  /** 上游 snapshot：条目过期即移除并返回空视图；命中返回状态副本（排除列表可安全持有）。 */
  snapshot(key: string): StateView {
    const entry = this.entries.get(key);
    if (entry === undefined) {
      return RouteMemory.emptyView();
    }
    if (entry.expiresAt <= this.now()) {
      this.drop(key);
      return RouteMemory.emptyView();
    }
    return {
      sampleCount: entry.view.sampleCount,
      affinity: entry.view.affinity,
      exclusions: entry.view.exclusions.slice()
    };
  }

  /** 上游 report：无条目则新建（容量满先淘汰最旧）；每次上报刷新 TTL 并计数。 */
  report(key: string, modelId: string, outcome: string): void {
    const now = this.now();
    if (!this.entries.has(key)) {
      if (this.order.length >= this.maxEntries) {
        const oldest = this.order.shift();
        if (oldest !== undefined) {
          this.entries.delete(oldest);
        }
      }
      this.entries.set(key, { view: RouteMemory.emptyView(), expiresAt: now + this.ttlMs });
      this.order.push(key);
    }
    const entry = this.entries.get(key);
    if (entry === undefined) {
      return;
    }
    entry.expiresAt = now + this.ttlMs;
    entry.view.sampleCount += 1;
    if (outcome === 'overflow' || outcome === 'unavailable') {
      if (entry.view.exclusions.indexOf(modelId) < 0) {
        entry.view.exclusions.push(modelId);
      }
    } else if (outcome === 'ok') {
      entry.view.affinity = modelId;
    }
  }

  private drop(key: string): void {
    this.entries.delete(key);
    const index = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
  }

  static emptyView(): StateView {
    return { sampleCount: 0, affinity: '', exclusions: [] };
  }
}
