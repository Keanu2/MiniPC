import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatBackend, ChatUpdate, LocalChat } from '../llm/LocalChat';
import { CloudChat } from '../llm/CloudChat';
import { BackendRouter } from '../llm/BackendRouter';
import { RouterChat } from '../llm/RouterChat';
import { XRouter } from '../llm/XRouter';
import { InferCardHooks, InferenceHost } from '../llm/InferenceHost';
import { InferenceRelay, RelayEvents } from '../llm/InferenceRelay';
import { PoolNode } from '../cluster/DevicePool';
import { DeviceSpeed } from '../cluster/DeviceSpeed';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { WireMessage, ChatMessage, ClusterInfo, DeviceInfoEntry, InferenceMetrics } from '../protocol/ChatProtocol';
import { IS_SERVER } from '../nearby/NearbyConfig';
import { ComputeRouter, DispatchEntry, ScheduleNode, originKeyOf, pickNode, pickRoute } from '../cluster/ComputeRouter';
import { classifyFromMessages } from '../cluster/TaskRules';
import { LocalLlmTransport } from '../llm/LlmTransport';
import { VlLlmTransport } from '../llm/VlLlmTransport';
import { QwenVlManager } from '../llm/QwenVlManager';
import { isVlLayout, modelSelection, readyModelDirs, saveModelSelection } from '../llm/ModelRegistry';
import { outputSettings, saveOutputSettings } from '../llm/OutputSettings';
import {
  UsageLedger, applyUsageSettings, emptyUsage, loadUsage, recordFinishedTask, recordLocalCall,
  savedTokens, saveUsage, usageSettingsJson
} from '../llm/UsageLedger';
import { pickJpegDataUrl, jpegBase64Payload } from '../media/ImageAttach';
import {
  DEVICE_INFO_POLL_MS, applyDeviceInfo, buildSelfEntry, deployedModelName,
  toDeviceInfoReply
} from '../cluster/DeviceInfo';
import { chatLabel, computeLabel, hidePhoneName, needsLabel, publicLabel, workerTail } from '../cluster/DeviceLabels';
import { ChatBridge } from '../ui/ChatBridge';
import { ActiveJob, DeviceView, JobView, ModelChoiceView, ModelSettingsView, PageEvent } from '../ui/DashboardTypes';
import { TaskBoard, TaskGroupView } from '../ui/TaskBoard';
import { TaskDisplayRelay } from '../ui/TaskDisplayRelay';
import { inferenceSummary } from '../ui/InferencePresentation';
import { InferenceTaskObserver } from '../ui/InferenceTaskObserver';
import { collaborationScreen } from '../ui/CollaborationScreen';

interface FlowNotice {
  key: string; kind: string; phase: string; origin: string; source: string;
  originId?: string; executorId?: string; elapsed: number; updatedAt: number; revision: number; signature: string;
}

interface RosterDelivery {
  signature: string;
  pending: boolean;
  lastFullAt: number;
}

interface TaskRequestLink { imageTask?: boolean; taskId?: string; subtaskId?: string; origin: string; input: string; }

function sameName(left: string, right: string): boolean {
  return left.length > 0 && right.length > 0 &&
    (left === right || left.indexOf(right) >= 0 || right.indexOf(left) >= 0);
}

function deviceGroup(role: string | undefined): number {
  return role === 'self' || role === 'compute' ? 0 : 1;
}

function labelSlot(name: string, compute: boolean): number {
  const prefix = compute ? '算力设备' : '聊天设备';
  if (name.indexOf(prefix) !== 0) return 1000000;
  const suffix = name.substring(prefix.length);
  if (suffix.length === 0) return 1000000;
  const slot = Number.parseInt(suffix);
  return Number.isFinite(slot) && slot > 0 ? slot : 1000000;
}

/** Compute cards first, then chat cards; each group follows its public slot. */
function compareDevices(left: DeviceView, right: DeviceView): number {
  const leftGroup = deviceGroup(left.role);
  const rightGroup = deviceGroup(right.role);
  if (leftGroup !== rightGroup) return leftGroup - rightGroup;
  const leftSlot = labelSlot(left.name, leftGroup === 0);
  const rightSlot = labelSlot(right.name, rightGroup === 0);
  if (leftSlot !== rightSlot) return leftSlot - rightSlot;
  if (left.name < right.name) return -1;
  if (left.name > right.name) return 1;
  return left.id < right.id ? -1 : (left.id > right.id ? 1 : 0);
}

const MAX_FINISHED_JOBS = 40;

@Entry
@Component
struct Index {
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ChatBridge = new ChatBridge((text: string): string => this.send(text),
    () => this.stop(), () => { this.connectNearby(); }, () => {
      if (!IS_SERVER) {
        this.autoConnect = true;
        this.ensureCollaborationReady(true);
      }
    }, () => { this.pickImage(); }, () => { this.clearFinishedJobs(); }, () => { this.pendingImage = ''; },
    (model: string): string => this.selectModel(model),
    (): string => IS_SERVER && this.filesDir.length > 0 ? JSON.stringify(this.modelSettings()) : 'null',
    (mode: string): string => this.setOutputMode(mode),
    (): string => usageSettingsJson(this.usage),
    (payload: string): string => this.saveUsageSettings(payload));
  private channel = nearbyChannel;
  private connecting: boolean = false;
  private preparation: Promise<void> | null = null;
  private serviceReady: boolean = false;
  private preparedOperation: number = -1;
  private selectedDeviceId: string = '';
  private autoConnect: boolean = true;
  private connectManual: boolean = false;
  private model: ChatBackend | null = null;
  /** 当前文本推理走哪一侧：'云侧' 或 '端侧'；aboutToAppear 选定后不变，改配置需重启。 */
  private backendSide: string = '';
  /** 云侧实际服役的模型名（端侧为空，沿用本地模型扫描结果）。 */
  private backendModel: string = '';
  /** 路由分派器引用：读最近一次决策的档位用于通道卡片展示。 */
  private modelRouter: RouterChat | null = null;
  private inference: InferenceHost | null = null;
  private relay: InferenceRelay | null = null;
  private transport: LocalLlmTransport | null = null;
  /** 本机多模态引擎通道（带图请求专用；VL 权重未部署时为空仍可创建，门控由内部就绪检查负责） */
  private vlTransport: VlLlmTransport | null = null;
  private pageReady: boolean = false;
  private connectionError: string = '';
  private activeId: string = '';
  /** Wire request id backing the WebView's live task card; '' when none is streaming. */
  private webActiveId: string = '';
  private answer: string = '';
  private question: string = '';
  private jobs: ActiveJob[] = [];
  private finishedJobs: ActiveJob[] = [];
  private queuedJobs: Map<string, JobView> = new Map();
  private flowRevision: number = 0;
  private flowNotices: Map<string, FlowNotice> = new Map();
  private flowDeliveries: Map<number, Map<string, number>> = new Map();
  private flowMirrors: Map<string, JobView> = new Map();
  private flowVersions: Map<string, number> = new Map();
  private taskBoard: TaskBoard = new TaskBoard();
  private taskObserver: InferenceTaskObserver = new InferenceTaskObserver();
  private taskDisplay: TaskDisplayRelay = new TaskDisplayRelay((message: WireMessage, epoch: number): Promise<boolean> =>
    this.channel.send(message, epoch));
  private taskLinks: Map<string, TaskRequestLink> = new Map();
  private history: ChatMessage[] = [];
  private pendingB: ChatMessage[] | null = null;
  private pendingBId: string = '';
  private overlapArmed: boolean = false;
  private filesDir: string = '';
  private usage: UsageLedger = emptyUsage();
  private router: ComputeRouter = new ComputeRouter();
  private deviceSpeed: DeviceSpeed = new DeviceSpeed();
  /** auto | split | pin1 | pin2. Only the hub's scheduleRequest consults this. */
  private routeMode: string = 'auto';
  /** Chat epoch -> 1 (this hub) or 2 (the other compute) while mode is split. */
  private splitTarget: Map<number, number> = new Map();
  private peerStats: Map<number, DeviceInfoEntry> = new Map();
  private infoTimer: number = -1;
  private rosterDeliveries: Map<number, RosterDelivery> = new Map();
  private lastPublishedRunning: number = -1;
  private meshTimer: number = -1;
  private pendingImage: string = '';
  private remoteSeen: Map<number, DeviceInfoEntry[]> = new Map();

