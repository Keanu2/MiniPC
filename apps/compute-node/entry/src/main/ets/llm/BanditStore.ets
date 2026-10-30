import { utf8Bytes } from './InferenceWire';
import { ObservationEntry, RetrievedItem, tierRankOf } from './BackendRouter';
import { parseObservations } from './Bandit';

// —— 上游 bandit_store.py 原样移植（检索器 + 两阶段记录库 + 每键 call 状态）——
// 执行侧适配：时钟统一毫秒；publish 版本机制未移植（version 恒 0，γ 衰减
// 退化为 weight=sim，参数仍校验透传保留上游形状）；观察表不包
// data['observations'] 键（RetrievedItem.data 即观察表本身）。

const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;
/** 上游 HashedNgramRetriever 固定 3-gram。 */
const NGRAM = 3;

/** 上游 _fnv1a：FNV-1a 32 位哈希，逐 UTF-8 字节（Python hash() 每进程加盐不可用）。 */
export function fnv1a(text: string): number {
  const bytes = utf8Bytes(text);
  let h = FNV_OFFSET;
  for (let i = 0; i < bytes.length; i++) {
    h = (h ^ bytes[i]) >>> 0;
    h = Math.imul(h, FNV_PRIME) >>> 0;
  }
  return h >>> 0;
}

/** store 参数（上游 BanditStoreParams；时间项以毫秒存储）。 */
export interface BanditStoreParams {
  retrieverDim: number;
  maxEntries: number;
  topK: number;
  minSimilarity: number;
  forgettingGamma: number;
  pendingTtlMs: number;
  exclusionTtlMs: number;
}

/** 上游 types.py 默认值。 */
export function defaultStoreParams(): BanditStoreParams {
  const params: BanditStoreParams = {
    retrieverDim: 4096,
    maxEntries: 2000,
    topK: 10,
    minSimilarity: 0.5,
    forgettingGamma: 1.0,
    pendingTtlMs: 7_200_000,
    exclusionTtlMs: 300_000
  };
  return params;
}

/** 每键 call 状态视图（上游 StateView；自 RouteMemory 迁入）。 */
export interface StateView {
  sampleCount: number;
  affinity: string;
  exclusions: string[];
}

export interface StoreQueryResult {
  view: StateView;
  retrieved: RetrievedItem[];
}

export interface StoreStats {
  pending: number;
  closed: number;
  dropped: number;
  unknown: number;
}

interface PendingEntry {
  vector: Float32Array;
  openedAt: number;
  version: number;
}

interface StoreRecord {
  observations: Map<string, ObservationEntry>;
  version: number;
  createdAt: number;
}

interface KeyEntry {
  affinity: string;
  exclusions: string[];
  sampleCount: number;
  touchedAt: number;
}

interface WeightedIndex {
  weight: number;
  index: number;
}

/**
 * 质量闭环存储（上游 BanditStore）：字符 3-gram 哈希检索器 + 两阶段观察
 * 记录（query 开 pending → reportObservation 关闭入库）+ 每键 call 状态
 * （上游 MemoryState 语义收编于此：rejected 仅计数、排除只增、TTL 严格 >）。
 */
export class BanditStore {
  private readonly params: BanditStoreParams;
  private readonly now: () => number;
  private readonly dim: number;
  private readonly sweepEveryMs: number;
  private readonly pending: Map<string, PendingEntry> = new Map();
  private readonly records: StoreRecord[] = [];
  private readonly rows: Float32Array[] = [];
  private readonly keys: Map<string, KeyEntry> = new Map();
  private version: number = 0;
  private dropped: number = 0;
  private unknown: number = 0;
  private lastSweep: number = 0;

  constructor(params: BanditStoreParams, now: () => number = (): number => Date.now()) {
    this.params = params;
    this.now = now;
    this.dim = params.retrieverDim;
    this.sweepEveryMs = Math.max(1000, Math.min(60_000, params.pendingTtlMs / 10));
  }

  static emptyView(): StateView {
    const empty: StateView = { sampleCount: 0, affinity: '', exclusions: [] };
    return empty;
  }

  stats(): StoreStats {
    const s: StoreStats = {
      pending: this.pending.size,
      closed: this.records.length,
      dropped: this.dropped,
      unknown: this.unknown
    };
    return s;
  }

