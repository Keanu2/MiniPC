import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage } from './LocalChat';
import { CloudClassifier } from './CloudClassifier';
import { capUtf8Bytes } from './InferenceWire';
import { BackendStatus, RetrievedItem, RouteContext, RouteDecision, RouteStrategy, TIER_ORDER, tierRankOf } from './BackendRouter';
import { BanditParams, chooseTier, defaultBanditParams } from './Bandit';
import { BanditStoreParams, defaultStoreParams } from './BanditStore';

const XROUTER_CONFIG_FILE = 'cloud_config.json';

// —— 上游常量（python/openjiuwen/x_router 原样移植）——
/** 复杂度档位（定义移至共享层 BackendRouter；此处 re-export 维持旧导入路径）。 */
export { TIER_ORDER };
/** 未单独配置模型的档位一律回退到 COMPLEX 的模型（上游 FALLBACK_TIER）。 */
const FALLBACK_TIER = 'COMPLEX';
/** 本地档位关闭：全部升级云侧，本地仅作降级目标（上游 local_capability=None）。 */
export const CAPABILITY_NONE = 'NONE';
/** 预览窗下限（上游 MIN_PREVIEW_CHARS）。 */
const MIN_PREVIEW_CHARS = 256;
/** 分类器预览预算（上游 classifier_preview_chars 默认 6000）。 */
const DEFAULT_PREVIEW_CHARS = 6000;
/** 喂给分类器的对话窗口条数（上游 WINDOW）。 */
const PREVIEW_WINDOW = 6;
/** 预览中段截断标记（上游 _bounded_text marker）。 */
const TRUNCATE_MARKER = '\n...[truncated]...\n';
/** 检索文本字节上限（上游 QUERY_MAX_TEXT_BYTES）。 */
const QUERY_MAX_TEXT_BYTES = 16384;

// 决策规则名（对齐上游 RULE_* 常量，进 reason 字段便于遥测比对）。
const RULE_WITHIN_LOCAL_CAPABILITY = 'within_local_capability';
const RULE_ESCALATE_CLOUD = 'escalate_cloud';
const RULE_TARGET_EXCLUDED_DEGRADE = 'target_excluded_degrade';

/**
 * 上游 RouterError::NoTarget：目标全被排除/不可用时决策层抛错，
 * 由宿主（RouterChat）兜底；决策止于抛错，不再自行降级。
 */
export class NoTargetError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NoTargetError';
  }
}

// 档位来源标记（对齐上游 SOURCE_* 常量）：分类器健康度可从路由遥测单独观测。
const SOURCE_LLM = 'llm';
const SOURCE_HEURISTIC = 'heuristic';
const SOURCE_HEURISTIC_FALLBACK = 'heuristic_fallback';
const SOURCE_PARSE_FAILED = 'parse_failed';
const SOURCE_UNAVAILABLE = 'unavailable';

// 启发式阈值（上游冻结契约原样保留：词数 80/400/1200、user 轮次 2/6、问号数 3）。
const TOKENS_MEDIUM = 80;
const TOKENS_COMPLEX = 400;
const TOKENS_RESEARCH = 1200;
const USER_TURNS_MEDIUM = 2;
const USER_TURNS_COMPLEX = 6;
const QUESTIONS_COMPLEX = 3;

// 关键词表为上游英文冻结集，不扩充中文：中文输入由 LLM 分类器主路径覆盖，
// 启发式仅作兜底（上游对中文同样失明，这是严格移植的既定行为）。
const REASONING_KEYWORDS: string[] = [
  'prove', 'proof', 'theorem', 'lemma', 'corollary', 'axiom',
  'formal verification', 'formal proof', 'mathematical proof',
  'by induction', 'induction hypothesis', 'qed',
  'contrapositive', 'bijection', 'isomorphism',
  'differential equation', 'eigenvalue', 'tensor calculus',
  'fourier transform', 'laplace transform',
  'np-complete', 'np-hard', 'sat solver', 'model checking'
];
const RESEARCH_KEYWORDS: string[] = [
  'quantum entanglement', 'quantum cryptography', 'quantum computing',
  "bell's inequality", 'epr paradox', 'wave function collapse',
  'qubit', 'decoherence',
  'genomics', 'proteomics', 'pharmacokinetics', 'pharmacodynamics',
  'pathophysiology', 'epidemiology', 'clinical trial', 'meta-analysis',
  'neurological', 'etiology', 'comorbidity',
  'jurisprudence', 'constitutional law', 'case precedent',
  'litigation', 'habeas corpus', 'estoppel',
  'derivative pricing', 'black-scholes', 'monte carlo simulation',
  'stochastic process', 'martingale',
  'transformer architecture', 'attention mechanism', 'rlhf',
  'systematic review', 'literature review', 'survey paper'
];
const COMPLEX_KEYWORDS: string[] = [
  'analyze all', 'analyze multiple', 'across all files',
  'end-to-end', 'architecture design', 'root cause analysis',
  'multi-step plan', 'step by step plan', 'step by step', 'step-by-step',
  'compare and contrast', 'trade-off analysis',
  'long document', 'entire codebase'
];
const MEDIUM_KEYWORDS: string[] = [
  'write a script', 'write a function', 'generate code', 'implement',
  'refactor', 'optimize', 'rewrite', 'debug', 'fix this bug',
  'how does', 'how do i',
  'summarize', 'translate', 'convert', 'parse', 'extract'
];