  aboutToAppear(): void {
    if (IS_SERVER) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.filesDir = context.getApplicationContext().filesDir;
      this.usage = loadUsage(this.filesDir);
      const cloud = CloudChat.create(this.filesDir);
      const local = new LocalChat(this.filesDir);
      const policy = BackendRouter.loadPolicy(this.filesDir);
      const xparams = policy === 'xrouter' ? XRouter.loadParams(this.filesDir) : null;
      const route = new BackendRouter(policy, xparams !== null ? new XRouter(xparams) : null);
      // 质量闭环服务（judge/settle/store）：xrouter 决策实际启用时才装配。
      const service = policy === 'xrouter' && xparams !== null
        ? RouterChat.buildService(this.filesDir, xparams) : null;
      this.modelRouter = new RouterChat(local, cloud, route, service);
      this.model = this.modelRouter;
      hilog.info(0, 'NearbyChat', 'llm backend=%{public}s route=%{public}s',
        cloud !== null ? 'cloud' : 'local', policy);
      if (service !== null) {
        hilog.info(0, 'NearbyChat', 'x-router service judge=%{public}s store=%{public}s bandit=%{public}s',
          service.judge !== null ? 'on' : 'off', 'on', service.banditEnabled ? 'on' : 'off');
      }
      // 通道卡片：config 策略沿用配置语义（与引入路由前一致）；其余策略按策略倾向显示。
      if (policy === 'cloud') {
        this.backendSide = '云侧';
        this.backendModel = cloud !== null ? cloud.modelName : '';
      } else if (policy === 'local') {
        this.backendSide = '端侧';
        this.backendModel = '';
      } else if (policy === 'auto') {
        this.backendSide = '自动';
        this.backendModel = '';
      } else if (policy === 'xrouter') {
        this.backendSide = '分档';
        this.backendModel = cloud !== null ? cloud.modelName : '';
      } else {
        this.backendSide = cloud !== null ? '云侧' : '端侧';
        this.backendModel = cloud !== null ? cloud.modelName : '';
      }
      const card = new InferCardHooks();
      card.phase = (id: string, epoch: number, phase: string): void => this.updateJobPhase(id, epoch, phase);
      card.metrics = (requestId: string, epoch: number, metrics: InferenceMetrics): void => {
        this.updateJobMetrics(requestId, epoch, metrics);
      };
      card.begin = (requestId: string, epoch: number, prompt: string, label: string, image: string): void => {
        this.showInferTask(requestId, epoch, prompt, label, image);
      };
      card.delta = (requestId: string, epoch: number, answer: string, outputAt?: number): void => {
        this.updateInferTask(requestId, epoch, answer, outputAt);
      };
      card.end = (requestId: string, epoch: number, answer: string, failed: boolean): void => {
        this.finishInferTask(requestId, epoch, answer, failed);
      };
      this.inference = new InferenceHost(this.model, (message: WireMessage, epoch: number): Promise<boolean> => {
        return this.channel.send(message, epoch);
      }, card);
      const host = this.inference;
      host.setDeviceProvider((): string => this.selfComputeLabel());
      const events = new RelayEvents();
      events.phase = (id: string, epoch: number, phase: string): void => this.updateJobPhase(id, epoch, phase);
      events.metrics = (requestId: string, epoch: number, metrics: InferenceMetrics): void => {
        this.updateJobMetrics(requestId, epoch, metrics);
      };
      events.begin = (requestId: string, chatEpoch: number, workerEpoch: number, messages: ChatMessage[], label: string,
        image: string): void => {
        this.showRelayTask(requestId, chatEpoch, workerEpoch, messages, label, image);
      };
      events.delta = (requestId: string, chatEpoch: number, answer: string): void => {
        this.updateRelayTask(requestId, chatEpoch, answer);
      };
      events.end = (requestId: string, chatEpoch: number, answer: string, failed: boolean): void => {
        this.completeJob(requestId, chatEpoch, answer.length > 0 ? answer : (failed ? '推理失败' : ''), failed);
      };
      events.forward = (requestId: string, chatEpoch: number, workerEpoch: number, request: WireMessage): void => {
        this.forwardTaskDisplay(requestId, chatEpoch, workerEpoch, request);
      };
      this.relay = new InferenceRelay(this.router, (): PoolNode[] => this.poolNodes(), (): number[] => this.chatEpochs(),
        host, (message: WireMessage, epoch: number): Promise<boolean> => this.channel.send(message, epoch), events);
      this.taskDisplay.log = (text: string): void => { hilog.warn(0, 'NearbyChat', '%{public}s', text); };
      this.relay.setSpeed((epoch: number): number => this.deviceSpeed.cost(epoch));
      this.relay.setAffinity((): boolean => {
        try { return fileIo.accessSync(this.filesDir + '/session-reuse.on'); } catch (_) { return false; }
      });
      host.setClusterProvider((): ClusterInfo | null => this.isComputeHub() ? this.relay?.load() ?? null : null);
      this.transport = new LocalLlmTransport(this.model);
        // 多模态引擎通道（可缺省）：VL 权重是否部署由 ModelRegistry 扫描决定，这里只建通道；
        // 构造或初始化失败时置空，带图请求回落为纯文本，不影响应用其余功能。
        try {
          this.vlTransport = new VlLlmTransport(context.cacheDir, this.filesDir);
          QwenVlManager.getInstance().init(this.filesDir);
          hilog.info(0, 'NearbyChat', 'VL ready enabled=%{public}s model=%{public}s',
            String(QwenVlManager.getInstance().isModelEnabled()),
            QwenVlManager.getInstance().getDeployedModelName() || 'NA');
        } catch (e) {
          this.vlTransport = null;
          hilog.warn(0, 'NearbyChat', 'VL transport unavailable: %{public}s',
            e instanceof Error ? e.message : 'unknown');
        }
        // 聊天端（远端）的带图请求走同一条 VL 通道；未部署时传 null，InferenceHost 会 fail closed。
        host.setVisionTransport(this.vlTransport);
    }
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    collaborationScreen.setWanted(false);
    this.stopInfoPoll();
    this.stopMeshRetry();
    this.vlTransport?.cancel();
    this.model?.close();
    this.channel.disconnect();
    this.channel.unsubscribe();
  }

  onPageShow(): void {
    if (this.pageReady && this.autoConnect) this.ensureCollaborationReady(this.connectManual);
  }

  private connectNearby(): void {
    if (IS_SERVER && (this.serviceReady || this.channel.isListening() || this.connecting || this.preparation !== null)) {
      this.stopNearField();
      return;
    }
    if (!IS_SERVER) {
      if (this.preparation !== null) return;
      if (this.channel.isConnected()) {
        this.autoConnect = false;
        this.channel.disconnect();
        this.showConnection();
        return;
      }
    }
    this.autoConnect = true;
    this.ensureCollaborationReady(true);
  }

  private stopNearField(): void {
    this.autoConnect = false;
    this.connecting = false;
    this.serviceReady = false;
    this.preparation = null;
    this.stopInfoPoll();
    this.stopMeshRetry();
    this.channel.disconnect();
    this.showConnection();
  }

  private ensureCollaborationReady(manual: boolean = false): Promise<void> {
    if (!IS_SERVER && this.activeId) return Promise.resolve();
    if (this.preparation !== null) return this.preparation;
    if (IS_SERVER && this.preparedOperation === this.channel.operation() && this.serviceReady) {
      return Promise.resolve();
    }
    if (!IS_SERVER && this.serviceReady && this.channel.isConnected() && this.preparedOperation === this.channel.operation()) {
      return Promise.resolve();
    }
    this.connectManual = manual;
    this.connecting = true;
    const operation = this.channel.operation();
    this.connectionError = '';
    this.showConnection();
    this.preparation = this.prepareCollaboration(operation);
    return this.preparation;
  }

  private async prepareCollaboration(operation: number): Promise<void> {
    hilog.info(0, 'NearbyChat', 'prepare begin operation=%{public}d manual=%{public}s',
      operation, String(this.connectManual));
    try {
      if (IS_SERVER) {
        await this.channel.prepare();
        if (operation !== this.channel.operation() || !this.pageReady) return;
        this.serviceReady = true;
        this.preparedOperation = operation;
        this.channel.connectOtherComputes(operation).catch(() => {});
        this.startMeshRetry();
        this.startInfoPoll();
        return;
      }
      if (!this.channel.isConnected() && !this.channel.isConnecting()) {
        const devices = await this.channel.computeDevices();
        if (operation !== this.channel.operation() || !this.pageReady) return;
        if (devices.length === 0) {
          if (!this.channel.hasComputeHits()) {
            throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
          }
          await this.channel.connectToAdvertisers(operation);
        } else {
          let index = 0;
          if (this.selectedDeviceId) {
            const found = devices.findIndex(device => device.deviceId === this.selectedDeviceId);
            if (found >= 0) index = found;
          }
          if (this.connectManual && !this.selectedDeviceId && devices.length > 1) {
            const buttons: [promptAction.Button, promptAction.Button?, promptAction.Button?,
              promptAction.Button?, promptAction.Button?, promptAction.Button?] = [
              { text: '算力 · ' + (devices[0].deviceName || '未命名设备'), color: '#9b5f4c' }
            ];
            for (let i = 1; i < Math.min(devices.length, 6); i++) {
              buttons.push({ text: '算力 · ' + (devices[i].deviceName || '未命名设备'), color: '#9b5f4c' });
            }
            const selection = await this.getUIContext().getPromptAction().showActionMenu({
              title: '选择算力设备', buttons: buttons
            });
            index = selection.index;
          }
          if (operation !== this.channel.operation() || !this.pageReady) return;
          if (index < 0 || index >= devices.length) return;
          this.selectedDeviceId = devices[index].deviceId;
          await this.channel.connect(devices[index].networkId!, operation);
        }
      }
      if (!await this.channel.waitUntilConnected()) throw new Error(this.channel.getStatus());
      if (operation !== this.channel.operation() || !this.pageReady) return;
      const error = await this.channel.checkService();
      if (operation !== this.channel.operation() || !this.pageReady) return;
      if (error) throw new Error(error);
      this.serviceReady = true;
      this.preparedOperation = operation;
      hilog.info(0, 'NearbyChat', 'collaboration prepared operation=%{public}d', operation);
    } catch (error) {
      if (operation === this.channel.operation()) {
        this.serviceReady = false;
        this.connectionError = error instanceof Error ? error.message : '协同未准备完成，请点击输入框重试。';
      }
    } finally {
      this.connecting = false;
      this.preparation = null;
      this.showConnection();
    }
  }

  private selfComputeLabel(): string {
    const label = this.channel.selfLabel();
    return label.length > 0 ? label : '算力设备';
  }

  private emit(event: PageEvent): void {
    if (!this.pageReady) return;
    this.controller.runJavaScript('window.onNativeEvent(' + JSON.stringify(event) + ')').catch(() => this.stop());
  }

  /**
   * Board identity of a job. A chat peer and this device can send the same wire
   * request id; the origin session keeps their cards apart. It is also the id the
   * local model engine keys on, so callbacks can be routed back to the right card.
   */
  private static jobKey(epoch: number, id: string): string {
    return originKeyOf(epoch, id);
  }

  private createJob(id: string, messages: ChatMessage[], peer: boolean, epoch: number, workerEpoch: number = 0,
    image: string = '', originLabel: string = '', routeMode: string = '', taskTier: number = 0): ActiveJob {
    const peers = this.channel.peerInfos();
    const link = this.taskLinks.get(Index.jobKey(epoch, id));
    this.taskLinks.delete(Index.jobKey(epoch, id));
    return {
      kind: link?.imageTask || image.length > 0 ? 'image' : 'text',
      phase: workerEpoch === 0 ? 'running' : 'sending', phaseStartedAt: Date.now(),
      taskId: link?.taskId, subtaskId: link?.subtaskId,
      input: link?.input,
      id: id, key: Index.jobKey(epoch, id), epoch: epoch, peer: peer, answer: '', question: messages[messages.length - 1].content,
      startedAt: Date.now(), firstAt: 0, endedAt: 0, error: false,
      source: computeLabel(workerEpoch, peers, this.selfComputeLabel()),
      origin: link !== undefined ? link.origin : (originLabel.length > 0 ? this.forwardedOrigin(originLabel) : (peer ? chatLabel(epoch, peers) : '本机')),
      workerEpoch: workerEpoch,
      image: this.jobImage(image),
      routeMode: routeMode,
      taskTier: taskTier
    };
  }

  /** A forwarded task may expose only the public chat/compute label, never a phone name. */
  private forwardedOrigin(origin: string): string {
    const label = origin.trim();
    if (label === '本机' || label.indexOf('聊天设备') === 0 || label.indexOf('算力设备') === 0) return label;
    return '聊天设备';
  }

  private toJobView(job: ActiveJob, now: number): JobView {
    const ended = job.endedAt > 0;
    const elapsed = (ended ? job.endedAt : now) - job.startedAt;
    return {
      groupKey: job.taskId !== undefined ? Index.jobKey(job.epoch, job.taskId) : undefined, subtaskId: job.subtaskId,
      input: job.input, metrics: job.metrics,
      kind: job.kind, phase: ended ? (job.error ? 'failed' : 'done') : job.phase,
      phaseStartedAt: job.phaseStartedAt || job.startedAt,
      originId: this.channel.peerInfos().find((peer) => peer.epoch === job.epoch && peer.role === 'chat')?.deviceUid,
      executorId: job.workerEpoch === 0 ? this.channel.localUid() :
        this.channel.peerInfos().find((peer) => peer.epoch === job.workerEpoch)?.deviceUid,
      id: job.id, key: job.key, source: job.source, origin: job.origin, local: !job.peer,
      image: job.image, question: job.question, answer: job.answer,
      chars: job.answer.length, startedAt: job.startedAt, firstAt: job.firstAt,
      endedAt: job.endedAt, running: !ended, error: job.error,
      elapsedMs: elapsed < 0 ? 0 : elapsed
    };
  }

  private taskViews(): TaskGroupView[] {
    const groups = this.taskBoard.views();
    for (const group of this.taskObserver.views()) if (!groups.some((item) => item.key === group.key)) groups.push(group);
    return groups;
  }

  private publishWorkerTasks(groups: TaskGroupView[]): void {
    if (!this.isComputeHub()) return;
    this.taskDisplay.publish(groups.filter((group: TaskGroupView): boolean => !this.taskObserver.provisional(group.key)),
      this.channel.peerInfos().filter((peer) => peer.ready && peer.role === 'compute')
      .map((peer) => peer.epoch), this.jobs.concat(this.finishedJobs).filter((job) => job.taskId !== undefined)
      .map((job) => Index.jobKey(job.epoch, job.taskId || '')));
  }

  private forwardTaskDisplay(requestId: string, chatEpoch: number, workerEpoch: number, request: WireMessage): void {
    const job = this.findJob(requestId, chatEpoch);
    if (job?.taskId === undefined || job.subtaskId === undefined) return;
    this.taskDisplay.bind(Index.jobKey(chatEpoch, job.taskId), job.subtaskId, request, workerEpoch);
    this.publishWorkerTasks(this.taskViews());
  }

  private modelSettingsLocked(): boolean {
    return this.jobs.some((job: ActiveJob): boolean => job.workerEpoch === 0) ||
      (this.inference?.isActive() ?? false) || (this.model?.hasPendingNativeJobs() ?? false) ||
      QwenVlManager.getInstance().isBusy();
  }

  private modelSettings(): ModelSettingsView {
    const selection = modelSelection(this.filesDir);
    const options = readyModelDirs(this.filesDir).map((dir: string): ModelChoiceView => {
      return { name: dir, vision: isVlLayout(this.filesDir + '/models/' + dir) };
    });
    return { selected: selection.model, options: options, streaming: outputSettings(this.filesDir).streaming,
      locked: this.modelSettingsLocked() };
  }

  private selectModel(model: string): string {
    if (!IS_SERVER || this.filesDir.length === 0) return '模型服务尚未初始化。';
    if (this.modelSettingsLocked()) return '本机正在推理或释放模型，请结束后再切换。';
    try {
      this.model?.resetIdleSessions();
      QwenVlManager.getInstance().unloadIfIdle();
    } catch (_) { return '旧模型尚未释放，请稍后再试。'; }
    const error = saveModelSelection(this.filesDir, { model: model });
    if (error.length > 0) return error;
    QwenVlManager.getInstance().init(this.filesDir);
    // Publish capabilities immediately so peers stop routing disabled input types here.
    for (const peer of this.channel.peerInfos()) {
      if (peer.ready) this.replyDeviceInfo('models-' + String(Date.now()), peer.epoch);
    }
    this.rosterDeliveries.clear();
    this.emitDashboard();
    return '';
  }

  private setOutputMode(mode: string): string {
    if (!IS_SERVER || this.filesDir.length === 0) return '模型服务尚未初始化。';
    if (mode !== 'stream' && mode !== 'complete') return '请选择有效的输出方式。';
    // Every request snapshots this preference on start; active requests retain their mode.
    const error = saveOutputSettings(this.filesDir, { streaming: mode === 'stream' });
    if (error.length === 0) this.emitDashboard();
    return error;
  }

  private saveUsageSettings(payload: string): string {
    if (!IS_SERVER || this.filesDir.length === 0) return '统计尚未初始化。';
    const error = applyUsageSettings(this.usage, payload);
    if (error.length > 0) return error;
    saveUsage(this.filesDir, this.usage);
    this.emitDashboard();
    return '';
  }

  private emitDashboard(): void {
    this.channel.setActiveJobs(this.jobs.length);
    collaborationScreen.setWanted(IS_SERVER && this.pageReady && (this.channel.isListening() || this.jobs.length > 0));
    const groups = this.taskViews();
    this.noteFinishedTasks(groups);
    if (IS_SERVER) this.publishWorkerTasks(groups);
    if (!IS_SERVER || !this.pageReady) return;
    const runningNow = this.jobs.filter((job: ActiveJob) => job.workerEpoch === 0).length;
    // Publish small load changes during inference too; full telemetry can wait.
    if (this.serviceReady && runningNow !== this.lastPublishedRunning) {
      const previousRunning = this.lastPublishedRunning;
      this.lastPublishedRunning = runningNow;
      const status = this.inferenceLoadStatus(runningNow);
      for (const peer of this.channel.peerInfos()) {
        if (peer.ready && peer.role === 'compute') this.channel.send(status, peer.epoch);
      }
      if (runningNow === 0 && previousRunning > 0) this.pollDeviceInfo();
    }
    const now = Date.now();
    const self = this.selfEntry();
    const peers = this.channel.peerInfos();
    const devices: DeviceView[] = [];
    const seen: string[] = [];
    const selfLabel = this.selfComputeLabel();
    const selfUid = this.channel.localUid() || self.id || 'self';
    devices.push({
      epoch: 0, name: selfLabel, id: selfUid, ready: true,
      // Work this device is actually running: its own questions plus requests a
      // chat peer routed here. `peer` alone would count "推理 0" mid-inference.
      jobs: this.jobs.filter((item: ActiveJob) => item.workerEpoch === 0).length,
      role: 'self', model: self.model, memUsage: self.memUsage,
      thermalLevel: self.thermalLevel, batteryTemp: self.batteryTemp, cpuUsage: self.cpuUsage,
      modelRequests: self.modelRequests, capabilities: self.capabilities,
      backend: this.backendLabel(), modelTier: self.modelTier
    });
    seen.push('id:' + selfUid);
    // Deduplicate on connection identity, not on the public label: two distinct
    // devices that happen to both be labelled 算力设备1 are still two devices.
    for (const peer of peers) {
      const id = peer.deviceUid || peer.peerId;
      const mark = id.length > 0 ? 'id:' + id : 'epoch:' + String(peer.epoch);
      if (seen.indexOf(mark) >= 0) continue;
      seen.push(mark);
      let count = 0;
      for (const job of this.jobs) {
        // `epoch` is the request's upstream/origin link. Only workerEpoch says
        // where inference runs; counting both made the forwarding compute look busy.
        if (peer.role === 'compute' && job.workerEpoch === peer.epoch) count++;
      }
      const stats = this.peerStats.get(peer.epoch);
      if (peer.role === 'compute' && stats?.modelRequests !== undefined && stats.modelRequests > count) {
        count = stats.modelRequests;
      }
      devices.push({
        epoch: peer.epoch, name: hidePhoneName(peer.name, peer.role || 'chat'), id: id, ready: peer.ready, jobs: count,
        role: peer.role, model: stats?.model, memUsage: stats?.memUsage,
        thermalLevel: stats?.thermalLevel, batteryTemp: stats?.batteryTemp, cpuUsage: stats?.cpuUsage,
        modelRequests: stats?.modelRequests, capabilities: stats?.capabilities, modelTier: stats?.modelTier
      });
    }
    for (const extra of this.remoteEntries()) {
      const raw = extra.name || '';
      let role = extra.role || 'chat';
      if (role === 'self') role = 'compute';
      // Match on the connection id when the reporter gave us one. Comparing names
      // is what turned one physical box into two cards labelled 算力设备1.
      const id = extra.deviceUid || extra.id || '';
      let known = id.length > 0 && id === selfUid;
      for (const peer of peers) {
        if (id.length > 0 && id === (peer.deviceUid || peer.peerId)) {
          known = true;
          break;
        }
      }
      if (known) continue;
      if (role === 'compute' && id.length === 0 &&
        sameName(this.channel.localName(), raw)) continue;
      const name = publicLabel(role, extra.slot === undefined ? 0 : extra.slot);
      const mark = id.length > 0 ? 'id:' + id : role + ':' + name;
      if (seen.indexOf(mark) >= 0) continue;
      seen.push(mark);
      devices.push({
        epoch: -1, name: name, id: id || name, ready: extra.ready !== false,
        jobs: role === 'compute' ? Math.max(0, extra.modelRequests ?? 0) : 0,
        role: role, model: extra.model, memUsage: extra.memUsage,
        thermalLevel: extra.thermalLevel, batteryTemp: extra.batteryTemp, cpuUsage: extra.cpuUsage,
        modelRequests: extra.modelRequests, capabilities: extra.capabilities, modelTier: extra.modelTier
      });
    }
    const views: JobView[] = [];
    const remoteCalls: JobView[] = [];
    // The task rail is local evidence, not a cluster-wide coordinator ledger.
    // A job with workerEpoch != 0 is only passing through this device on its way
    // to another compute. The executing compute creates its own workerEpoch=0 job,
    // so filtering here leaves exactly the tasks this box actually inferred.
    for (const job of this.jobs) {
      if (job.workerEpoch === 0) views.push(this.toJobView(job, now));
      else remoteCalls.push(this.toJobView(job, now));
    }
    for (const job of this.finishedJobs) {
      if (job.workerEpoch === 0) views.push(this.toJobView(job, now));
      else remoteCalls.push(this.toJobView(job, now));
    }
    const localRunning = this.jobs.filter((job: ActiveJob) => job.workerEpoch === 0).length;
    devices.sort(compareDevices);
    this.publishFlow(views.concat(remoteCalls).concat(Array.from(this.queuedJobs.values())));
    this.emit({
      kind: 'dashboard',
      text: this.connectionError || this.channel.getStatus(),
      available: true,
      connectLabel: this.serviceReady ? '停用近场' : '启用近场',
      connecting: this.connecting || this.channel.isConnecting(),
      running: localRunning,
      selfLabel: this.selfComputeLabel(),
      devices: devices,
      jobs: views,
      remoteCalls: remoteCalls,
      flowCalls: this.isComputeHub() ? [] : Array.from(this.flowMirrors.values()).filter((job: JobView): boolean => now - job.startedAt < 600000),
      queuedCalls: Array.from(this.queuedJobs.values()).filter((job: JobView): boolean => {
        if (now - job.startedAt <= 130000) return true;
        this.queuedJobs.delete(job.key); return false;
      }),
      groups: groups,
      modelSettings: this.modelSettings(),
      usage: { tasks: this.usage.completedTasks, tokens: savedTokens(this.usage), microYuan: this.usage.savedMicroYuan }
    });
  }

  private showConnection(): void {
    const connected = this.channel?.isConnected() === true;
    const ready = connected && this.serviceReady && this.preparedOperation === this.channel.operation();
    this.emit({ kind: 'connection', text: this.connectionError || (this.connecting ? (this.channel.getStatus() || '正在准备协同…') :
      (!IS_SERVER && ready ? '协同已就绪' : this.channel.getStatus())),
      available: IS_SERVER || ready, pendingText: IS_SERVER ? '正在推理中' : '正在等待推理端回复',
      connectLabel: this.serviceReady ? '停用近场' : (IS_SERVER ? '启用近场' : '连接'),
      connecting: this.connecting || this.channel.isConnecting(),
      selfLabel: this.selfComputeLabel() });
    if (IS_SERVER) this.emitDashboard();
  }

  private connectionChanged(connected: boolean, epoch: number): void {
    hilog.info(0, 'NearbyChat', 'connection=%{public}s epoch=%{public}d peers=%{public}d server=%{public}s',
      String(connected), epoch, this.channel.connectedCount(), String(IS_SERVER));
    if (this.channel.isConnected()) this.connectionError = '';
    if (!IS_SERVER && !connected) this.serviceReady = false;
    if (IS_SERVER) {
      const dropped = !this.channel.hasEpoch(epoch);
      // InferenceHost owns its per-request native identifiers and cancellation.
      if (dropped) {
        this.taskBoard.disconnect(epoch);
        for (const job of this.queuedJobs.values()) if (job.key.indexOf(String(epoch) + ':') === 0) this.queuedJobs.delete(job.key);
        this.flowDeliveries.delete(epoch);
        if (!this.isComputeHub()) { this.flowMirrors.clear(); this.flowVersions.clear(); }
        this.taskObserver.disconnect(epoch);
        this.inference?.peerDropped(epoch);
        // Relay first: it owns the infer.* hand-offs that cancelDroppedPeers must not treat as chat requests.
        this.relay?.chatDropped(epoch);
        this.relay?.workerDropped(epoch);
      }
      this.cancelDroppedPeers();
      this.relay?.publishLoad();
      if (dropped || connected) this.pollDeviceInfo();
      // A chat link can only be dialled by the chat phone: the peer carries no
      // discoverable address, and connectOtherComputes() only ever dials advertised
      // compute nodes. There is nothing for this side to re-dial, so say so instead
      // of leaving a silent gap the operator has to guess at.
      if (dropped && this.channel.connectedCount() === 0 && !this.connecting && this.serviceReady) {
        this.connectionError = '聊天手机已断开，等待它自动重连…';
      }
    }
    else if (!connected && this.activeId) {
      this.finish(this.answer + (this.answer ? '\n\n' : '') + '连接已中断，请连接后重新发送。', true);
    }
    this.showConnection();
  }

  private cancelDroppedPeers(): void {
    for (const job of this.jobs.slice()) {
      if (job.peer && !this.channel.hasEpoch(job.epoch) && job.workerEpoch === 0) {
        this.model?.cancel(job.key);
        this.vlTransport?.cancel();
      }
    }
    const peers = this.channel.peerInfos();
    const live: number[] = [];
    for (const peer of peers) live.push(peer.epoch);
    const stale: number[] = [];
    this.peerStats.forEach((_, epoch) => {
      if (live.indexOf(epoch) < 0) stale.push(epoch);
    });
    for (const epoch of stale) {
      this.peerStats.delete(epoch);
      const dropped = this.router.dropWorker(epoch);
      for (const entry of dropped) {
        if (entry.infer) continue;
        this.channel.send({ type: 'error', requestId: entry.originRequestId,
          error: '执行设备 ' + entry.workerName + ' 连接断开' }, entry.originEpoch);
        this.completeJob(entry.originRequestId, entry.originEpoch, '执行设备连接断开', true);
      }
    }
    const staleSnapshots: number[] = [];
    this.rosterDeliveries.forEach((_, epoch) => {
      if (live.indexOf(epoch) < 0) this.rosterDeliveries.delete(epoch);
    });
    this.remoteSeen.forEach((_, epoch) => {
      if (live.indexOf(epoch) < 0) staleSnapshots.push(epoch);
    });
    for (const epoch of staleSnapshots) this.remoteSeen.delete(epoch);
    this.refreshRemoteChats();
  }

  private findJob(id: string, epoch: number = 0): ActiveJob | undefined {
    return this.findJobByKey(Index.jobKey(epoch, id));
  }

  private findJobByKey(key: string): ActiveJob | undefined {
    for (const item of this.jobs) {
      if (item.key === key) return item;
    }
    return undefined;
  }

  private localBusy(): boolean {
    return this.jobs.some((item: ActiveJob) => !item.peer);
  }

  /** 聊天轨道同一时刻只服务一张卡片：本机任务 + Hub 自己转发出去的请求。 */
  private railBusy(): boolean {
    return this.jobs.some((item: ActiveJob) => !item.peer || item.epoch === 0);
  }

  private selfMeetsNeeds(needs: string[]): boolean {
    const caps = this.selfEntry().capabilities || [];
    if (needs.length === 0) return caps.indexOf('text') >= 0;
    for (const need of needs) {
      if (caps.indexOf(need) < 0) return false;
    }
    return true;
  }

  /** 本机档位：selfEntry 的 modelTier（1-2：1 弱、2 强），未声明/越界 → 2 强档。 */
  private selfTierOf(): number {
    const tier = this.selfEntry().modelTier;
    return tier === 1 ? 1 : 2;
  }

  /**
   * G5：本地能力不足（原规则），或（仅 auto 模式）任务档位高于本机且调度器真会
   * 选别的节点。用 pickNode 真实结果判定，避免"进了调度器又选回本机"造成的
   * 聊天轨道/任务卡错位。pin/split 模式档位盲（实验纯净性）。
   * 仅 hub 有调度权：worker 档位不足时本机直答——档位是质量偏好，绝不变成本机
   * 被拒绝的理由（否则 scheduleRequest 会回"请连接算力设备1"）。
   */
  private shouldScheduleSelf(needs: string[], taskTier: number): boolean {
    if (!this.selfMeetsNeeds(needs)) return true;
    if (this.channel.selfComputeNumber() !== 1) return false;
    if (this.routeMode !== 'auto' && this.routeMode.length > 0) return false;
    if (taskTier <= this.selfTierOf()) return false;
    const pick = pickNode(this.scheduleNodes(), needs, taskTier);
    return pick !== null && !pick.isSelf;
  }

  private recentMessages(question: string): ChatMessage[] {
    const recent = this.history.slice();
    while (recent.length > 0 && (recent.length > 6 ||
      recent.reduce((n: number, m: ChatMessage): number => n + m.content.length, question.length) > 1800)) {
      recent.splice(0, 2);
    }
    this.history = recent;
    const user: ChatMessage = { role: 'user', content: question };
    return recent.concat([user]);
  }

  private pickImage(): void {
    if (this.localBusy()) return;
    pickJpegDataUrl().then((dataUrl: string) => {
      if (dataUrl.length === 0) return;
      this.pendingImage = dataUrl;
      this.emit({ kind: 'image', text: dataUrl });
    }).catch(() => {
      this.emit({ kind: 'image-error', text: '图片读取失败，请重试。' });
    });
  }

  private send(text: string): string {
    const raw = typeof text === 'string' ? text.trim() : '';
    if (raw.length === 0 && this.pendingImage.length === 0) return '请输入问题。';
    if (raw.length > 1100) return '这条消息太长，请缩短后再发送。';
    const question = raw.length > 0 ? raw : '请描述这张图片。';
    if (IS_SERVER) {
      const routed = this.applyRouteCommand(question);
      if (routed !== null) return routed;
      const bench = this.startBench(question);
      if (bench !== null) return bench;
      if (this.localBusy()) return '模型正在回答上一条问题，请稍后再发。';
    } else if (this.activeId || this.model?.isBusy()) {
      return '模型正在回答上一条问题，请稍后再发。';
    }
    if (!IS_SERVER && (!this.channel.isConnected() || !this.serviceReady ||
      this.preparedOperation !== this.channel.operation())) {
      this.ensureCollaborationReady();
      return '协同尚未准备完成，请就绪后发送。';
    }
    const messages = this.recentMessages(question);
    const id = util.generateRandomUUID();
    if (IS_SERVER) {
      // 管线内使用裸 base64：wire 校验与 LocalChat 都不认 data: 前缀。
      const image = jpegBase64Payload(this.pendingImage);
      const needs: string[] = image.length > 0 ? ['vision'] : [];
      // G5：Hub 自身请求仅在本地能力不足，或（仅 auto 模式）任务档位高于本机且
      // 调度器真会选别的节点时交给调度；轻任务与无更强节点时仍本机直答，聊天
      // 轨道的取消/历史行为保持不变。
      const profile = classifyFromMessages(messages, image.length > 0);
      if (this.shouldScheduleSelf(needs, profile.tier)) {
        if (this.railBusy()) return '模型正在回答上一条问题，请稍后再发。';
        const error = this.scheduleRequest(id, messages, 0, false, this.selfComputeLabel(), needs, image);
        if (error) return error;
        if (this.webActiveId.length === 0) this.webActiveId = id;
        this.pendingImage = '';
        return '';
      }
      const error = this.startLocal(id, messages, false, 0, image, '', '', profile.tier);
      if (error) return error;
      this.pendingImage = '';
    } else {
      this.activeId = id; this.answer = ''; this.question = question;
      this.channel?.send({ type: 'request', requestId: id, messages: messages, needs: [] }).then((sent: boolean) => {
        if (!sent && this.activeId === id) this.finish('发送失败，请连接后重试。', true);
      });
    }
    return '';
  }

  private benchPrompt(kind: string): string {
    if (kind === 'b') return 'Write only the integers 100 through 130 in order, separated by commas. No other words.';
    return 'Write only the integers 1 through 30 in order, separated by commas. No other words.';
  }

  private benchMessages(kind: string): ChatMessage[] {
    return [{ role: 'user', content: this.benchPrompt(kind) }];
  }

  /** `key` is the board identity of the job; it also keys local cancellation. */
  private startModel(key: string, messages: ChatMessage[], image: string = ''): string {
    // 带图 → VL 引擎（NPU 多模态）；纯文本 → GEWU 文本引擎（LocalChat）。
    // 带图请求绝不降级发给纯文本引擎：VL 通道不可用时报错，由调度层决定是否转投远端。
    if (image.length > 0 && this.vlTransport !== null) {
      return this.vlTransport.start(messages, (update: ChatUpdate) => this.localUpdate(key, update), key, image);
    }
    // 任务切到纯文本：先卸载驻留的 VL 权重（约 5.3GB）。否则 GEWU 再加载 5.8GB 文本模型
    // 会超过本机内存（MemTotal 15.8GB），被系统低内存杀手杀掉进程——真机实测。
    QwenVlManager.getInstance().unloadIfIdle();
    if (this.transport !== null) {
      return this.transport.start(messages, (update: ChatUpdate) => this.localUpdate(key, update), key, image);
    }
    if (!this.model) return '模型服务尚未初始化。';
    return this.model.start(messages, (update: ChatUpdate) => this.localUpdate(key, update), key, { image: image });
  }

  private queueJob(id: string, messages: ChatMessage[]): string {
    const key = Index.jobKey(0, id);
    const error = this.startModel(key, messages);
    if (error) return error;
    this.jobs.push(this.createJob(id, messages, false, 0));
    this.emitDashboard();
    return '';
  }

  private startBench(question: string): string | null {
    if (question === '__exp_single__') {
      const error = this.queueJob(util.generateRandomUUID(), this.benchMessages('a'));
      if (!error) this.emit({ kind: 'done', text: '实验已启动：单路请求', error: false });
      return error;
    }
    if (question === '__exp_sim__') {
      const first = this.queueJob(util.generateRandomUUID(), this.benchMessages('a'));
      if (first) return first;
      const second = this.queueJob(util.generateRandomUUID(), this.benchMessages('b'));
      if (!second) this.emit({ kind: 'done', text: '实验已启动：双路同时请求', error: false });
      return second;
    }
    if (question === '__exp_serial__') {
      this.pendingB = this.benchMessages('b');
      this.pendingBId = util.generateRandomUUID();
      const error = this.queueJob(util.generateRandomUUID(), this.benchMessages('a'));
      if (!error) this.emit({ kind: 'done', text: '实验已启动：双路串行请求', error: false });
      return error;
    }
    if (question === '__exp_overlap__') {
      this.pendingB = this.benchMessages('b');
      this.pendingBId = util.generateRandomUUID();
      this.overlapArmed = true;
      const error = this.queueJob(util.generateRandomUUID(), this.benchMessages('a'));
      if (!error) this.emit({ kind: 'done', text: '实验已启动：执行中再请求', error: false });
      return error;
    }
    return null;
  }

  private applyRouteCommand(question: string): string | null {
    let mode = '';
    let label = '';
    if (question === '__route_auto__') { mode = 'auto'; label = '自动'; }
    else if (question === '__route_split__') { mode = 'split'; label = '拆到两台'; }
    else if (question === '__route_pin1__') { mode = 'pin1'; label = '都在算力1'; }
    else if (question === '__route_pin2__') { mode = 'pin2'; label = '都在算力2'; }
    else return null;
    this.routeMode = mode;
    this.splitTarget.clear();
    hilog.info(0, 'NearbyChat', 'EXP-MODE mode=%{public}s', mode);
    this.emit({ kind: 'done', text: '实验路由：' + label, error: false });
    return '';
  }

  private chooseNode(nodes: ScheduleNode[], originEpoch: number, needs: string[] = [],
    taskTier: number = 0): ScheduleNode | null {
    if (this.routeMode !== 'split') return pickRoute(nodes, this.routeMode, true, needs, taskTier);
    const prior = this.splitTarget.get(originEpoch);
    let preferSelf = true;
    if (prior === 2) preferSelf = false;
    else if (prior !== 1) {
      let peerTaken = false;
      this.splitTarget.forEach((target: number) => {
        if (target === 2) peerTaken = true;
      });
      preferSelf = !peerTaken;
    }
    const node = pickRoute(nodes, 'split', preferSelf, needs);
    if (node !== null && prior !== 1 && prior !== 2) this.splitTarget.set(originEpoch, node.isSelf ? 1 : 2);
    return node;
  }

  private logRoute(job: ActiveJob): void {
    if (job.routeMode.length === 0 || job.routeMode === 'auto') return;
    hilog.info(0, 'NearbyChat',
      'EXP-ROUTE mode=%{public}s origin=%{public}s worker=%{public}s hop=%{public}d tier=%{public}d id=%{public}s',
      job.routeMode, job.origin, job.source, job.workerEpoch === 0 ? 0 : 1,
      job.taskTier === undefined ? 0 : job.taskTier, job.id);
  }

  private logExperiment(job: ActiveJob): void {
    if (job.routeMode.length === 0 || job.routeMode === 'auto') return;
    const ttft = job.firstAt > job.startedAt ? job.firstAt - job.startedAt : -1;
    const total = job.endedAt > job.startedAt ? job.endedAt - job.startedAt : -1;
    let mem = -1;
    let thermal = -1;
    if (job.workerEpoch === 0) {
      const self = this.selfEntry();
      mem = self.memAvail === undefined ? -1 : self.memAvail;
      thermal = self.thermalLevel === undefined ? -1 : self.thermalLevel;
    } else {
      const stats = this.peerStats.get(job.workerEpoch);
      mem = stats === undefined || stats.memAvail === undefined ? -1 : stats.memAvail;
      thermal = stats === undefined || stats.thermalLevel === undefined ? -1 : stats.thermalLevel;
    }
    hilog.info(0, 'NearbyChat',
      'EXP mode=%{public}s origin=%{public}s worker=%{public}s ttft=%{public}d total=%{public}d chars=%{public}d hop=%{public}d err=%{public}s start=%{public}d mem=%{public}d thermal=%{public}d tier=%{public}d id=%{public}s',
      job.routeMode, job.origin, job.source,
      job.metrics?.streaming === true && job.metrics.outputChunks !== 1 ? ttft : -1, total, job.answer.length,
      job.workerEpoch === 0 ? 0 : 1, job.error ? '1' : '0', job.startedAt, mem, thermal,
      job.taskTier === undefined ? 0 : job.taskTier, job.id);
  }

  /** Card text is the Loop user task; the model still receives the full prompt. */
  private inferQuestion(prompt: string, label: string = ''): string {
    return inferenceSummary(prompt, label);
  }

  private jobImage(image: string): string {
    if (image.length === 0) return '';
    return image.indexOf('data:image/') === 0 ? image : 'data:image/jpeg;base64,' + image;
  }

  private showInferTask(requestId: string, epoch: number, prompt: string, label: string, image: string = ''): void {
    const question = this.inferQuestion(prompt, label);
    if (this.webActiveId.length === 0) this.webActiveId = requestId;
    this.router.beginSelf();
    const job = this.createJob(requestId, [{ role: 'user', content: question }], true, epoch, 0, image);
    if (job.input === undefined) job.input = prompt;
    if (this.isComputeHub()) this.taskObserver.begin(job, label, this.selfComputeLabel());
    this.jobs.push(job);
    hilog.info(0, 'NearbyChat', 'infer card request=%{public}s jobs=%{public}d', requestId, this.jobs.length);
    this.emit({ kind: 'remote-start', text: question, requestId: requestId });
    this.emitDashboard();
    this.relay?.publishLoad();
  }

  private updateJobMetrics(requestId: string, epoch: number, metrics: InferenceMetrics): void {
    const job = this.findJob(requestId, epoch);
    if (job !== undefined) job.metrics = metrics;
  }

  private updateJobPhase(id: string, epoch: number, phase: string): void {
    const job = this.findJob(id, epoch);
    if (job === undefined || job.endedAt > 0 || job.phase === phase) return;
    job.phase = phase; job.phaseStartedAt = Date.now();
    this.emitDashboard();
  }

  private recordFirstOutput(job: ActiveJob, outputAt?: number): void {
    if (job.firstAt !== 0 || job.answer.length === 0) return;
    const now = Date.now();
    // Local native timestamps avoid collapsing callbacks drained in one 80ms poll.
    // Remote calls deliberately use this device's receive clock instead.
    job.firstAt = typeof outputAt === 'number' && Number.isFinite(outputAt) &&
      outputAt >= job.startedAt && outputAt <= now ? outputAt : now;
  }

  private updateInferTask(requestId: string, epoch: number, answer: string, outputAt?: number): void {
    const job = this.findJob(requestId, epoch);
    if (job === undefined) return;
    this.updateJobPhase(requestId, epoch, 'running');
    job.answer = answer;
    this.recordFirstOutput(job, outputAt);
    if (this.webActiveId === requestId) this.emit({ kind: 'text', text: answer, requestId: requestId });
    this.emitDashboard();
  }

  private finishInferTask(requestId: string, epoch: number, answer: string, failed: boolean): void {
    const job = this.findJob(requestId, epoch);
    if (job === undefined) return;
    if (answer.length > 0) job.answer = answer;
    this.router.endSelf();
    const shown = answer.length > 0 ? answer : job.answer;
    this.completeJob(requestId, epoch, shown.length > 0 ? shown : (failed ? '推理失败' : ''), failed);
    this.relay?.publishLoad();
  }

  /** Hub: a forwarded agent request gets the same task card as a local one, labelled with its device. */
  private showRelayTask(requestId: string, chatEpoch: number, workerEpoch: number, messages: ChatMessage[], label: string,
    image: string = ''): void {
    const question = this.inferQuestion(messages[messages.length - 1].content, label);
    if (this.webActiveId.length === 0) this.webActiveId = requestId;
    const job = this.createJob(requestId, [{ role: 'user', content: question }], true, chatEpoch, workerEpoch, image);
    if (job.input === undefined) job.input = messages.map((item: ChatMessage): string => '[' + item.role + ']\n' + item.content).join('\n\n');
    if (this.isComputeHub()) this.taskObserver.begin(job, label, this.selfComputeLabel());
    this.jobs.push(job);
    this.emit({ kind: 'remote-start', text: question, requestId: requestId });
    this.emitDashboard();
  }

  private updateRelayTask(requestId: string, chatEpoch: number, answer: string): void {
    const job = this.findJob(requestId, chatEpoch);
    if (job === undefined) return;
    this.updateJobPhase(requestId, chatEpoch, 'running');
    job.answer = answer;
    if (job.firstAt === 0 && answer.length > 0) job.firstAt = Date.now();
    if (this.webActiveId === requestId) this.emit({ kind: 'text', text: answer, requestId: requestId });
    this.emitDashboard();
  }

  /** The hub (or an unranked single device) routes agent requests; ranked workers only execute. */
  private isComputeHub(): boolean {
    return this.channel.selfComputeNumber() <= 1;
  }

  private chatEpochs(): number[] {
    const epochs: number[] = [];
    for (const peer of this.channel.peerInfos()) {
      if (peer.ready && peer.role === 'chat') epochs.push(peer.epoch);
    }
    return epochs;
  }

  /** Load snapshot for routing: include hand-offs the devices have not reported yet. */
  private poolNodes(): PoolNode[] {
    const nodes: PoolNode[] = [];
    const self = this.selfEntry();
    const own = new PoolNode();
    own.epoch = 0;
    own.label = this.selfComputeLabel();
    own.isSelf = true;
    own.ready = this.model !== null && !!self.model && self.model.length > 0;
    own.inflight = Math.max(self.modelRequests === undefined ? 0 : self.modelRequests, this.inference?.activeCount() ?? 0);
    own.memAvail = self.memAvail === undefined ? -1 : self.memAvail;
    // 能力必须透传给转发决策：infer 侧按它做硬门槛（见 pickIdleFor）。
    own.capabilities = self.capabilities !== undefined && self.capabilities.length > 0 ?
      self.capabilities : ['text'];
    if (self.modelTier !== undefined) own.modelTier = self.modelTier;
    nodes.push(own);
    const peers = this.channel.peerInfos();
    for (const peer of peers) {
      if (peer.role !== 'compute' || !peer.ready) continue;
      const stats = this.peerStats.get(peer.epoch);
      const node = new PoolNode();
      node.epoch = peer.epoch;
      node.label = computeLabel(peer.epoch, peers, this.selfComputeLabel());
      node.ready = !!stats && !!stats.model && stats.model.length > 0;
      node.inflight = this.router.workerLoad(peer.epoch, stats?.modelRequests === undefined ? 0 : stats.modelRequests);
      node.memAvail = stats?.memAvail === undefined ? -1 : stats.memAvail;
      node.capabilities = stats !== undefined && stats.capabilities !== undefined &&
        stats.capabilities.length > 0 ? stats.capabilities : ['text'];
      if (stats?.modelTier !== undefined) node.modelTier = stats.modelTier;
      nodes.push(node);
    }
    return nodes;
  }

  /** Small display notices, sent only when membership or a request phase changes. */
  private publishFlow(calls: JobView[]): void {
    if (!this.isComputeHub()) return;
    const present: string[] = [];
    for (const job of calls) {
      const key = job.key + ':' + job.startedAt.toString();
      present.push(key);
      const phase = job.running ? (job.phase || 'running') : 'cleared';
      const signature = [phase, job.kind || 'text', job.origin, job.source, job.originId || '', job.executorId || ''].join('|');
      if (this.flowNotices.get(key)?.signature === signature) continue;
      this.flowNotices.set(key, { key: key, kind: job.kind || 'text', phase: phase,
        origin: job.origin, source: job.source, originId: job.originId, executorId: job.executorId,
        elapsed: Math.max(0, Date.now() - (job.phaseStartedAt || job.startedAt)), updatedAt: Date.now(),
        revision: ++this.flowRevision, signature: signature });
    }
    for (const notice of this.flowNotices.values()) {
      if (!present.includes(notice.key) && notice.phase !== 'cleared') {
        notice.phase = 'cleared'; notice.signature = 'cleared'; notice.revision = ++this.flowRevision;
      }
    }
    while (this.flowNotices.size > 256) this.flowNotices.delete(Array.from(this.flowNotices.keys())[0]);
    const peers = this.channel.peerInfos().filter((peer) => peer.ready && peer.role === 'compute');
    for (const peer of peers) {
      let delivered = this.flowDeliveries.get(peer.epoch);
      if (delivered === undefined) { delivered = new Map(); this.flowDeliveries.set(peer.epoch, delivered); }
      for (const notice of this.flowNotices.values()) {
        // The executor already has authoritative local callbacks for its own calls.
        if (notice.source === computeLabel(peer.epoch, this.channel.peerInfos()) && !delivered.has(notice.key)) continue;
        if ((delivered.get(notice.key) || 0) >= notice.revision) continue;
        const revision = notice.revision;
        delivered.set(notice.key, revision);
        // No prompt, answer or image data is included in this display channel.
        const payload: FlowNotice = { key: notice.key, kind: notice.kind, phase: notice.phase, origin: notice.origin,
          source: notice.source, originId: notice.originId, executorId: notice.executorId,
          elapsed: notice.elapsed + Math.max(0, Date.now() - notice.updatedAt), updatedAt: 0, revision: revision, signature: '' };
        this.channel.send({ type: 'infer.status', version: 2, requestId: 'flow', source: 'flow-display',
          text: JSON.stringify(payload) }, peer.epoch).then((sent: boolean): void => {
          if (!sent && delivered?.get(notice.key) === revision) delivered.delete(notice.key);
        }).catch((): void => { if (delivered?.get(notice.key) === revision) delivered.delete(notice.key); });
      }
      for (const key of delivered.keys()) if (!this.flowNotices.has(key)) delivered.delete(key);
    }
    for (const epoch of this.flowDeliveries.keys()) if (!peers.some((peer) => peer.epoch === epoch)) this.flowDeliveries.delete(epoch);
  }

  private receiveFlow(message: WireMessage, epoch: number): void {
    const peers = this.channel.peerInfos();
    const peer = peers.find((item) => item.epoch === epoch);
    if (this.isComputeHub() || !peer?.ready || peer.role !== 'compute' || computeLabel(epoch, peers) !== '算力设备1') return;
    let notice: FlowNotice;
    try { notice = JSON.parse(message.text || '') as FlowNotice; } catch (_) { return; }
    if (notice === null || typeof notice !== 'object' || typeof notice.key !== 'string' || notice.key.length > 256 ||
      !Number.isSafeInteger(notice.revision) || notice.revision < 1 ||
      !['text', 'image'].includes(notice.kind) || !['sending', 'running', 'queued', 'cleared'].includes(notice.phase) ||
      typeof notice.origin !== 'string' || notice.origin.length > 128 ||
      typeof notice.source !== 'string' || notice.source.length > 128 ||
      (notice.originId !== undefined && (typeof notice.originId !== 'string' || notice.originId.length > 128)) ||
      (notice.executorId !== undefined && (typeof notice.executorId !== 'string' || notice.executorId.length > 128)) ||
      typeof notice.elapsed !== 'number' || !Number.isFinite(notice.elapsed) || notice.elapsed < 0 || notice.elapsed > 86400000 ||
      notice.revision <= (this.flowVersions.get(notice.key) || 0)) return;
    this.flowVersions.set(notice.key, notice.revision);
    while (this.flowVersions.size > 256) this.flowVersions.delete(Array.from(this.flowVersions.keys())[0]);
    if (notice.phase === 'cleared' || notice.source === this.selfComputeLabel()) {
      this.flowMirrors.delete(notice.key);
    } else {
      if (!this.flowMirrors.has(notice.key) && this.flowMirrors.size >= 128) return;
      const now = Date.now();
      this.flowMirrors.set(notice.key, { key: 'mirror:' + notice.key, id: notice.key, origin: this.forwardedOrigin(notice.origin),
        source: notice.source, originId: notice.originId, executorId: notice.executorId,
        kind: notice.kind, phase: notice.phase, phaseStartedAt: now - notice.elapsed,
        question: '', answer: '', chars: 0, startedAt: now - notice.elapsed, endedAt: 0, firstAt: 0, running: true, error: false, elapsedMs: notice.elapsed });
    }
    this.emitDashboard();
  }

  private receiveInference(message: WireMessage, epoch: number): void {
    if (message.type === 'infer.status' && message.source === 'flow-display') { this.receiveFlow(message, epoch); return; }
    // Chat-owned retry waiting is display-only; it must never create model work.
    if (message.type === 'infer.status' && message.source === 'queue-display') {
      const peer = this.channel.peerInfos().find((item) => item.epoch === epoch);
      if (!this.isComputeHub() || !peer?.ready || peer.role !== 'chat') return;
      const id = message.requestId || '';
      const key = Index.jobKey(epoch, id);
      if (message.state === 'queued' && this.taskLinks.has(key) && !this.findJob(id, epoch) && !this.queuedJobs.has(key)) {
        if (this.queuedJobs.size >= 128) return;
        const job = this.createJob(id, [{ role: 'user', content: '等待分配' }], true, epoch);
        const view = this.toJobView(job, Date.now());
        view.phase = 'queued'; view.source = ''; view.executorId = undefined;
        const elapsed = Number(message.text || '0');
        if (Number.isFinite(elapsed) && elapsed >= 0 && elapsed <= 120000) view.phaseStartedAt = Date.now() - elapsed;
        this.queuedJobs.set(key, view);
      } else if (message.state === 'cleared') {
        this.queuedJobs.delete(key); this.taskLinks.delete(key);
      }
      this.emitDashboard(); return;
    }
    if (message.type === 'infer.task') {
      const peer = this.channel.peerInfos().find((item) => item.epoch === epoch);
      const fromChat = this.isComputeHub() && peer?.ready && peer.role === 'chat';
      const fromHub = !this.isComputeHub() && peer?.ready && peer.role === 'compute' &&
        computeLabel(epoch, this.channel.peerInfos()) === '算力设备1';
      if ((fromChat || fromHub) && message.task !== undefined &&
        this.taskBoard.accept(message.task, epoch, fromChat ? chatLabel(epoch, this.channel.peerInfos()) : this.forwardedOrigin(message.origin || ''),
          fromChat ? this.selfComputeLabel() : computeLabel(epoch, this.channel.peerInfos()))) {
        this.taskObserver.suppress(Index.jobKey(epoch, message.task.id));
        this.emitDashboard();
      } else {
        hilog.warn(0, 'NearbyChat', 'infer.task dropped epoch=%{public}d revision=%{public}d fromChat=%{public}s fromHub=%{public}s',
          epoch, message.task?.revision ?? -1, String(fromChat), String(fromHub));
      }
      return;
    }
    if (message.type === 'infer.request') {
      const peer = this.channel.peerInfos().find((item) => item.epoch === epoch);
      this.queuedJobs.delete(Index.jobKey(epoch, message.requestId || ''));
      const origin = peer?.role === 'chat' ? chatLabel(epoch, this.channel.peerInfos()) : this.forwardedOrigin(message.origin || '');
      message.origin = origin;
      if (this.taskLinks.size >= 128) this.taskLinks.delete(Array.from(this.taskLinks.keys())[0]);
      this.taskLinks.set(Index.jobKey(epoch, message.requestId || ''), {
        imageTask: !!message.image, taskId: message.taskId, subtaskId: message.subtaskId, origin: origin,
        input: message.prompt !== undefined ? message.prompt : (message.messages || []).map((item: ChatMessage): string => '[' + item.role + ']\n' + item.content).join('\n\n') });
    }
    if (message.type === 'infer.accepted' || message.type === 'infer.status' || message.type === 'infer.delta' ||
      message.type === 'infer.done' || message.type === 'infer.error') {
      // Output from a compute device that this hub handed a request to.
      this.relay?.handleFromWorker(message, epoch);
      return;
    }
    if (this.isComputeHub() && this.relay !== null) {
      this.relay.handleFromChat(message, epoch);
      return;
    }
    this.inference?.handle(message, epoch);
  }

  private startLocal(id: string, messages: ChatMessage[], peer: boolean, epoch: number, image: string = '',
    originLabel: string = '', routeMode: string = '', taskTier: number = 0): string {
    if (this.transport === null && this.model === null) return '模型服务尚未初始化。';
    if (!peer && this.localBusy()) return '模型正在回答上一条问题，请稍后再发。';
    // The rail only streams while one card owns the composer; a second peer request
    // would otherwise stream into whichever card happened to be first.
    if (this.webActiveId.length === 0) this.webActiveId = id;
    if (peer) this.router.beginSelf();
    const key = Index.jobKey(epoch, id);
    const error = this.startModel(key, messages, image);
    if (error) {
      if (peer) this.router.endSelf();
      if (this.webActiveId === id) this.webActiveId = '';
      return error;
    }
    const job = this.createJob(id, messages, peer, epoch, 0, image, originLabel, routeMode, taskTier);
    this.jobs.push(job);
    this.logRoute(job);
    hilog.info(0, 'NearbyChat', 'accepted request=%{public}s remote=%{public}s jobs=%{public}d',
      id, String(peer), this.jobs.length);
    if (peer) this.emit({ kind: 'remote-start', text: messages[messages.length - 1].content, requestId: id });
    this.emitDashboard();
    return '';
  }

  /** 通道标签：分档策略附带最近一次请求的档位与实际服役模型（如 分档·COMPLEX·云侧GLM-5.3），
   * 其余策略为静态侧别。端侧模型取部署目录名，缩写规则与 peer-chat.html 的 shortModel 一致。 */
  private backendLabel(): string {
    if (this.backendSide !== '分档' || this.modelRouter === null) return this.backendSide;
    const decision = this.modelRouter.lastDecision();
    if (decision === null) return this.backendSide;
    const tier = decision.tier !== undefined && decision.tier.length > 0 ? '·' + decision.tier : '';
    if (decision.side === 'cloud') {
      const model = decision.model !== undefined && decision.model.length > 0 ?
        decision.model : this.backendModel;
      return '分档' + tier + '·云侧' + model;
    }
    return '分档' + tier + '·端侧' + this.deployedModelLabel();
  }

  /** 端侧部署目录名的展示缩写（与 web 侧 shortModel 同规则，防徽章过长）。 */
  private deployedModelLabel(): string {
    return deployedModelName(this.filesDir).replace(/-Instruct.*$/, '').replace(/-Q4.*$/, '');
  }

  private selfEntry(): DeviceInfoEntry {
    const running = this.model === null ? 0 : this.model.activeCount();
    const entry = buildSelfEntry(this.filesDir, this.router.selfLoad(running), '本机', 'self');
    // 云侧时设备卡展示实际服役的云模型；端侧沿用本地模型目录扫描结果。
    if (this.backendSide === '云侧' && this.backendModel.length > 0) entry.model = this.backendModel;
    return entry;
  }

  private clusterSelfEntry(): DeviceInfoEntry {
    const entry = this.selfEntry();
    entry.id = this.channel.localUid() || entry.id;
    entry.deviceUid = this.channel.localUid();
    entry.name = this.channel.localName();
    entry.role = 'compute';
    const slot = this.channel.selfComputeNumber();
    if (slot >= 1) entry.slot = slot;
    return entry;
  }

  private scheduleNodes(): ScheduleNode[] {
    const nodes: ScheduleNode[] = [];
    const self = this.selfEntry();
    if (self.model && self.model.length > 0) {
      const node = new ScheduleNode();
      node.epoch = 0;
      node.name = '本机';
      node.isSelf = true;
      node.model = self.model;
      node.capabilities = self.capabilities || [];
      node.requests = self.modelRequests === undefined ? 0 : self.modelRequests;
      node.memAvail = self.memAvail === undefined ? -1 : self.memAvail;
      if (self.modelTier !== undefined) node.modelTier = self.modelTier;
      nodes.push(node);
    }
    const peers = this.channel.peerInfos();
    for (const peer of peers) {
      if (peer.role !== 'compute' || !peer.ready) continue;
      const stats = this.peerStats.get(peer.epoch);
      const model = stats?.model || '';
      if (model.length === 0) continue;
      const node = new ScheduleNode();
      node.epoch = peer.epoch;
      node.name = peer.name;
      node.model = model;
      node.capabilities = stats?.capabilities || ['text'];
      node.requests = this.router.workerLoad(peer.epoch, stats?.modelRequests === undefined ? 0 : stats.modelRequests);
      node.memAvail = stats?.memAvail === undefined ? -1 : stats.memAvail;
      if (stats?.modelTier !== undefined) node.modelTier = stats.modelTier;
      nodes.push(node);
    }
    return nodes;
  }

  private scheduleRequest(id: string, messages: ChatMessage[], originEpoch: number, sched: boolean,
    forwardedOrigin: string = '', needs: string[] = [], image: string = ''): string {
    if (image.length > 0 && needs.length === 0) needs = ['vision'];
    if (sched) return this.startLocal(id, messages, true, originEpoch, image, forwardedOrigin || '聊天设备');
    if (this.channel.selfComputeNumber() !== 1) return '请连接算力设备1，由它统一调度。';
    const nodes = this.scheduleNodes();
    // 档位与执行端同规则重算：消息逐字转发，两侧分类结果一致（tier 不上线协议）。
    const profile = classifyFromMessages(messages, image.length > 0);
    const node = this.chooseNode(nodes, originEpoch, needs, profile.tier);
    // nodeTier < tier 即降档；node=none 即能力不合格（fail closed）。
    hilog.info(0, 'NearbyChat',
      'ROUTE id=%{public}s tier=%{public}d reason=%{public}s needs=%{public}s mode=%{public}s node=%{public}s nodeTier=%{public}d',
      id, profile.tier, profile.reason, needs.join(','), this.routeMode,
      node === null ? 'none' : (node.isSelf ? '本机' : node.name),
      node === null ? 0 : node.modelTier);
    if (node === null) {
      if (this.routeMode === 'pin1') return '实验路由找不到算力设备1。';
      if (this.routeMode === 'pin2') return '实验路由找不到算力设备2。';
      // 有带模型的设备却选不出，只能是能力不满足：绝不降级发给不具备能力的设备。
      if (nodes.length > 0) return '集群中没有支持' + (needs.length > 0 ? needsLabel(needs) : '文字推理') + '的设备。';
      return '集群中无已部署模型的可用设备。';
    }
    if (node.isSelf) return this.startLocal(id, messages, true, originEpoch, image, '', this.routeMode, profile.tier);
    const entry = new DispatchEntry();
    entry.originEpoch = originEpoch;
    entry.originRequestId = id;
    entry.workerEpoch = node.epoch;
    entry.workerName = node.name;
    // The forwarded id is ours, not the origin's: the worker echoes it back
    // verbatim and that is the only way to tell two same-id requests apart.
    const dispatch = this.router.beginDispatch(id, entry);
    const job = this.createJob(id, messages, true, originEpoch, node.epoch, image,
      originEpoch === 0 ? this.selfComputeLabel() : '', this.routeMode, profile.tier);
    this.jobs.push(job);
    this.logRoute(job);
    this.emitDashboard();
    this.channel.send({
      type: 'request', requestId: dispatch.forwardId, messages: messages, sched: true,
      origin: job.origin, needs: needs, image: image
    }, node.epoch)
      .then((sent: boolean) => {
        if (sent) return;
        this.router.finishForward(dispatch.forwardId);
        this.channel.send({ type: 'error', requestId: id, error: '派发失败：与执行设备 ' + node.name + ' 的会话已断开' },
          originEpoch);
        this.completeJob(id, originEpoch, '派发失败', true);
      });
    return '';
  }

  private handleCancel(id: string, epoch: number): void {
    const dispatch = this.router.getDispatch(id, epoch);
    if (dispatch !== undefined && dispatch.originEpoch === epoch) {
      // The worker only knows the forwarded id.
      this.channel.send({ type: 'cancel', requestId: dispatch.forwardId }, dispatch.workerEpoch);
      return;
    }
    const job = this.findJob(id, epoch);
    if (job !== undefined && job.peer && job.epoch === epoch) {
      this.model?.cancel(job.key);
      this.vlTransport?.cancel(); // VL 引擎为单任务，引擎级取消即覆盖该卡
    }
  }

  private handleWorkerReply(message: WireMessage, epoch: number): void {
    const forwardId = message.requestId;
    if (!forwardId) return;
    // Match on the id we generated for this hand-off. Origin ids are not unique
    // here: two chat devices may both be running a request called r1.
    const dispatch = this.router.getByForwardId(forwardId);
    if (dispatch === undefined || dispatch.workerEpoch !== epoch) return;
    this.routeWorkerReply(message, dispatch, forwardId);
  }

  private routeWorkerReply(message: WireMessage, dispatch: DispatchEntry, forwardId: string): void {
    const id = dispatch.originRequestId;
    if (message.metrics !== undefined) this.updateJobMetrics(id, dispatch.originEpoch, message.metrics);
    // originEpoch 0 = Hub 自己的请求被转发：回复不走出链接，直接回流聊天轨道。
    const selfOrigin = dispatch.originEpoch === 0;
    if (message.type === 'delta') {
      const job = this.findJob(id, dispatch.originEpoch);
      if (job === undefined) return;
      if (!message.text || message.text.length === 0) return;
      this.updateJobPhase(id, dispatch.originEpoch, 'running');
      job.answer += message.text || '';
      if (job.firstAt === 0) job.firstAt = Date.now();
      this.emitDashboard();
      if (selfOrigin) {
        if (this.webActiveId === id) this.emit({ kind: 'text', text: job.answer, requestId: id });
      } else {
        this.channel.send({ type: 'delta', requestId: id, text: message.text || '', metrics: message.metrics }, dispatch.originEpoch);
      }
      return;
    }
    const job = this.router.finishForward(forwardId) === undefined ? undefined : this.findJob(id, dispatch.originEpoch);
    if (message.type === 'error') {
      if (!selfOrigin) {
        this.channel.send({ type: 'error', requestId: id, error: message.error || '执行设备推理失败' },
          dispatch.originEpoch);
      }
      this.completeJob(id, dispatch.originEpoch, message.error || '执行设备推理失败', true);
      return;
    }
    if (!selfOrigin) {
      this.channel.send({
        type: 'done', requestId: id, finishReason: message.finishReason,
        source: workerTail(dispatch.workerEpoch, this.channel.peerInfos(), this.selfComputeLabel()), metrics: message.metrics
      }, dispatch.originEpoch);
    } else if (job !== undefined && message.finishReason !== 'cancelled') {
      // 与本地执行路径一致：完成的对话回填历史，供后续多轮上下文使用。
      this.history.push({ role: 'user', content: job.question });
      this.history.push({ role: 'assistant', content: job.answer });
    }
    const stopped = message.finishReason === 'cancelled';
    this.completeJob(id, dispatch.originEpoch, job === undefined ? '' :
      (stopped && job.answer.length > 0 ? job.answer + '\n\n已停止生成' : job.answer), false);
  }

  private handleDeviceInfo(message: WireMessage, epoch: number): void {
    if (message.memUsage !== undefined || message.model !== undefined ||
      message.thermalLevel !== undefined || message.batteryTemp !== undefined ||
      message.cpuUsage !== undefined || message.modelRequests !== undefined || message.modelTier !== undefined) {
      let entry = this.peerStats.get(epoch);
      if (entry === undefined) {
        entry = { role: this.channel.peerRole(epoch) || 'compute', capabilities: [] };
      }
      applyDeviceInfo(entry, message);
      this.peerStats.set(epoch, entry);
      if (entry.memAvail !== undefined) this.channel.setPeerMem(epoch, entry.memAvail);
      this.emitDashboard();
      this.relay?.publishLoad();
      return;
    }
    if (message.requestId) this.replyDeviceInfo(message.requestId, epoch);
  }

  private handleClusterSync(message: WireMessage, epoch: number): void {
    const devices = message.devices === undefined ? [] : message.devices;
    const peers = this.channel.peerInfos();
    for (const sender of peers) {
      if (sender.epoch === epoch && sender.ready && sender.role === 'compute') {
        if (!this.channel.applyRemoteRoster(epoch, devices)) break;
        // Re-read the rank after applying the roster. Only the current hub can
        // report indirect members; a worker's old snapshot is not authoritative.
        const current = this.channel.peerInfos().find((peer) => peer.epoch === epoch);
        if (this.channel.selfComputeNumber() > 1 && current !== undefined && current.slot === 1) {
          this.remoteSeen.set(epoch, devices);
        } else {
          this.remoteSeen.delete(epoch);
        }
        break;
      }
    }
    this.refreshRemoteChats();
    this.emitDashboard();
  }

  /** Only a connected current hub may supply indirect members. */
  private remoteEntries(): DeviceInfoEntry[] {
    const result: DeviceInfoEntry[] = [];
    if (this.channel.selfComputeNumber() <= 1) return result;
    const hub = this.channel.peerInfos().find((peer) =>
      peer.ready && peer.role === 'compute' && peer.slot === 1);
    if (hub === undefined) return result;
    const seen: string[] = [];
    this.remoteSeen.forEach((entries, epoch) => {
      if (epoch !== hub.epoch || !this.channel.hasEpoch(epoch)) return;
      for (const entry of entries) {
        const identity = entry.deviceUid || entry.id || '';
        const mark = identity.length > 0 ? 'id:' + identity :
          (entry.role || '') + ':' + (entry.name || '');
        if (seen.indexOf(mark) >= 0) continue;
        seen.push(mark);
        result.push(entry);
      }
    });
    return result;
  }

  /** Only expose remote chats from the current hub's live snapshot. */
  private refreshRemoteChats(): void {
    const chats: string[] = [];
    for (const entry of this.remoteEntries()) {
      if (entry.role === 'chat' && entry.name && chats.indexOf(entry.name) < 0) chats.push(entry.name);
    }
    this.channel.setRemoteChats(chats);
  }

  private replyDeviceInfo(requestId: string, epoch: number): void {
    this.channel.send(toDeviceInfoReply(requestId, this.clusterSelfEntry()), epoch);
  }

  private inferenceLoadStatus(running: number): WireMessage {
    return { type: 'deviceInfo', requestId: 'load-' + String(Date.now()),
      model: deployedModelName(this.filesDir), modelRequests: running, peerRole: 'compute' };
  }

  private startMeshRetry(): void {
    if (this.meshTimer !== -1) return;
    this.meshTimer = setInterval(() => {
      if (!this.serviceReady) return;
      this.channel.connectOtherComputes(this.channel.operation()).catch(() => {});
    }, 7000);
  }

  private stopMeshRetry(): void {
    if (this.meshTimer === -1) return;
    clearInterval(this.meshTimer);
    this.meshTimer = -1;
  }

  private startInfoPoll(): void {
    if (this.infoTimer !== -1) return;
    this.infoTimer = setInterval(() => this.pollDeviceInfo(), DEVICE_INFO_POLL_MS);
    this.pollDeviceInfo();
  }

  private stopInfoPoll(): void {
    if (this.infoTimer === -1) return;
    clearInterval(this.infoTimer);
    this.infoTimer = -1;
    this.rosterDeliveries.clear();
    this.lastPublishedRunning = -1;
  }

  private pollDeviceInfo(): void {
    if (!IS_SERVER || !this.serviceReady) return;
    let self = this.clusterSelfEntry();
    this.channel.setSelfMem(self.memAvail === undefined ? -1 : self.memAvail);
    // Memory can finish the initial election; snapshot the resulting slot, not 0.
    self = this.clusterSelfEntry();
    const peers = this.channel.peerInfos();
    const cluster: DeviceInfoEntry[] = [self];
    for (const peer of peers) {
      if (!peer.ready) continue;
      const stats = this.peerStats.get(peer.epoch);
      const identity = peer.deviceUid || peer.peerId;
      const entry: DeviceInfoEntry = {
        id: identity, deviceUid: peer.deviceUid || undefined,
        name: peer.helloName || '', role: peer.role || 'chat', ready: peer.ready,
        model: stats?.model, memUsage: stats?.memUsage, memAvail: stats?.memAvail,
        memTotal: stats?.memTotal, thermalLevel: stats?.thermalLevel,
        batteryTemp: stats?.batteryTemp, cpuUsage: stats?.cpuUsage,
        modelRequests: stats?.modelRequests,
        capabilities: stats?.capabilities || [],
        modelTier: stats?.modelTier
      };
      if (peer.role === 'chat' && peer.slot > 0) entry.slot = peer.slot;
      if (peer.role === 'compute' && peer.slot > 0) entry.slot = peer.slot;
      cluster.push(entry);
    }
    const signature = cluster.map((entry: DeviceInfoEntry) =>
      entry.id + ':' + (entry.role || '') + ':' + String(entry.slot || 0)).sort().join('|');
    const now = Date.now();
    const busy = this.jobs.length > 0;
    const isHub = this.channel.selfComputeNumber() === 1;
    // Topology is control traffic: membership changes must reach joining nodes
    // during inference too. Strip telemetry/name duplication to keep it small.
    const compact = cluster.map((entry: DeviceInfoEntry): DeviceInfoEntry => ({
      id: entry.deviceUid || entry.id, role: entry.role, slot: entry.slot, ready: entry.ready,
      capabilities: entry.capabilities || []
    }));
    // Publish only self and direct peers. Re-forwarding another compute's roster
    // created a cycle in which a disconnected chat survived forever as a ghost.
    for (const peer of peers) {
      if (!peer.ready) continue;
      // Chat peers neither consume the cluster roster nor supply scheduling
      // metrics. Avoid sending a multi-frame snapshot to every chat phone.
      if (peer.role !== 'compute') continue;
      if (busy) {
        this.channel.send(this.inferenceLoadStatus(this.jobs.filter((job: ActiveJob): boolean => job.workerEpoch === 0).length), peer.epoch);
      }
      const prior = this.rosterDeliveries.get(peer.epoch);
      const changed = prior === undefined || prior.signature !== signature;
      const syncRoster = isHub && (changed || (!busy && !prior?.pending && now - (prior?.lastFullAt || 0) >= 30000));
      if (syncRoster) {
        const operation = this.channel.operation();
        const delivery: RosterDelivery = { signature: signature, pending: true, lastFullAt: prior?.lastFullAt || 0 };
        this.rosterDeliveries.set(peer.epoch, delivery);
        this.channel.send({ type: 'deviceInfoSync', requestId: 'sync-' + String(peer.epoch), devices: busy ? compact : cluster },
          peer.epoch).then((sent: boolean) => {
          if (operation !== this.channel.operation() || this.rosterDeliveries.get(peer.epoch) !== delivery) return;
          delivery.pending = false;
          if (!sent) { delivery.signature = ''; return; }
          if (!busy) delivery.lastFullAt = Date.now();
          if (this.jobs.length === 0 && this.channel.hasEpoch(peer.epoch)) {
            // The empty info frame is only a poll: capabilities must stay declared
            // because validDeviceInfo requires the field on every deviceInfo wire.
            this.channel.send({ type: 'deviceInfo', requestId: 'info-' + String(peer.epoch), capabilities: [] }, peer.epoch);
          }
        });
      } else if (!busy) {
        this.channel.send({ type: 'deviceInfo', requestId: 'info-' + String(peer.epoch), capabilities: [] }, peer.epoch);
      }
    }
    this.emitDashboard();
  }

  /**
   * `id` is the wire request id as the origin sent it; `key` is the engine handle.
   * They differ only for work a chat peer asked for, where the engine must key on
   * the origin session so two peers can reuse one id.
   */
  private localUpdate(key: string, update: ChatUpdate): void {
    const job = this.findJobByKey(key);
    if (job === undefined) return;
    if (update.metrics !== undefined) job.metrics = update.metrics;
    const id = job.id;
    if (update.kind === 'delta') {
      if (update.text.length === 0) return;
      job.answer += update.text;
      this.recordFirstOutput(job, update.outputAt);
      // requestId lets the page update that one card instead of waiting for the next
      // dashboard poll; without it the rail lagged the reply by up to five seconds.
      if (this.webActiveId === id) this.emit({ kind: 'text', text: job.answer, requestId: id });
      this.emitDashboard();
      if (job.peer) this.channel?.send({ type: 'delta', requestId: id, text: update.text, metrics: update.metrics }, job.epoch);
      if (this.overlapArmed && this.pendingB !== null) {
        this.overlapArmed = false;
        const follow = this.pendingB;
        const followId = this.pendingBId;
        this.pendingB = null;
        this.pendingBId = '';
        this.queueJob(followId, follow);
      }
      return;
    }
    if (job.peer) {
      const message: WireMessage = update.error ? { type: 'error', requestId: id, error: update.error } :
        { type: 'done', requestId: id, finishReason: update.finishReason,
          source: workerTail(0, this.channel.peerInfos(), this.selfComputeLabel()), metrics: update.metrics };
      this.channel?.send(message, job.epoch);
      this.router.endSelf();
    } else if (!update.error && update.finishReason !== 'cancelled' &&
      job.question.indexOf('Write only the integers') < 0) {
      this.history.push({ role: 'user', content: job.question });
      this.history.push({ role: 'assistant', content: job.answer });
    }
    hilog.info(0, 'NearbyChat', 'finished request=%{public}s reason=%{public}s', id, update.finishReason || 'error');
    if (this.webActiveId === id) this.webActiveId = '';
    if (update.finishReason === 'cancelled') job.phase = 'cancelled';
    this.completeJob(id, job.epoch, update.text, !!update.error);
  }

  private receive(message: WireMessage, epoch: number): void {
    if (IS_SERVER) {
      if (message.type.indexOf('infer.') === 0) {
        this.receiveInference(message, epoch);
        return;
      }
      if (message.type === 'deviceInfo') {
        this.handleDeviceInfo(message, epoch);
      } else if (message.type === 'deviceInfoSync') {
        this.handleClusterSync(message, epoch);
      } else if (message.type === 'prepare' && message.requestId) {
        const textError = this.model?.readinessError() ?? '模型服务尚未初始化。';
        const error = textError && this.vlTransport?.readinessError() === '' ? '' : textError;
        const reply: WireMessage = { type: 'prepared', requestId: message.requestId };
        if (error) reply.error = error;
        this.channel.send(reply, epoch);
        hilog.info(0, 'NearbyChat', 'service prepared request=%{public}s ready=%{public}s',
          message.requestId, String(!error));
        this.replyDeviceInfo(message.requestId, epoch);
      } else if (message.type === 'request' && message.messages && message.requestId) {
        const error = this.scheduleRequest(message.requestId, message.messages, epoch, message.sched === true,
          message.origin || '', message.needs || [], message.image || '');
        if (error) this.channel?.send({ type: 'error', requestId: message.requestId, error: error }, epoch);
      } else if (message.type === 'cancel' && message.requestId) {
        this.handleCancel(message.requestId, epoch);
      } else if (message.type === 'delta' || message.type === 'done' || message.type === 'error') {
        this.handleWorkerReply(message, epoch);
      }
      return;
    }
    if (!this.activeId || message.requestId !== this.activeId) return;
    if (message.type === 'delta') {
      this.answer += message.text || '';
      this.emit({ kind: 'text', text: this.answer });
    } else if (message.type === 'done') {
      const stopped = message.finishReason === 'cancelled';
      if (!stopped && this.answer) this.remember();
      this.finish(stopped ? this.answer + (this.answer ? '\n\n' : '') + '已停止生成' :
        (this.answer || '模型没有返回内容，请重试。'), !stopped && !this.answer);
    } else if (message.type === 'error') {
      const busy = (message.error || '').indexOf('请稍后再发') >= 0;
      if (!busy) {
        this.serviceReady = false;
        this.connectionError = message.error || '请求失败，请点击输入框重试。';
      }
      this.finish(message.error || '请求失败，请点击输入框重试。', true);
      this.showConnection();
    }
  }

  private remember(): void {
    this.history.push({ role: 'user', content: this.question });
    this.history.push({ role: 'assistant', content: this.answer });
  }

  private completeJob(id: string, epoch: number, text: string, error: boolean): void {
    const job = this.findJob(id, epoch);
    const key = Index.jobKey(epoch, id);
    if (job !== undefined) {
      job.endedAt = Date.now();
      job.error = error;
      if (text && job.answer.length === 0) job.answer = text;
      this.noteUsage(job);
      if (this.isComputeHub() && job.peer) {
        this.deviceSpeed.record(job.workerEpoch, job.endedAt - job.startedAt,
          (job.input === undefined ? 0 : job.input.length) + job.answer.length, error);
      }
      this.taskObserver.end(job);
      this.jobs.splice(this.jobs.indexOf(job), 1);
      // A reused request id must not evict the earlier card with the same wire id.
      for (let i = this.finishedJobs.length - 1; i >= 0; i--) {
        if (this.finishedJobs[i].key === key) this.finishedJobs.splice(i, 1);
      }
      this.finishedJobs.unshift(job);
      // Long parallel runs produce many cards (split, sub-tasks, merge); keep the whole run visible.
      if (this.finishedJobs.length > MAX_FINISHED_JOBS) this.finishedJobs.pop();
      this.logExperiment(job);
    }
    if (this.webActiveId === id) this.webActiveId = '';
    this.emit({ kind: 'done', text: text, error: error, requestId: id });
    this.emitDashboard();
    if (this.pendingB !== null && !this.overlapArmed && this.jobs.length === 0) {
      const follow = this.pendingB;
      const followId = this.pendingBId;
      this.pendingB = null;
      this.pendingBId = '';
      this.queueJob(followId, follow);
    }
  }

  /** Successful local calls only. Forwarded work is counted by the device that ran it. */
  private noteUsage(job: ActiveJob): void {
    if (job.error || job.workerEpoch !== 0 || job.phase === 'cancelled') return;
    const taskKey = job.taskId !== undefined && job.taskId.length > 0 ? Index.jobKey(job.epoch, job.taskId) : '';
    if (!recordLocalCall(this.usage, job.key, taskKey, job.metrics?.promptTokens, job.metrics?.completionTokens, job.endedAt)) return;
    saveUsage(this.filesDir, this.usage);
  }

  /** A parent task counts once, after this device has already recorded one of its calls. */
  private noteFinishedTasks(groups: TaskGroupView[]): void {
    let changed = false;
    for (const group of groups) {
      if (group.phase === 'done' && recordFinishedTask(this.usage, group.key)) changed = true;
    }
    if (changed) saveUsage(this.filesDir, this.usage);
  }

  /** Clears the finished-task list only; running tasks stay so their results still arrive. */
  private clearFinishedJobs(): void {
    const activeTasks = this.taskViews().filter((group: TaskGroupView): boolean => group.endedAt === 0)
      .map((group: TaskGroupView): string => group.key);
    this.finishedJobs = this.finishedJobs.filter((job: ActiveJob): boolean =>
      job.taskId !== undefined && activeTasks.includes(Index.jobKey(job.epoch, job.taskId)));
    this.taskBoard.clearFinished();
    this.taskObserver.clearFinished();
    this.emitDashboard();
  }

  private finish(text: string, error: boolean): void {
    this.activeId = '';
    this.emit({ kind: 'done', text: text, error: error });
  }

  private stop(): void {
    if (IS_SERVER) {
      const local = this.jobs.find((item: ActiveJob) => !item.peer);
      if (local !== undefined) {
        this.model?.cancel(local.key);
        this.vlTransport?.cancel(); // VL 引擎为单任务，引擎级取消即覆盖本地卡
        return;
      }
      // Hub 自己转发出去的请求：按转发句柄取消远端执行。
      const forwarded = this.jobs.find((item: ActiveJob) => item.peer && item.epoch === 0);
      if (forwarded !== undefined) this.handleCancel(forwarded.id, 0);
      return;
    }
    if (!this.activeId) return;
    const id = this.activeId;
    this.channel?.send({ type: 'cancel', requestId: id }).then((sent: boolean) => {
      if (!sent && this.activeId === id) this.finish('连接已中断，停止请求未送达。', true);
    });
  }

  build() {
    Stack() {
      Web({ src: $rawfile('peer-chat.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .javaScriptProxy({ object: this.bridge, name: 'chatBridge', methodList: ['send', 'stop', 'connect', 'prepare', 'pickImage', 'clear', 'clearImage', 'selectModel', 'models', 'setOutputMode', 'usageSettings', 'saveUsageSettings'], controller: this.controller })
        .onPageEnd(() => {
          this.pageReady = true;
          this.channel.subscribe(
            (message: WireMessage, epoch: number) => this.receive(message, epoch),
            (connected: boolean, epoch: number) => this.connectionChanged(connected, epoch));
          this.showConnection();
          if (this.autoConnect) this.ensureCollaborationReady(false);
        })
        .onLoadIntercept((event) => !event.data.getRequestUrl().startsWith('resource://rawfile/'))
        .width('100%').height('100%').backgroundColor('#FFF9F4')
    }.width('100%').height('100%')
  }
}
