/**
 * least_load 算法（原 ComputeRouter.pickNode 迁移）：能力是硬门槛（fail
 * closed）→ 空闲节点优先/负载最低 → 档位贴近决胜（贴近再平手 → 就高）→
 * 内存更大 → 本机优先。MiniPC 本机可多路 session，满载仍可选本机；没有
 * 任何合格节点返回 null，绝不降级给不具备能力的设备。
 *
 * 判定谓词（nodeLoad/meetsNeeds/memAvailOf/tierOf/compareTier）是本算法的
 * 实现细节，随算法内联私有；其他算法自带自己的判定逻辑，不经手这些函数。
 */
import { ScheduleNode, RouteContext, RouteAlgorithm } from './RouterTypes';

function nodeLoad(node: ScheduleNode): number {
  return node.requests < 0 ? 0 : node.requests;
}

/** 空需求沿用旧协议的文字请求语义；否则每一项都要在节点能力表里。 */
function meetsNeeds(node: ScheduleNode, needs: string[]): boolean {
  if (needs.length === 0) return node.capabilities.indexOf('text') >= 0;
  for (const need of needs) {
    if (node.capabilities.indexOf(need) < 0) return false;
  }
  return true;
}

function memAvailOf(node: ScheduleNode): number {
  return node.memAvail < 0 ? 0 : node.memAvail;
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

export class LeastLoadRouter implements RouteAlgorithm {
  name(): string {
    return 'least_load';
  }

  route(ctx: RouteContext): ScheduleNode | null {
    let best: ScheduleNode | null = null;
    let bestLoad: number = Number.MAX_VALUE;
    for (const node of ctx.nodes) {
      if (node.model.length === 0 || !meetsNeeds(node, ctx.needs)) continue;
      const load = nodeLoad(node);
      if (best !== null && load >= 1 && bestLoad < 1) continue;
      if (best === null || load < bestLoad) {
        best = node;
        bestLoad = load;
        continue;
      }
      if (load > bestLoad) continue;
      // 负载平手：档位贴近决胜（贴近再平手 → 就高），仍平手回落内存/本机。
      const byTier = compareTier(node, best, ctx.taskTier);
      if (byTier < 0 || (byTier === 0 && (memAvailOf(node) > memAvailOf(best) ||
        (memAvailOf(node) === memAvailOf(best) && node.isSelf)))) {
        best = node;
        bestLoad = load;
      }
    }
    return best;
  }
}