const LEVEL_RE = /^\s*(SIMPLE|MEDIUM|COMPLEX|RESEARCH|REASONING)\s*$/i;
const WHITESPACE_RE = /\s+/;

// 分类器 prompt 模板（上游 PROMPT_TEMPLATE 逐字移植，{content} 为预览占位）。
const PROMPT_TEMPLATE = `Classify the work needed in the next assistant turn as SIMPLE, MEDIUM, COMPLEX, RESEARCH, or REASONING.
Use the overall user goal and recent assistant/tool progress to identify what remains. Ignore system prompts, tool definitions, and completed work.

Levels:
SIMPLE: A direct, single-step response using supplied context, with no substantive transformation or execution.
MEDIUM: Bounded drafting, editing, summarization, calculation, coding, data transformation, or routine tool/file work with clear steps.
COMPLEX: Substantial planning, implementation, debugging, design, or analysis requiring broad context or multiple interdependent steps or artifacts.
RESEARCH: Investigative work requiring gathering, evaluation, comparison, and synthesis across multiple sources.
REASONING: A hard problem where rigorous multi-hop inference, formal proof, derivation, or verification is the central work.

Locality: SIMPLE and MEDIUM are local-only; COMPLEX, RESEARCH, and REASONING are cloud tiers. If the next step requires internet access, external sources, or a remote API, choose among the three cloud tiers by the definitions above; external access alone does not distinguish among them. Looking up current or live data, or using a remote service through a tool or CLI, requires a cloud tier. Writing code or instructions that may use an API later does not itself require cloud access.
Classify the remaining step, not the entire original task. The mere availability of tools must not affect the level.

Conversation and recent progress:
{content}

Reply with ONLY the tier name.`;

/** cloud_config.json 里 x-router 关心的字段。 */
interface XRouterConfigJson {
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  /** qwen3 系思考吃预算，true = 云请求体带 enable_thinking:false（分类器/裁判/主路径共用）。 */
  disableThinking?: boolean;
  xRouter?: XRouterConfigSection;
}

interface XRouterConfigSection {
  localCapabilityLevel?: string;
  tierModels?: Record<string, string>;
  classifierPreviewChars?: number;
  classifier?: ClassifierConfigSection;
  judge?: JudgeConfigSection;
  bandit?: BanditConfigSection;
  shadow?: boolean;
}

/** 上游 [x-router.classifier_model] 的 api 版形状。 */
interface ClassifierConfigSection {
  enabled?: boolean;
  model?: string;
  timeoutSeconds?: number;
  /** 分类请求 max_tokens；推理模型需覆盖思考阶段，缺省 2048。 */
  maxTokens?: number;
}

/** 上游 [x-router.judge_model] 的 api 版形状（质量裁判，宿主服务段）。 */
interface JudgeConfigSection {
  enabled?: boolean;
  model?: string;
  timeoutSeconds?: number;
  /** 裁判请求 max_tokens；推理模型需覆盖思考阶段，缺省 2048。 */
  maxTokens?: number;
}

/** 上游 [x-router.bandit] 段：store 子表此处即读，决策参数字段由 loadParams bandit 段解析。 */
interface BanditConfigSection {
  enabled?: boolean;
  store?: StoreConfigSection;
  minNeighbors?: number;
  margin?: number;
  lambdaC?: number;
  costRefUsd?: number;
}

