import { ObservationEntry, RetrievedItem, tierRankOf } from './BackendRouter';

// —— 上游 bandit.py 原样移植（决策纯函数，逐句对照）——

/** bandit 相对分类器档位的处置码，进 reason 的 bandit=<code>。 */
export const BANDIT_OFF = 'off';
export const BANDIT_COLD = 'cold';
export const BANDIT_SAME = 'same';
export const BANDIT_IGNORE = 'ignore';
export const BANDIT_OVERRIDE = 'override';

/** bandit 决策参数（上游 BanditParams）：邻居门槛/覆写余量/成本权重/成本基准。 */
export interface BanditParams {
  minNeighbors: number;
  margin: number;
  lambdaC: number;
  costRefUsd: number;
}

/** 上游 types.py 默认值。 */
export function defaultBanditParams(): BanditParams {
  const params: BanditParams = { minNeighbors: 5, margin: 0.3, lambdaC: 0.2, costRefUsd: 0.005 };
  return params;
}

/** 单档加权证据累计（上游 TierEvidence）。 */
export class TierEvidence {
  count: number = 0;
  weight: number = 0;
  qualitySum: number = 0;
  costWeight: number = 0;
  costSum: number = 0;

  add(weight: number, quality: number, cost: number | null): void {
    this.count += 1;
    this.weight += weight;
    this.qualitySum += weight * quality;
    if (cost !== null) {
      this.costWeight += weight;
      this.costSum += weight * cost;
    }
  }

  meanQuality(): number | null {
    return this.weight > 0 ? this.qualitySum / this.weight : null;
  }

  meanCost(): number | null {
    return this.costWeight > 0 ? this.costSum / this.costWeight : null;
  }
}

/**
 * 校验并规范化观察表（上游 parse_observations）：档名大写化后未知丢弃、
 * quality 非有限数丢弃、cost 非有限或负→null。算法与 store 两侧共用，
 * 两边解析永不分歧。上游把观察包在 data['observations'] 键下，本移植的
 * RetrievedItem.data 即观察表本身（传输形状差异，语义一致）。
 */
export function parseObservations(data: Map<string, ObservationEntry> | null): Map<string, ObservationEntry> {
  const parsed = new Map<string, ObservationEntry>();
  if (data === null || data === undefined) return parsed;
  data.forEach((observation: ObservationEntry, name: string): void => {
    const tier = `${name ?? ''}`.trim().toUpperCase();
    if (tierRankOf(tier) < 0) return;
    const quality = observation.quality;
    if (typeof quality !== 'number' || !Number.isFinite(quality)) return;
    let cost: number | null = observation.costUsd;
    if (typeof cost !== 'number' || !Number.isFinite(cost) || cost < 0) cost = null;
    const entry: ObservationEntry = { quality: quality, costUsd: cost };
    parsed.set(tier, entry);
  });
  return parsed;
}

/** 聚合结果：neighbours=贡献了≥1 条可用观察的条目数，evidence 按档累计。 */
export interface AggregateResult {
  neighbours: number;
  evidence: Map<string, TierEvidence>;
}

/** 上游 aggregate：score 非有限或≤0 的条目跳过（不计 neighbours）。 */
export function aggregate(retrieved: RetrievedItem[]): AggregateResult {
  const evidence = new Map<string, TierEvidence>();
  let neighbours = 0;
  const items = retrieved ?? [];
  for (const item of items) {
    const weight = item.score;
    if (typeof weight !== 'number' || !Number.isFinite(weight) || weight <= 0) continue;
    const observations = parseObservations(item.data);
    if (observations.size === 0) continue;
    neighbours += 1;
    observations.forEach((observation: ObservationEntry, tier: string): void => {
      let agg = evidence.get(tier);
      if (agg === undefined) {
        agg = new TierEvidence();
        evidence.set(tier, agg);
      }
      agg.add(weight, observation.quality, observation.costUsd);
    });
  }
  const result: AggregateResult = { neighbours: neighbours, evidence: evidence };
  return result;
}

/** 上游 utilities：U=质量−λ·成本/成本基准；λ>0 时无成本报告的档剔除，λ=0 退化为纯质量。 */
export function utilities(evidence: Map<string, TierEvidence>, params: BanditParams): Map<string, number> {
  const scores = new Map<string, number>();
  evidence.forEach((agg: TierEvidence, tier: string): void => {
    const quality = agg.meanQuality();
    if (quality === null) return;
    const cost = agg.meanCost();
    if (params.lambdaC > 0) {
      if (cost === null) return;
      scores.set(tier, quality - params.lambdaC * cost / params.costRefUsd);
    } else {
      scores.set(tier, quality);
    }
  });
  return scores;
}

/** choose_tier 的返回：处置后的档位、处置码、邻居数。 */
export interface TierChoice {
  tier: string;
  code: string;
  neighbours: number;
}

/**
 * 上游 choose_tier 逐句对照：邻居<门槛→cold；incumbent 无证据→ignore；
 * 候选按档秩升序、严格 > 才替换（平手取更低档）；best 未变→same；
 * 优势≤margin→ignore；否则 override 到 best。
 */
export function chooseTier(tier: string, retrieved: RetrievedItem[], params: BanditParams): TierChoice {
  const aggregated = aggregate(retrieved);
  const neighbours = aggregated.neighbours;
  if (neighbours < params.minNeighbors) {
    const cold: TierChoice = { tier: tier, code: BANDIT_COLD, neighbours: neighbours };
    return cold;
  }
  const scores = utilities(aggregated.evidence, params);
  const incumbent = scores.get(tier);
  if (incumbent === undefined) {
    const ignored: TierChoice = { tier: tier, code: BANDIT_IGNORE, neighbours: neighbours };
    return ignored;
  }
  const candidates: string[] = [];
  scores.forEach((_score: number, candidate: string): void => {
    candidates.push(candidate);
  });
  candidates.sort((a: string, b: string): number => tierRankOf(a) - tierRankOf(b));
  let best = tier;
  let bestScore = incumbent;
  for (const candidate of candidates) {
    if (candidate === tier) continue;
    const score = scores.get(candidate);
    if (score !== undefined && score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  if (best === tier) {
    const same: TierChoice = { tier: tier, code: BANDIT_SAME, neighbours: neighbours };
    return same;
  }
  if (bestScore - incumbent <= params.margin) {
    const blocked: TierChoice = { tier: tier, code: BANDIT_IGNORE, neighbours: neighbours };
    return blocked;
  }
  const override: TierChoice = { tier: best, code: BANDIT_OVERRIDE, neighbours: neighbours };
  return override;
}
