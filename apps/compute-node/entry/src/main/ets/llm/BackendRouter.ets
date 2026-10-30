import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage } from './LocalChat';

const ROUTE_CONFIG_FILE = 'cloud_config.json';

// —— 上游 ComplexityLevel 档位与观察类型（共享层：XRouter/Bandit/BanditStore 共用）——
/** 复杂度档位，序即能力序。语义对齐上游 ComplexityLevel 枚举。 */
export const TIER_ORDER: string[] = ['SIMPLE', 'MEDIUM', 'COMPLEX', 'RESEARCH', 'REASONING'];

/** 档位秩（上游 ComplexityLevel IntEnum 序）；未知档 -1。 */
export function tierRankOf(tier: string): number {
  return TIER_ORDER.indexOf(tier);
}

/** 一条档位质量观察（上游 {quality, cost_usd}；costUsd 为 null 表示未上报成本）。 */
export interface ObservationEntry {
  quality: number;
  costUsd: number | null;
}

/** 近邻检索条目（上游 RetrievedItem）：score 为按龄折算后的权重，data 携带各档观察。 */
export interface RetrievedItem {
  id: string;
  score: number;
  data: Map<string, ObservationEntry>;
}

/** cloud_config.json 里路由关心的字段。 */
interface RouteConfigJson {
  route?: string;
}

/** 一次推理请求的路由上下文（决策输入）。 */
export interface RouteContext {
  /** 完整对话消息（同上游 RouteRequest.messages，策略自行提取特征）。 */
  messages: ChatMessage[];
  /** 最后一条 user 消息的字符数。 */
  promptChars: number;
  /** 请求携带图片（裸 base64）时非空。 */
  image: string;
  /** 请求的 max_tokens；未指定为 0。 */
  maxTokens: number;
  /** 近邻检索结果（上游 RouteContext.retrieved）；仅 xrouter+bandit 启用时由宿主填充，算法只读。 */
  retrieved?: RetrievedItem[];
}

/** 两侧推理后端的可用性快照。 */
export interface BackendStatus {
  localReady: boolean;
  localBusy: boolean;
  cloudReady: boolean;
  cloudBusy: boolean;
  /** 状态排除的模型 id 列表（上游 StateView.exclusions）：目标被排除时策略降级而非报错。 */
  exclusions: string[];
}

/** 路由决策：side 为 'local' 或 'cloud'；reason 记录决策依据，随日志输出便于排查。 */
export interface RouteDecision {
  side: string;
  reason: string;
  /** 复杂度档位（仅 xrouter 策略填充，如 'COMPLEX'；其余策略缺省）。 */
  tier?: string;
  /** 选中的模型 id（上游 selected_model_id）：'local' 或云侧模型名。 */
  model?: string;
}

/**
 * 自定义路由规则（路由方案的注入点）：返回 'local' 或 'cloud'；
 * 返回空串表示本条不接管，落回当前策略的默认决策。
 */
export interface RouteRule {
  decide(context: RouteContext, status: BackendStatus): string;
}

/**
 * 策略级路由算法挂载点（语义对齐上游 model-router 的 AlgorithmProvider.decide）：
 * x-router 等复杂策略实现此接口，经构造函数注入，由 'xrouter' 策略调用。
 * 异步形式：x-router 分类器可走网络（ArkTS 无同步 HTTP；上游 route() 阻塞至
 * 分类器超时的行为在此折算为 Promise）。
 */
export interface RouteStrategy {
  decideAsync(context: RouteContext, status: BackendStatus): Promise<RouteDecision>;
}

/**
 * 端侧/云侧路由策略。决策优先级：自定义规则 > 策略。
 * 策略取值：
 * - 'config'（默认）：沿用 cloud_config.json 的 backend 语义（backend 缺省视为 cloud），
 *   行为与引入路由模块前完全一致；
 * - 'cloud'：强制云侧；
 * - 'local'：强制端侧；
 * - 'auto'：按可用性自动选择，默认启发式见 auto()；
 * - 'xrouter'：按对话复杂度分档路由（x-router 语义移植），决策由注入的 RouteStrategy 执行。
 * 策略来源：cloud_config.json 的可选 route 字段（缺省 'config'），也可 setPolicy() 运行时切换。
 */