/** 上游 [x-router.bandit.store] 段（时间项以秒配置，装配转 ms）。 */
interface StoreConfigSection {
  retrieverDim?: number;
  maxEntries?: number;
  topK?: number;
  minSimilarity?: number;
  forgettingGamma?: number;
  pendingTtlSeconds?: number;
  exclusionTtlSeconds?: number;
}

/** 裁判传输装配参数。 */
export interface JudgeServiceConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
  timeoutSeconds: number;
  maxTokens: number;
  disableThinking: boolean;
}

/** 服务装配配置（loadServiceConfig 产物）：judge 与 store 任一激活即非 null。 */
export interface XRouterServiceConfig {
  judge: JudgeServiceConfig | null;
  /** null = store 表缺省（judge 启用即由宿主以默认参数激活 store）。 */
  storeParams: BanditStoreParams | null;
}

/**
 * 分类器传输槽（上游 ComplexityBackend）：只收成品 prompt、只回原始输出，
 * 严格单标签解析在 XRouter 侧。上游为同步调用 + torch 本地模型；本环境为
 * 云端 OpenAI 兼容端点，宿主侧以异步包装（上游文档明言 route() 会阻塞至分类器超时）。
 */
export interface ComplexityBackend {
  classifyAsync(prompt: string): Promise<string>;
}

/** x-router 参数（上游 XRouterParams 的移植；localModel 固定 'local'——本地执行器唯一）。 */
export interface XRouterParams {
  localCapabilityLevel: string;
  tierModels: Map<string, string>;
  previewChars: number;
  backend: ComplexityBackend | null;
  /** 本环境增量（上游无）：影子模式只记分档日志，实际路由沿用 config 语义。 */
  shadow: boolean;
  /** 档位覆写参数（上游 params.bandit）；缺省/null = bandit 关闭。 */
  bandit?: BanditParams | null;
}

interface ClassifyResult {
  tier: string;
  source: string;
}

interface TierDecision {
  model: string;
  rule: string;
}

interface ConversationEntry {
  role: string;
  content: string;
}

/**
 * x-router 复杂度分档路由（gitcode jiuwen_device/model-router 严格移植）。
 * 决策链：分类（LLM 分类器优先——构建/调用/解析三段失败分别落回启发式，
 * 任何故障只降不升）→ 档位映射（tier ≤ 本地能力（含）→ 本地；超过 →
 * 档位映射的云模型；目标被状态排除 → 降级本地）。
 * 环境性偏离（已注释）：分类器为云端 API 而非本地 torch；tool_call_depth 恒 0
 * （wire 协议无 tool_calls）；目标目录由两侧就绪度 + 状态排除构成（上游为
 * 配置目录减排除）；RoutingKey 退化为全局单键。
 */
export class XRouter implements RouteStrategy {
  private readonly params: XRouterParams;

  constructor(params: XRouterParams) {
    this.params = params;
    hilog.info(0, 'NearbyChat', 'x-router level=%{public}s shadow=%{public}s backend=%{public}s',
      params.localCapabilityLevel, `${params.shadow}`, params.backend === null ? 'heuristic' : 'llm');
  }

  decideAsync(context: RouteContext, status: BackendStatus): Promise<RouteDecision> {
    const targets = this.targetsOf(status);
    if (targets.length === 0) {
      // 上游 no available target → RouterError::NoTarget；抛错由宿主兜底（决策层不再自行降级）。
      return Promise.reject(new NoTargetError('no available target'));
    }
    return this.classify(context).then((pair: ClassifyResult): RouteDecision => {
      // bandit 档位覆写（上游 algorithm.route）：参数在场才读 retrieved；覆写后的
      // 终档进 tier/reason，LLM 原档进 tier_llm。未配置 → reasoning 逐字节不变。
      let tier = pair.tier;
      let note = '';
      if (this.params.bandit !== null && this.params.bandit !== undefined) {
        const retrieved: RetrievedItem[] = context.retrieved !== undefined && context.retrieved !== null
          ? context.retrieved : [];
        const choice = chooseTier(pair.tier, retrieved, this.params.bandit);
        tier = choice.tier;
        note = ' tier_llm=' + pair.tier + ' bandit=' + choice.code + ' neighbors=' + choice.neighbours;
      }
      const mapped = this.decideByTier(tier, targets);
      const reasoning = 'x-router: rule=' + mapped.rule + ' tier=' + tier + ' source=' + pair.source + note;
      const side = mapped.model === 'local' ? 'local' : 'cloud';
      if (this.params.shadow) {
        const effective = status.cloudReady ? 'cloud' : 'local';
        return {
          side: effective, reason: reasoning + ' shadow=true would=' + side,
          tier: tier, model: mapped.model
        };
      }
      return { side: side, reason: reasoning, tier: tier, model: mapped.model };
    });
  }

