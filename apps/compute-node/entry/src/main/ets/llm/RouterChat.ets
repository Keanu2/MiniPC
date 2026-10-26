import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatBackend, ChatMessage, ChatStartOptions, ChatUpdate, LocalChat } from './LocalChat';
import { CloudChat } from './CloudChat';
import { BackendRouter, BackendStatus, RouteContext, RouteDecision } from './BackendRouter';
import { BanditStore, defaultStoreParams, StoreStats } from './BanditStore';
import { XRouter, XRouterParams } from './XRouter';
import { Judge, JudgeClient, JudgeTransport } from './Judge';

/** 单会话应用的路由反馈键（上游 RoutingKey(session, agent) 在此退化为全局键）。 */
const ROUTING_KEY = 'default';
/** 上游 react_agent.call_model 的尝试上限（4 次总尝试）。 */
const MAX_ATTEMPTS = 4;
/** 上游 DEFAULT_QUEUE_SIZE：在飞 settle 上限，超限丢弃（丢分无害——store 只是提示）。 */
const SETTLE_QUEUE_CAP = 256;
/** 预览预算兜底（与 XRouter 默认一致；正常路径由 service.previewChars 携带）。 */
const DEFAULT_PREVIEW_CHARS = 6000;

/**
 * 宿主服务装配（RouterChat.buildService 产物）。
 * service 非 null 即 store 激活（judge 或 store 表任一在场，上游 _retrieve 语义）。
 */
export interface RouterService {
  store: BanditStore;
  judge: JudgeTransport | null;
  /** bandit 参数在场：attemptRoute 以 query 填 context.retrieved；否则仅 openPending（跳过 kNN）。 */
  banditEnabled: boolean;
  previewChars: number;
  queueCap: number;
}

/** settle 漏斗计数（上游 XRouterService.stats 形状；judgeFailed 上升是路由层看不到的信号）。 */
export interface SettleStats {
  submitted: number;
  settled: number;
  judgeFailed: number;
  droppedFull: number;
  inflight: number;
  store: StoreStats;
}

interface SettleCounts {
  submitted: number;
  settled: number;
  judgeFailed: number;
  droppedFull: number;
}

/**
 * 端侧/云侧分派器：对上层（InferenceHost/LlmTransport）呈现单一 ChatBackend，
 * 每次请求经 BackendRouter 异步决策后转发给 LocalChat 或 CloudChat。
 * 默认策略 'config' 下行为与单后端直连完全一致；两侧互不干扰，
 * cancel/close 同时下发两侧（空闲侧为 no-op）。
 * 决策/执行结果回流 BanditStore（上游 MemoryState 语义，bandit_store 移植）：
 * 失败→排除该模型（下次决策降级），成功→亲和；取消不产生观察。失败处理对齐上游
 * react_agent：后端失败/拒收 → 上报 Outcome（overflow/unavailable 进排除表）→
 * 同请求重路由换目标重试，上限 4 次，仅 xrouter 策略启用（config 等维持单次直连语义）。
 * 质量闭环（上游 XRouterService）：storeActive 时 attemptRoute 以 retrievalText
 * 开两阶段记录（bandit 开→query 取近邻塞 context.retrieved；关→openPending 只开
 * 记录）；done-ok 且 judge 在场 → scheduleSettle 异步评分上报（不上请求路径），
 * 队列上限 256，失败只计数、日志按 1/10/100/1000 节流。
 */
export class RouterChat implements ChatBackend {
  private readonly local: LocalChat;
  private readonly cloud: CloudChat | null;
  private readonly router: BackendRouter;
  /** 反馈状态（上游 BanditStore，收编 MemoryState 语义；service 未注入时默认参数）。 */
  private readonly store: BanditStore;
  /** 服务装配（judge/settle/两阶段记录）；null = 无服务，行为同旧（仅 call 状态）。 */
  private readonly service: RouterService | null;
  private closed: boolean = false;
  private last: RouteDecision | null = null;
  /** routeId 序号：每次 route 调用唯一（上游 route_id；重试不撞 pending 键）。 */
  private routeSeq: number = 0;
  private inflight: number = 0;
  private readonly settleCounts: SettleCounts = { submitted: 0, settled: 0, judgeFailed: 0, droppedFull: 0 };