  /**
   * 文本→定长向量（上游 HashedNgramRetriever.encode）：lower→trim→空白折叠
   * 单空格；按码点取 3-gram（整串不足 3 码点则整串一个 gram）；桶计数
   * fnv1a(gram)%dim；L2 归一（空串/纯空白→零向量）。
   */
  encode(text: string): Float32Array {
    const vector = new Float32Array(this.dim);
    const normalized = `${text ?? ''}`.toLowerCase().trim().replace(/\s+/g, ' ');
    if (normalized.length === 0) return vector;
    const chars = Array.from(normalized);
    const grams: string[] = [];
    if (chars.length < NGRAM) {
      grams.push(normalized);
    } else {
      for (let i = 0; i + NGRAM <= chars.length; i++) {
        grams.push(chars.slice(i, i + NGRAM).join(''));
      }
    }
    const counts = new Float64Array(this.dim);
    for (const gram of grams) {
      counts[fnv1a(gram) % this.dim] += 1;
    }
    let normSq = 0;
    for (let i = 0; i < this.dim; i++) {
      normSq += counts[i] * counts[i];
    }
    const norm = Math.sqrt(normSq);
    if (norm > 0) {
      for (let i = 0; i < this.dim; i++) {
        vector[i] = counts[i] / norm;
      }
    }
    return vector;
  }

  /** 每键状态视图；超 exclusionTtl 未触碰→删除返回空（边界严格 >，恰在 ttl 时存活）。 */
  snapshot(key: string): StateView {
    const entry = this.keys.get(key);
    if (entry === undefined) return BanditStore.emptyView();
    if (this.now() - entry.touchedAt > this.params.exclusionTtlMs) {
      this.keys.delete(key);
      return BanditStore.emptyView();
    }
    const view: StateView = {
      sampleCount: entry.sampleCount,
      affinity: entry.affinity,
      exclusions: entry.exclusions.slice()
    };
    return view;
  }

  /**
   * call 结局上报（上游 _absorb_call_locked）：条目缺失或超时→整条重建；
   * ok→亲和；overflow/unavailable→排除追加去重（空 modelId 不排）；
   * 其余（含 rejected）仅计数。
   */
  reportCall(key: string, modelId: string, outcome: string): void {
    const now = this.now();
    let entry = this.keys.get(key);
    if (entry === undefined || now - entry.touchedAt > this.params.exclusionTtlMs) {
      const fresh: KeyEntry = { affinity: '', exclusions: [], sampleCount: 0, touchedAt: 0 };
      this.keys.set(key, fresh);
      entry = fresh;
    }
    entry.touchedAt = now;
    entry.sampleCount += 1;
    const outcomeNorm = `${outcome ?? ''}`.toLowerCase();
    if (outcomeNorm === 'ok') {
      entry.affinity = modelId;
    } else if (outcomeNorm === 'overflow' || outcomeNorm === 'unavailable') {
      if (modelId.length > 0 && entry.exclusions.indexOf(modelId) < 0) {
        entry.exclusions.push(modelId);
      }
    }
  }

  /** 查询（上游 State.query）：文本空白→仅视图不开 pending；否则 encode→开 pending（routeId 非空）→清扫→取近邻。 */
  query(key: string, text: string, routeId: string): StoreQueryResult {
    const view = this.snapshot(key);
    const trimmed = `${text ?? ''}`.trim();
    if (trimmed.length === 0) {
      const noVector: StoreQueryResult = { view: view, retrieved: [] };
      return noVector;
    }
    const vector = this.encode(text);
    if (routeId.length > 0) {
      const now = this.now();
      const opened: PendingEntry = { vector: vector, openedAt: now, version: this.version };
      this.pending.set(routeId, opened);
      this.sweep(now);
    }
    const retrieved = this.neighbours(vector);
    const result: StoreQueryResult = { view: view, retrieved: retrieved };
    return result;
  }

  /**
   * 仅开 pending 不取近邻（bandit 关闭时的宿主优化：决策不读 retrieved，
   * kNN 白算；语义上等价于 query 后丢弃 retrieved，零决策影响）。
   */
  openPending(routeId: string, text: string): void {
    const trimmed = `${text ?? ''}`.trim();
    if (trimmed.length === 0 || routeId.length === 0) return;
    const now = this.now();
    const opened: PendingEntry = { vector: this.encode(trimmed), openedAt: now, version: this.version };
    this.pending.set(routeId, opened);
    this.sweep(now);
  }