  static tierRank(tier: string): number {
    return tierRankOf(tier);
  }

  /** 严格单标签解析（上游 parse_complexity）：整串必须恰为一个档名；散文/多标签一律拒绝。 */
  static parseTier(value: string): string {
    const match = LEVEL_RE.exec(`${value ?? ''}`);
    if (match === null) return '';
    return match[1].toUpperCase();
  }

  /**
   * 目标目录（上游 [targets] models 语义）：本地模型（就绪时）+ 各档云模型
   * （云侧就绪时），再剔除状态排除项。上游无就绪度概念，此处把"不可运行"
   * 折叠为"不在目录"。
   */
  private targetsOf(status: BackendStatus): string[] {
    const declared: string[] = [];
    if (status.localReady) declared.push('local');
    if (status.cloudReady) {
      this.params.tierModels.forEach((model: string): void => {
        if (declared.indexOf(model) < 0) declared.push(model);
      });
    }
    return declared.filter((model: string): boolean => status.exclusions.indexOf(model) < 0);
  }

  /**
   * 档位映射（上游 decide_by_tier 逐句移植）：tier ≤ 本地能力（含）→ 本地；
   * 超过 → 档位模型；档位模型不在目标目录 → 降级本地（降级永远安全，升级不安全）。
   * 注意上游 quirk：本地自身被排除时 _pick 落到目录首个目标，规则名不变。
   */
  private decideByTier(tier: string, targets: string[]): TierDecision {
    const capability = this.params.localCapabilityLevel;
    if (capability !== CAPABILITY_NONE && XRouter.tierRank(tier) <= XRouter.tierRank(capability)) {
      return { model: XRouter.pick('local', targets), rule: RULE_WITHIN_LOCAL_CAPABILITY };
    }
    const model = this.modelFor(tier);
    if (targets.indexOf(model) < 0) {
      return { model: XRouter.pick('local', targets), rule: RULE_TARGET_EXCLUDED_DEGRADE };
    }
    return { model: model, rule: RULE_ESCALATE_CLOUD };
  }

  /** 档位模型（上游 model_for）：未配置的档位回退 FALLBACK_TIER 的模型。 */
  private modelFor(tier: string): string {
    const mapped = this.params.tierModels.get(tier);
    if (mapped !== undefined && mapped.length > 0) return mapped;
    const fallback = this.params.tierModels.get(FALLBACK_TIER);
    return fallback !== undefined ? fallback : '';
  }

  /** 上游 _pick：首选被排除时落到目录首个目标。 */
  static pick(preferred: string, targets: string[]): string {
    if (targets.indexOf(preferred) >= 0) return preferred;
    return targets.length > 0 ? targets[0] : '';
  }

  /**
   * 分类（上游 classify 的三段失败移植）：backend 未配置 → 启发式；
   * prompt 构建失败 / 调用失败 → heuristic_fallback；解析失败 → parse_failed。
   * 铁律 no failure escalates：任何故障路径不得产生比启发式更高的档位。
   */
  private classify(context: RouteContext): Promise<ClassifyResult> {
    if (this.params.backend === null) {
      return Promise.resolve(this.safeHeuristic(context, SOURCE_HEURISTIC));
    }
    let prompt = '';
    try {
      prompt = XRouter.buildClassifierPrompt(context.messages, this.params.previewChars);
    } catch (error) {
      hilog.warn(0, 'NearbyChat', 'x-router classifier prompt build failed error=%{public}s',
        error instanceof Error ? error.message : 'unknown');
      return Promise.resolve(this.safeHeuristic(context, SOURCE_HEURISTIC_FALLBACK));
    }
    return this.params.backend.classifyAsync(prompt)
      .then((raw: string): ClassifyResult => {
        const tier = XRouter.parseTier(raw);
        if (tier === '') {
          hilog.warn(0, 'NearbyChat', 'x-router classifier parse failed raw=%{public}s',
            `${raw ?? ''}`.slice(0, 120));
          return this.safeHeuristic(context, SOURCE_PARSE_FAILED);
        }
        return { tier: tier, source: SOURCE_LLM };
      })
      .catch((error: Error): ClassifyResult => {
        hilog.warn(0, 'NearbyChat', 'x-router classifier call failed error=%{public}s',
          error.message ?? 'unknown');
        return this.safeHeuristic(context, SOURCE_HEURISTIC_FALLBACK);
      });
  }

