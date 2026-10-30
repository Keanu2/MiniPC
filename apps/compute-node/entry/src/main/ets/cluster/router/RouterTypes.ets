/**
 * 路由框架协议（从 ComputeRouter.ets 抽离）。对齐 Switchyard Algorithm trait
 * 与 model-router AlgorithmProvider 的形态：算法是纯策略，不做 I/O、不经手流量，
 * 只从集群快照里选一个节点或回答"选不出"（null = fail closed，绝不降级给不具备
 * 能力的设备）。
 *
 * 本文件只定义协议——输入快照、输出类型、算法接口；不含任何具体算法的实现
 * 逻辑（门槛/负载/档位等判定谓词归属各自的算法文件），框架不认识任何算法。
 *
 * 一算法一文件，RouterRegistry 按名字装配；加一个算法 = 加一个实现
 * RouteAlgorithm 的文件 + Registry 里两个 set 语句。
 *
 * 本文件是路由依赖图的根，刻意零 import（cluster 的裸 vm 测试纪律）。
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

/** 单次路由决策的输入快照，由调用方（hub）组装。 */
export class RouteContext {
  /** 集群快照（本机 + 就绪对端）。 */
  nodes: ScheduleNode[] = [];
  /** 能力硬门槛；空数组沿用旧协议的文字请求语义（须有 text）。 */
  needs: string[] = [];
  /** 任务档位 0=未分类（档位比较恒平）；档位只在负载平手时参与决胜。 */
  taskTier: number = 0;
}

/** 路由算法契约：name() 稳定低基数（注册表与日志），route() 单步决策。 */
export interface RouteAlgorithm {
  name(): string;
  route(ctx: RouteContext): ScheduleNode | null;
}