export class BackendRouter {
  private currentPolicy: string = 'config';
  private rule: RouteRule | null = null;
  private readonly xrouter: RouteStrategy | null;

  constructor(policy: string = 'config', xrouter: RouteStrategy | null = null) {
    this.currentPolicy = BackendRouter.normalizePolicy(policy);
    this.xrouter = xrouter;
  }

  policy(): string { return this.currentPolicy; }

  /** 运行时切换策略；非合法取值一律回落 'config'。 */
  setPolicy(policy: string): void {
    const normalized = BackendRouter.normalizePolicy(policy);
    if (normalized !== this.currentPolicy) {
      hilog.info(0, 'NearbyChat', 'route policy=%{public}s', normalized);
    }
    this.currentPolicy = normalized;
  }

  /** 注入/移除自定义路由规则；规则优先于策略。 */
  setRule(rule: RouteRule | null): void {
    this.rule = rule;
  }

  route(context: RouteContext, status: BackendStatus): RouteDecision {
    if (this.rule !== null) {
      const side = this.rule.decide(context, status);
      if (side === 'local' || side === 'cloud') {
        return { side: side, reason: 'rule' };
      }
    }
    if (this.currentPolicy === 'cloud') return { side: 'cloud', reason: 'policy=cloud' };
    if (this.currentPolicy === 'local') return { side: 'local', reason: 'policy=local' };
    if (this.currentPolicy === 'auto') return this.auto(context, status);
    if (this.currentPolicy === 'xrouter') {
      // x-router 决策可走网络分类器，只能经 routeAsync；同步入口一律回落 config。
      hilog.warn(0, 'NearbyChat', 'xrouter policy requires routeAsync, config fallback');
      return this.configDecision(status);
    }
    return this.configDecision(status);
  }

  /** 异步路由入口（xrouter 策略必须走此入口；其余策略为同步语义的 Promise 包装）。 */
  routeAsync(context: RouteContext, status: BackendStatus): Promise<RouteDecision> {
    if (this.currentPolicy === 'xrouter') {
      if (this.xrouter !== null) {
        return this.xrouter.decideAsync(context, status);
      }
      hilog.warn(0, 'NearbyChat', 'xrouter policy without strategy, config fallback');
    }
    return Promise.resolve(this.route(context, status));
  }

  private configDecision(status: BackendStatus): RouteDecision {
    return {
      side: status.cloudReady ? 'cloud' : 'local',
      reason: status.cloudReady ? 'config:backend=cloud' : 'config:backend=local'
    };
  }

  /**
   * auto 默认启发式（框架示例）：带图走端侧（云侧不收图），云侧未就绪走端侧，
   * 端侧无模型走云侧，其余默认云侧。
   * TODO(路由方案): 在此实现你的自动路由策略。
   */
  private auto(context: RouteContext, status: BackendStatus): RouteDecision {
    if (context.image.length > 0) return { side: 'local', reason: 'auto:带图请求走端侧' };
    if (!status.cloudReady) return { side: 'local', reason: 'auto:云侧未就绪' };
    if (!status.localReady) return { side: 'cloud', reason: 'auto:端侧无模型' };
    return { side: 'cloud', reason: 'auto:默认云侧' };
  }

  static normalizePolicy(policy: string): string {
    const trimmed = (policy ?? '').trim();
    return trimmed === 'cloud' || trimmed === 'local' || trimmed === 'auto' || trimmed === 'xrouter'
      ? trimmed : 'config';
  }

  /** 读取 cloud_config.json 的可选 route 字段；文件缺失、字段缺失或非法取值均回落 'config'。 */
  static loadPolicy(filesDir: string): string {
    let text: string;
    try {
      text = fileIo.readTextSync(filesDir + '/' + ROUTE_CONFIG_FILE);
    } catch (_) {
      return 'config';
    }
    try {
      const json = JSON.parse(text) as RouteConfigJson;
      return BackendRouter.normalizePolicy(json.route ?? '');
    } catch (_) {
      return 'config';
    }
  }
}