  private safeHeuristic(context: RouteContext, source: string): ClassifyResult {
    try {
      return { tier: this.classifyHeuristic(context), source: source };
    } catch (_) {
      return { tier: 'MEDIUM', source: SOURCE_UNAVAILABLE };
    }
  }

  /**
   * 免模型分类器（上游 classify_heuristic 逐句移植）：关键词表/阈值/空白分词
   * 全部保持冻结。tool_call_depth 信号在本 wire 协议不可得（消息无 tool_calls
   * 字段），恒为 0，不虚构。
   */
  private classifyHeuristic(context: RouteContext): string {
    const view = XRouter.conversationView(context.messages);
    const text = view.map((entry: ConversationEntry): string => entry.content).join(' ').toLowerCase();
    const stripped = text.trim();
    const tokenCount = stripped.length > 0 ? stripped.split(WHITESPACE_RE).length : 0;
    const userTurns = view.filter((entry: ConversationEntry): boolean => entry.role === 'user').length;
    const questionCount = XRouter.countChar(text, '?') + XRouter.countChar(text, '？');
    if (XRouter.hasKeyword(text, REASONING_KEYWORDS)) return 'REASONING';
    if (XRouter.hasKeyword(text, RESEARCH_KEYWORDS) || tokenCount > TOKENS_RESEARCH) return 'RESEARCH';
    if (XRouter.hasKeyword(text, COMPLEX_KEYWORDS) || tokenCount > TOKENS_COMPLEX
      || userTurns > USER_TURNS_COMPLEX || questionCount > QUESTIONS_COMPLEX) return 'COMPLEX';
    if (XRouter.hasKeyword(text, MEDIUM_KEYWORDS) || tokenCount > TOKENS_MEDIUM
      || userTurns > USER_TURNS_MEDIUM) return 'MEDIUM';
    return 'SIMPLE';
  }

  /** 对话视图（上游 conversation_messages）：过滤脚手架与空消息。 */
  static conversationView(messages: ChatMessage[]): ConversationEntry[] {
    const view: ConversationEntry[] = [];
    for (const message of messages ?? []) {
      const role = (message.role ?? 'user').toLowerCase();
      const content = `${message.content ?? ''}`;
      if (XRouter.isScaffolding(role, content)) continue;
      const trimmed = content.trim();
      if (trimmed.length === 0) continue;
      view.push({ role: role, content: trimmed });
    }
    return view;
  }

  /** 上游 _is_scaffolding：system 消息，以及 agent 框架注入 user 轮的 system-reminder 块。 */
  private static isScaffolding(role: string, content: string): boolean {
    if (role === 'system') return true;
    const stripped = content.replace(/^\s+/, '');
    return stripped.startsWith('<system-reminder>') && stripped.indexOf('<prompt-attachment') >= 0;
  }

  /**
   * 有界对话预览（上游 conversation_preview）：取最近 WINDOW 条；若最新 user 轮
   * 已被挤出窗口则重新置顶（agent 循环尾部常全是 assistant 流量，不带这条
   * 分类器会看不到请求本身）。格式 [role]: text 逐行拼接。
   */
  static conversationPreview(messages: ChatMessage[], maxChars: number): string {
    const view = XRouter.conversationView(messages);
    let recent = view.slice(-PREVIEW_WINDOW);
    let latestUser: ConversationEntry | null = null;
    for (let index = view.length - 1; index >= 0; index--) {
      if (view[index].role === 'user') {
        latestUser = view[index];
        break;
      }
    }
    if (latestUser !== null && recent.indexOf(latestUser) < 0) {
      recent = [latestUser].concat(view.slice(-(PREVIEW_WINDOW - 1)));
    }
    const parts: string[] = [];
    for (const entry of recent) {
      parts.push('[' + entry.role + ']: ' + entry.content);
    }
    return XRouter.boundedText(parts.join('\n'), maxChars);
  }