  constructor(local: LocalChat, cloud: CloudChat | null, router: BackendRouter,
    service: RouterService | null = null) {
    this.local = local;
    this.cloud = cloud;
    this.router = router;
    this.service = service;
    this.store = service !== null ? service.store : new BanditStore(defaultStoreParams());
  }

  /** 最近一次路由决策（展示/排查用；尚无请求时为 null）。 */
  lastDecision(): RouteDecision | null { return this.last; }

  routePolicy(): string { return this.router.policy(); }

  isBusy(): boolean {
    return this.local.isBusy() || (this.cloud !== null && this.cloud.isBusy());
  }

  activeCount(): number {
    return this.local.activeCount() + (this.cloud !== null ? this.cloud.activeCount() : 0);
  }

  /** 任一侧可服务即就绪；两侧都不可用时回报端侧的具体错误（与单后端时代一致）。 */
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    if (this.local.readinessError() === '') return '';
    if (this.cloud !== null && this.cloud.readinessError() === '') return '';
    return this.local.readinessError();
  }

  hasPendingNativeJobs(): boolean { return this.local.hasPendingNativeJobs(); }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId: string = '',
    options: ChatStartOptions = {}): string {
    if (this.closed) return '模型服务已关闭。';
    if (messages.length === 0) return '请输入问题。';
    if ((options.image ?? '').length > 0 && this.router.policy() === 'xrouter') {
      // 图片宿主预检（自 XRouter 决策层移出）：云侧不收图，直接钉本地，单发不重试。
      // routeId=''：未走 attemptRoute，无 pending 可关，也不评分。
      const pinned: RouteDecision = { side: 'local', reason: 'host: rule=image_local tier=NA source=na' };
      this.dispatch(pinned, messages, callback, requestId, options, MAX_ATTEMPTS, '');
      return '';
    }
    this.attemptRoute(messages, callback, requestId, options, 1);
    return '';
  }

  /**
   * 上游 react_agent.call_model 的分派循环：每次尝试完整重路由（决策读最新
   * 排除表），失败上报 outcome 后换目标重试；取消不重试。storeActive 时先以
   * retrievalText 开两阶段记录（上游 route() 的 state hint 语义）。
   */
  private attemptRoute(messages: ChatMessage[], callback: (update: ChatUpdate) => void,
    requestId: string, options: ChatStartOptions, attempt: number): void {
    const context = this.contextOf(messages, options);
    this.routeSeq = this.routeSeq + 1;
    const routeId = (requestId.length > 0 ? requestId : 'req') + '#' + this.routeSeq;
    if (this.service !== null && this.router.policy() === 'xrouter') {
      const text = XRouter.retrievalText(context.messages, this.service.previewChars);
      if (this.service.banditEnabled) {
        const query = this.store.query(ROUTING_KEY, text, routeId);
        context.retrieved = query.retrieved;
      } else {
        this.store.openPending(routeId, text);
      }
    }
    this.router.routeAsync(context, this.snapshot())
      .then((decision: RouteDecision): void => {
        this.dispatch(decision, messages, callback, requestId, options, attempt, routeId);
      })
      .catch((error: Error): void => {
        // NoTarget：全目标被排除 → 宿主兜底本地（失败重试再入 attemptRoute，attempt 封顶）。
        if (error.name === 'NoTargetError') {
          hilog.warn(0, 'NearbyChat', 'host: no-target fallback local request=%{public}s', requestId);
          // 决策未产出选择，该 routeId 的 pending 无可报观察（上游同语义），交 TTL 过期。
          const fallback: RouteDecision = { side: 'local', reason: 'host: no available target' };
          this.dispatch(fallback, messages, callback, requestId, options, attempt, '');
          return;
        }
        callback({ kind: 'done', text: '', error: '路由决策失败，请重试。', finishReason: 'error' });
      });
  }

  /** 决策落地：记录并转发到选中后端；失败上报 outcome 后按上游语义降级重试。 */
  private dispatch(decision: RouteDecision, messages: ChatMessage[],
    callback: (update: ChatUpdate) => void, requestId: string, options: ChatStartOptions,
    attempt: number, routeId: string): void {
    this.last = decision;
    const modelId = this.modelIdOf(decision);
    hilog.info(0, 'NearbyChat',
      'route side=%{public}s policy=%{public}s reason=%{public}s model=%{public}s request=%{public}s',
      decision.side, this.router.policy(), decision.reason, modelId, requestId);
    let backend: ChatBackend;
    if (decision.side === 'cloud') {
      if (this.cloud === null) {
        callback({ kind: 'done', text: '', error: '云侧模型未配置，无法路由到云侧。', finishReason: 'error' });
        return;
      }
      backend = this.cloud;
    } else {
      backend = this.local;
    }
    // 已流出 delta 的失败不重试：上游 invoke 要么整段返回要么抛错，没有
    // "流一半再失败"的形态；重试会让第二次的 delta 拼在第一次后面。
    let emitted = false;
    const wrapped = (update: ChatUpdate): void => {
      if (update.kind !== 'done' || update.finishReason === 'cancelled') {
        emitted = true;
        callback(update);
        return;
      }
      const failed = (update.error !== undefined && update.error.length > 0) ||
        update.text.trim().length === 0;
      if (!failed) {
        this.store.reportCall(ROUTING_KEY, modelId, 'ok');
        if (routeId.length > 0 && this.service !== null && this.service.judge !== null) {
          this.scheduleSettle(routeId, decision, messages, update.text);
        }
        callback(update);
        return;
      }
      const outcome = update.failureKind === 'overflow' ? 'overflow' : 'unavailable';
      hilog.warn(0, 'NearbyChat', 'backend failed model=%{public}s outcome=%{public}s error=%{public}s',
        modelId, outcome, update.error ?? '');
      this.store.reportCall(ROUTING_KEY, modelId, outcome);
      if (this.canRetry(attempt) && !emitted) {
        hilog.info(0, 'NearbyChat', 'route retry attempt=%{public}d after=%{public}s request=%{public}s',
          attempt + 1, modelId, requestId);
        this.attemptRoute(messages, callback, requestId, options, attempt + 1);
        return;
      }
      if (update.error === undefined || update.error.length === 0) {
        const finalUpdate: ChatUpdate = {
          kind: 'done',
          text: '',
          error: '模型未返回内容，请重试。',
          finishReason: update.finishReason
        };
        callback(finalUpdate);
        return;
      }
      callback(update);
    };
    const refused = backend.start(messages, wrapped, requestId, options);
    if (refused.length > 0) {
      hilog.warn(0, 'NearbyChat', 'backend refused model=%{public}s error=%{public}s', modelId, refused);
      this.store.reportCall(ROUTING_KEY, modelId, 'unavailable');
      if (this.canRetry(attempt)) {
        this.attemptRoute(messages, callback, requestId, options, attempt + 1);
        return;
      }
      callback({ kind: 'done', text: '', error: refused, finishReason: 'error' });
    }
  }

  /**
   * 上游 XRouterService._submit/_run_settle：异步评分上报（不上请求路径）。
   * 队列满/已关闭 → droppedFull 计数（节流日志）；失败只计数 judgeFailed（节流）。
   * 请求文本在调度点即刻定界（消息此后不变，与 worker 内构建等价）；
   * cost 恒 0.0（自有端点，上游明示免费档报 0.0）。
   */
  private scheduleSettle(routeId: string, decision: RouteDecision, messages: ChatMessage[],
    responseText: string): void {
    const service = this.service;
    if (service === null || service.judge === null) return;
    if (this.closed || this.inflight >= service.queueCap) {
      this.settleCounts.droppedFull = this.settleCounts.droppedFull + 1;
      if (RouterChat.shouldLogCount(this.settleCounts.droppedFull)) {
        hilog.warn(0, 'NearbyChat', 'settle queue full inflight=%{public}d dropped=%{public}d',
          this.inflight, this.settleCounts.droppedFull);
      }
      return;
    }
    this.inflight = this.inflight + 1;
    this.settleCounts.submitted = this.settleCounts.submitted + 1;
    const request = Judge.buildJudgeRequest(messages, responseText);
    service.judge.scoreAsync(request)
      .then((raw: string): void => {
        const quality = Judge.parseJudgeScore(raw);
        const tier = decision.tier;
        if (tier === undefined || tier.length === 0) {
          throw new Error('settle: decision carries no tier');
        }
        this.store.reportObservation(routeId, tier, quality, 0.0);
        this.settleCounts.settled = this.settleCounts.settled + 1;
        hilog.info(0, 'NearbyChat', 'judge settled quality=%{public}s tier=%{public}s route=%{public}s',
          quality.toFixed(3), tier, routeId);
        const stats = this.store.stats();
        hilog.info(0, 'NearbyChat',
          'store stats pending=%{public}d closed=%{public}d dropped=%{public}d unknown=%{public}d',
          stats.pending, stats.closed, stats.dropped, stats.unknown);
      })
      .catch((_error: Error): void => {
        this.settleCounts.judgeFailed = this.settleCounts.judgeFailed + 1;
        if (RouterChat.shouldLogCount(this.settleCounts.judgeFailed)) {
          hilog.warn(0, 'NearbyChat', 'judge settle failed count=%{public}d', this.settleCounts.judgeFailed);
        }
      })
      .then((): void => {
        this.inflight = this.inflight - 1;
      });
  }

  /** 上游失败日志节流点（1/10/100/1000）。 */
  private static shouldLogCount(count: number): boolean {
    return count === 1 || count === 10 || count === 100 || count === 1000;
  }

  /** settle 漏斗 + store 计数（排查用；unknown 上升 = routeId/pending 不匹配）。 */
  serviceStats(): SettleStats {
    const stats: SettleStats = {
      submitted: this.settleCounts.submitted,
      settled: this.settleCounts.settled,
      judgeFailed: this.settleCounts.judgeFailed,
      droppedFull: this.settleCounts.droppedFull,
      inflight: this.inflight,
      store: this.store.stats()
    };
    return stats;
  }

  /**
   * 服务装配（上游 build_service 的宿主侧）：读 judge/store 配置段，建 BanditStore
   * （store 表缺省而 judge 启用 → 默认参数）与 JudgeClient。两者皆未激活 → null
   * （无服务，行为同旧）。banditEnabled 由决策参数在场决定（loadParams bandit 段）。
   */
  static buildService(filesDir: string, xparams: XRouterParams | null): RouterService | null {
    const config = XRouter.loadServiceConfig(filesDir);
    if (config === null) return null;
    const storeParams = config.storeParams !== null ? config.storeParams : defaultStoreParams();
    let judge: JudgeTransport | null = null;
    if (config.judge !== null) {
      judge = new JudgeClient(config.judge.apiKey, config.judge.baseUrl, config.judge.model,
        config.judge.timeoutSeconds, config.judge.maxTokens, config.judge.disableThinking);
    }
    const service: RouterService = {
      store: new BanditStore(storeParams),
      judge: judge,
      banditEnabled: xparams !== null && xparams.bandit !== null && xparams.bandit !== undefined,
      previewChars: xparams !== null ? xparams.previewChars : DEFAULT_PREVIEW_CHARS,
      queueCap: SETTLE_QUEUE_CAP
    };
    return service;
  }

  /** 仅 xrouter 策略重试（上游语义）；config/cloud/local 维持单次直连。 */
  private canRetry(attempt: number): boolean {
    return attempt < MAX_ATTEMPTS && this.router.policy() === 'xrouter';
  }

  private modelIdOf(decision: RouteDecision): string {
    if (decision.model !== undefined && decision.model.length > 0) return decision.model;
    if (decision.side === 'cloud' && this.cloud !== null) return this.cloud.modelName;
    return 'local';
  }

  cancel(requestId?: string): void {
    this.local.cancel(requestId);
    if (this.cloud !== null) this.cloud.cancel(requestId);
  }

  close(): void {
    this.closed = true;
    this.local.close();
    if (this.cloud !== null) this.cloud.close();
  }

  private snapshot(): BackendStatus {
    const view = this.store.snapshot(ROUTING_KEY);
    return {
      localReady: this.local.readinessError() === '',
      localBusy: this.local.isBusy(),
      cloudReady: this.cloud !== null && this.cloud.readinessError() === '',
      cloudBusy: this.cloud !== null && this.cloud.isBusy(),
      exclusions: view.exclusions
    };
  }

  private contextOf(messages: ChatMessage[], options: ChatStartOptions): RouteContext {
    let promptChars = 0;
    for (let index = messages.length - 1; index >= 0; index--) {
      if (messages[index].role === 'user') {
        promptChars = messages[index].content.length;
        break;
      }
    }
    return {
      messages: messages,
      promptChars: promptChars,
      image: options.image ?? '',
      maxTokens: options.maxTokens ?? 0
    };
  }
}