  /**
   * 关闭观察（上游 report 的 x-router.bandit 扩展路径）：pending 无此 id→
   * unknown++；否则弹出→入库（版本取 pending 开启时点）→超容量 FIFO 淘汰
   * 最老记录。非法 quality/cost/tier 抛错，由宿主记 judgeFailed。
   */
  reportObservation(routeId: string, tier: string, quality: number, costUsd: number): void {
    if (!Number.isFinite(quality) || quality < -1 || quality > 1) {
      throw new Error('bandit observation quality out of range: ' + quality);
    }
    if (!Number.isFinite(costUsd) || costUsd < 0) {
      throw new Error('bandit observation cost out of range: ' + costUsd);
    }
    if (tierRankOf(tier) < 0) {
      throw new Error('bandit observation unknown tier: ' + tier);
    }
    const pendingEntry = routeId.length > 0 ? this.pending.get(routeId) : undefined;
    if (pendingEntry === undefined) {
      this.unknown += 1;
      return;
    }
    this.pending.delete(routeId);
    const observations = new Map<string, ObservationEntry>();
    const observation: ObservationEntry = { quality: quality, costUsd: costUsd };
    observations.set(tier, observation);
    const record: StoreRecord = {
      observations: observations,
      version: pendingEntry.version,
      createdAt: this.now()
    };
    this.records.push(record);
    this.rows.push(pendingEntry.vector);
    while (this.records.length > this.params.maxEntries) {
      this.records.shift();
      this.rows.shift();
    }
  }

  /** 清扫过期 pending（上游 _sweep_locked）：节流窗 pendingTtlMs/10 钳 [1s,60s]；pending 超容量强扫。 */
  private sweep(now: number): void {
    if (now - this.lastSweep < this.sweepEveryMs && this.pending.size <= this.params.maxEntries) {
      return;
    }
    this.lastSweep = now;
    const stale: string[] = [];
    this.pending.forEach((entry: PendingEntry, id: string): void => {
      if (now - entry.openedAt > this.params.pendingTtlMs) {
        stale.push(id);
      }
    });
    for (const id of stale) {
      this.pending.delete(id);
    }
    this.dropped += stale.length;
  }

  /** 绕过节流立即清扫（上游 expire_pending 测试口）；返回本次丢弃数。 */
  expirePending(): number {
    const before = this.dropped;
    this.lastSweep = 0;
    this.sweep(this.now());
    return this.dropped - before;
  }

  /**
   * 近邻检索（上游 _neighbours_locked，顺序敏感）：k=min(topK, 条数)→
   * 全量点积（行与查询均 L2 归一→点积即余弦）→先按原始相似度取 top-k
   * （平局按记录序）→后过滤 sim<minSimilarity→weight=sim·γ^(版本差)→
   * 非有限或≤0 丢→按 weight 降序输出。
   */
  private neighbours(vector: Float32Array): RetrievedItem[] {
    const count = this.records.length;
    if (count === 0) return [];
    const k = Math.min(this.params.topK, count);
    const sims: number[] = [];
    for (let i = 0; i < count; i++) {
      const row = this.rows[i];
      let dot = 0;
      for (let j = 0; j < row.length; j++) {
        dot += row[j] * vector[j];
      }
      sims.push(dot);
    }
    const order: number[] = [];
    for (let i = 0; i < count; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number): number => {
      const bySim = sims[b] - sims[a];
      return bySim !== 0 ? bySim : a - b;
    });
    const items: WeightedIndex[] = [];
    const gamma = this.params.forgettingGamma;
    for (let n = 0; n < k; n++) {
      const index = order[n];
      const similarity = sims[index];
      if (similarity < this.params.minSimilarity) continue;
      const decay = Math.pow(gamma, Math.max(0, this.version - this.records[index].version));
      const weight = similarity * decay;
      if (!Number.isFinite(weight) || weight <= 0) continue;
      const weighted: WeightedIndex = { weight: weight, index: index };
      items.push(weighted);
    }
    items.sort((a: WeightedIndex, b: WeightedIndex): number => b.weight - a.weight);
    const result: RetrievedItem[] = [];
    for (const item of items) {
      const retrieved: RetrievedItem = {
        id: 'r' + item.index,
        score: item.weight,
        data: parseObservations(this.records[item.index].observations)
      };
      result.push(retrieved);
    }
    return result;
  }
}