  /** 上游 _bounded_text：超预算时保留开头与最近文本，中段以标记截断。 */
  private static boundedText(text: string, maxChars: number): string {
    if (text.length <= maxChars) return text;
    const available = maxChars - TRUNCATE_MARKER.length;
    const head = Math.floor(available / 2);
    return text.substring(0, head) + TRUNCATE_MARKER + text.substring(text.length - (available - head));
  }

  /** 上游 build_classifier_request：空对话抛错（→ heuristic_fallback）。 */
  static buildClassifierPrompt(messages: ChatMessage[], maxChars: number): string {
    const content = XRouter.conversationPreview(messages, maxChars);
    if (content.length === 0) {
      throw new Error('classifier requires a non-empty conversation');
    }
    return PROMPT_TEMPLATE.replace('{content}', content);
  }

  /** 上游 retrieval_text：分类器同款预览再截 16KB UTF-8 字节（码点边界）。 */
  static retrievalText(messages: ChatMessage[], maxChars: number): string {
    return capUtf8Bytes(XRouter.conversationPreview(messages, maxChars), QUERY_MAX_TEXT_BYTES);
  }

  private static hasKeyword(text: string, keywords: string[]): boolean {
    for (const keyword of keywords) {
      if (text.indexOf(keyword) >= 0) return true;
    }
    return false;
  }

  private static countChar(text: string, ch: string): number {
    return text.split(ch).length - 1;
  }

  /**
   * 装配参数（上游 from_mapping + 校验语义移植）：任一参数非法即返回 null
   * 并记 error（上游 ParamsError 装配期失败；本环境 App 不因此拒启，路由
   * 回落 config 策略）。分类器构建规则对齐上游 classifier_model：enabled
   * 且云侧字段齐全 → 云端分类器；否则启发式兜底（上游明示的 heuristic-only 模式）。
   */
  /** 配置读取前奏（loadParams/loadServiceConfig 共享）：读文件+解析，失败记日志返回 null。 */
  private static readConfig(filesDir: string): XRouterConfigJson | null {
    let text = '';
    try {
      text = fileIo.readTextSync(filesDir + '/' + XROUTER_CONFIG_FILE);
    } catch (_) {
      return null;
    }
    try {
      return JSON.parse(text) as XRouterConfigJson;
    } catch (_) {
      hilog.error(0, 'NearbyChat', 'x-router params error: config parse failed');
      return null;
    }
  }

  static loadParams(filesDir: string): XRouterParams | null {
    const json = XRouter.readConfig(filesDir);
    if (json === null) return null;
    const section = json.xRouter;
    if (section === undefined || section === null) {
      hilog.error(0, 'NearbyChat', 'x-router params error: missing xRouter section');
      return null;
    }
    const rawCapability = section.localCapabilityLevel === undefined || section.localCapabilityLevel === null
      ? 'MEDIUM' : `${section.localCapabilityLevel}`;
    const capability = rawCapability.trim().toUpperCase();
    let localCapabilityLevel = CAPABILITY_NONE;
    if (capability !== CAPABILITY_NONE) {
      if (XRouter.tierRank(capability) < 0) {
        hilog.error(0, 'NearbyChat', 'x-router params error: unknown localCapabilityLevel=%{public}s', capability);
        return null;
      }
      localCapabilityLevel = capability;
    }
    const tierModels = new Map<string, string>();
    const rawModels = section.tierModels;
    if (rawModels !== undefined && rawModels !== null) {
      for (const key of Object.keys(rawModels)) {
        const tier = `${key}`.trim().toUpperCase();
        if (XRouter.tierRank(tier) < 0) {
          hilog.error(0, 'NearbyChat', 'x-router params error: unknown tier_models key=%{public}s', `${key}`);
          return null;
        }
        const model = `${rawModels[key] ?? ''}`.trim();
        if (model.length === 0) {
          hilog.error(0, 'NearbyChat', 'x-router params error: empty tier_models[%{public}s]', tier);
          return null;
        }
        tierModels.set(tier, model);
      }
    }
    if (!tierModels.has(FALLBACK_TIER)) {
      hilog.error(0, 'NearbyChat', 'x-router params error: tier_models must define %{public}s', FALLBACK_TIER);
      return null;
    }
    let previewChars = DEFAULT_PREVIEW_CHARS;
    if (section.classifierPreviewChars !== undefined && section.classifierPreviewChars !== null) {
      const parsed = Math.floor(Number(section.classifierPreviewChars));
      if (!(parsed >= MIN_PREVIEW_CHARS)) {
        hilog.error(0, 'NearbyChat', 'x-router params error: classifierPreviewChars must be at least %{public}d',
          MIN_PREVIEW_CHARS);
        return null;
      }
      previewChars = parsed;
    }
    let backend: ComplexityBackend | null = null;
    const classifier = section.classifier;
    if (classifier !== undefined && classifier !== null && classifier.enabled === true) {
      const apiKey = (json.apiKey ?? '').trim();
      const baseUrl = (json.baseUrl ?? '').trim();
      const model = (classifier.model ?? json.model ?? '').trim();
      if (apiKey.length === 0 || baseUrl.length === 0 || model.length === 0) {
        hilog.warn(0, 'NearbyChat', 'x-router classifier enabled but cloud config incomplete, heuristic-only');
      } else {
        let timeoutSeconds = 30;
        if (typeof classifier.timeoutSeconds === 'number' && Number.isFinite(classifier.timeoutSeconds)) {
          timeoutSeconds = Math.min(120, Math.max(5, Math.floor(classifier.timeoutSeconds)));
        }
        let maxTokens = 2048;
        if (typeof classifier.maxTokens === 'number' && Number.isFinite(classifier.maxTokens)) {
          maxTokens = Math.min(4096, Math.max(16, Math.floor(classifier.maxTokens)));
        }
        backend = new CloudClassifier(apiKey, baseUrl, model, timeoutSeconds, maxTokens, json.disableThinking === true);
      }
    }
    // bandit 段（上游 params.bandit）：缺省或 enabled:false → null；表存在且
    // enabled≠false → 启用（上游默认 true，Stage 1 必须显式 "enabled": false）。
    // 任一参数非法 → 整体 null（回落 config 策略，语义同其他段）。store 子表
    // 不在此读（服务参数，见 loadServiceConfig）。
    let bandit: BanditParams | null = null;
    const banditSection = section.bandit;
    if (banditSection !== undefined && banditSection !== null && banditSection.enabled !== false) {
      const banditParams = defaultBanditParams();
      let parsed: number | null;
      if (banditSection.minNeighbors !== undefined && banditSection.minNeighbors !== null) {
        parsed = XRouter.num(banditSection.minNeighbors);
        if (parsed === null || Math.floor(parsed) !== parsed || parsed < 1) return null;
        banditParams.minNeighbors = parsed;
      }
      if (banditSection.margin !== undefined && banditSection.margin !== null) {
        parsed = XRouter.num(banditSection.margin);
        if (parsed === null || parsed < 0) return null;
        banditParams.margin = parsed;
      }
      if (banditSection.lambdaC !== undefined && banditSection.lambdaC !== null) {
        parsed = XRouter.num(banditSection.lambdaC);
        if (parsed === null || parsed < 0) return null;
        banditParams.lambdaC = parsed;
      }
      if (banditSection.costRefUsd !== undefined && banditSection.costRefUsd !== null) {
        parsed = XRouter.num(banditSection.costRefUsd);
        if (parsed === null || parsed <= 0) return null;
        banditParams.costRefUsd = parsed;
      }
      bandit = banditParams;
    }
    return {
      localCapabilityLevel: localCapabilityLevel,
      tierModels: tierModels,
      previewChars: previewChars,
      backend: backend,
      shadow: section.shadow === true,
      bandit: bandit
    };
  }

  /** 数值字段提取：非数（含 bool）/非有限 → null。 */
  private static num(value: number | undefined | null): number | null {
    if (typeof value !== 'number' || !Number.isFinite(value)) return null;
    return value;
  }

  /**
   * store 子表逐字段校验（宿主侧）：未写字段取默认；写了即校验，任一非法整体
   * null（对齐 loadParams 的严格回落语义）。时间为秒→毫秒。上限为宿主内存
   * 护栏（每条记录一个 dim 维向量）。
   */
  private static parseStoreSection(section: StoreConfigSection): BanditStoreParams | null {
    const params: BanditStoreParams = defaultStoreParams();
    let parsed: number | null;
    if (section.retrieverDim !== undefined && section.retrieverDim !== null) {
      parsed = XRouter.num(section.retrieverDim);
      if (parsed === null || Math.floor(parsed) !== parsed || parsed < 1 || parsed > 1_048_576) return null;
      params.retrieverDim = parsed;
    }
    if (section.maxEntries !== undefined && section.maxEntries !== null) {
      parsed = XRouter.num(section.maxEntries);
      if (parsed === null || Math.floor(parsed) !== parsed || parsed < 1 || parsed > 100_000) return null;
      params.maxEntries = parsed;
    }
    if (section.topK !== undefined && section.topK !== null) {
      parsed = XRouter.num(section.topK);
      if (parsed === null || Math.floor(parsed) !== parsed || parsed < 1 || parsed > 256) return null;
      params.topK = parsed;
    }
    if (section.minSimilarity !== undefined && section.minSimilarity !== null) {
      parsed = XRouter.num(section.minSimilarity);
      if (parsed === null || parsed < 0 || parsed > 1) return null;
      params.minSimilarity = parsed;
    }
    if (section.forgettingGamma !== undefined && section.forgettingGamma !== null) {
      parsed = XRouter.num(section.forgettingGamma);
      if (parsed === null || parsed <= 0 || parsed > 1) return null;
      params.forgettingGamma = parsed;
    }
    if (section.pendingTtlSeconds !== undefined && section.pendingTtlSeconds !== null) {
      parsed = XRouter.num(section.pendingTtlSeconds);
      if (parsed === null || parsed <= 0) return null;
      params.pendingTtlMs = parsed * 1000;
    }
    if (section.exclusionTtlSeconds !== undefined && section.exclusionTtlSeconds !== null) {
      parsed = XRouter.num(section.exclusionTtlSeconds);
      if (parsed === null || parsed <= 0) return null;
      params.exclusionTtlMs = parsed * 1000;
    }
    return params;
  }

  /**
   * 服务装配配置（上游 [x-router.judge_model]/[x-router.bandit.store] 的本环境读法）：
   * judge 段 enabled 且凭据齐全才建（缺凭据 warn 后停用，对齐分类器降级路径）；
   * store 子表存在即逐字段校验，非法整体 null。judge 与 store 均未激活 → null
   * （无服务，行为同旧）。模型回落顶层 model；超时/令牌钳制为推理模型适配区间。
   */
  static loadServiceConfig(filesDir: string): XRouterServiceConfig | null {
    const json = XRouter.readConfig(filesDir);
    if (json === null) return null;
    const section = json.xRouter;
    if (section === undefined || section === null) return null;

    let judge: JudgeServiceConfig | null = null;
    const judgeSection = section.judge;
    if (judgeSection !== undefined && judgeSection !== null && judgeSection.enabled === true) {
      const apiKey = (json.apiKey ?? '').trim();
      const baseUrl = (json.baseUrl ?? '').trim();
      const model = (judgeSection.model ?? json.model ?? '').trim();
      if (apiKey.length === 0 || baseUrl.length === 0 || model.length === 0) {
        hilog.warn(0, 'NearbyChat', 'x-router judge enabled but cloud config incomplete, judge off');
      } else {
        let timeoutSeconds = 60;
        const rawTimeout = XRouter.num(judgeSection.timeoutSeconds);
        if (rawTimeout !== null) {
          timeoutSeconds = Math.min(120, Math.max(5, Math.floor(rawTimeout)));
        }
        let maxTokens = 2048;
        const rawTokens = XRouter.num(judgeSection.maxTokens);
        if (rawTokens !== null) {
          maxTokens = Math.min(8192, Math.max(16, Math.floor(rawTokens)));
        }
        const built: JudgeServiceConfig = {
          apiKey: apiKey,
          baseUrl: baseUrl,
          model: model,
          timeoutSeconds: timeoutSeconds,
          maxTokens: maxTokens,
          disableThinking: json.disableThinking === true
        };
        judge = built;
      }
    }

    let storeParams: BanditStoreParams | null = null;
    const banditSection = section.bandit;
    const storeSection = banditSection === undefined || banditSection === null
      ? undefined : banditSection.store;
    if (storeSection !== undefined && storeSection !== null) {
      storeParams = XRouter.parseStoreSection(storeSection);
      if (storeParams === null) {
        hilog.error(0, 'NearbyChat', 'x-router service error: invalid bandit.store section');
        return null;
      }
    }

    if (judge === null && storeParams === null) return null;
    const config: XRouterServiceConfig = { judge: judge, storeParams: storeParams };
    return config;
  }
}
