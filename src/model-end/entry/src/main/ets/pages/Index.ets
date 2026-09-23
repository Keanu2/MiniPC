import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalChat, ChatUpdate } from '../llm/LocalChat';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { WireMessage, ChatMessage, DeviceInfoEntry } from '../protocol/ChatProtocol';
import { IS_SERVER } from '../nearby/NearbyConfig';
import { ComputeRouter, DispatchEntry, ScheduleNode, originKeyOf, pickRoute } from '../cluster/ComputeRouter';
import { LocalLlmTransport } from '../llm/LlmTransport';
import { pickJpegDataUrl } from '../media/ImageAttach';
import {
  DEVICE_INFO_POLL_MS, applyDeviceInfo, buildSelfEntry,
  toDeviceInfoReply
} from '../cluster/DeviceInfo';
import { chatLabel, computeLabel, hidePhoneName, publicLabel, workerTail } from '../cluster/DeviceLabels';
import { ChatBridge } from '../ui/ChatBridge';
import { ActiveJob, DeviceView, JobView, PageEvent } from '../ui/DashboardTypes';

interface RosterDelivery {
  signature: string;
  pending: boolean;
  lastFullAt: number;
}

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
    }, () => { this.pickImage(); });
  private channel = nearbyChannel;
  private connecting: boolean = false;
  private preparation: Promise<void> | null = null;
  private serviceReady: boolean = false;
  private preparedOperation: number = -1;
  private selectedDeviceId: string = '';
  private autoConnect: boolean = true;
  private connectManual: boolean = false;
  private model: LocalChat | null = null;
  private transport: LocalLlmTransport | null = null;
  private pageReady: boolean = false;
  private connectionError: string = '';
  private activeId: string = '';
  /** Wire request id backing the WebView's live task card; '' when none is streaming. */
  private webActiveId: string = '';
  private answer: string = '';
  private question: string = '';
  private jobs: ActiveJob[] = [];
  private finishedJobs: ActiveJob[] = [];
  private history: ChatMessage[] = [];
  private pendingB: ChatMessage[] | null = null;
  private pendingBId: string = '';
  private overlapArmed: boolean = false;
  private filesDir: string = '';
  private router: ComputeRouter = new ComputeRouter();
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
      this.model = new LocalChat(this.filesDir);
      this.transport = new LocalLlmTransport(this.model);
    }
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.stopInfoPoll();
    this.stopMeshRetry();
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
    image: string = '', originLabel: string = '', routeMode: string = ''): ActiveJob {
    const peers = this.channel.peerInfos();
    return {
      id: id, key: Index.jobKey(epoch, id), epoch: epoch, peer: peer, answer: '', question: messages[messages.length - 1].content,
      startedAt: Date.now(), firstAt: 0, endedAt: 0, error: false,
      source: computeLabel(workerEpoch, peers, this.selfComputeLabel()),
      origin: originLabel.length > 0 ? this.forwardedOrigin(originLabel) : (peer ? chatLabel(epoch, peers) : '本机'),
      workerEpoch: workerEpoch,
      image: peer ? '' : image,
      routeMode: routeMode
    };
  }

  /** A forwarded task may expose only the public chat label, never a phone name. */
  private forwardedOrigin(origin: string): string {
    const label = origin.trim();
    if (label === '本机' || label === '聊天设备' || label.indexOf('聊天设备') === 0) return label;
    return '聊天设备';
  }

  private toJobView(job: ActiveJob, now: number): JobView {
    const ended = job.endedAt > 0;
    const elapsed = (ended ? job.endedAt : now) - job.startedAt;
    return {
      id: job.id, key: job.key, source: job.source, origin: job.origin, local: !job.peer,
      image: job.image, question: job.question, answer: job.answer,
      chars: job.answer.length, startedAt: job.startedAt, firstAt: job.firstAt,
      endedAt: job.endedAt, running: !ended, error: job.error,
      elapsedMs: elapsed < 0 ? 0 : elapsed
    };
  }

  private emitDashboard(): void {
    this.channel.setActiveJobs(this.jobs.length);
    if (!IS_SERVER || !this.pageReady) return;
    const runningNow = this.jobs.filter((job: ActiveJob) => job.workerEpoch === 0).length;
    // Same rule as the roster in pollDeviceInfo(): background telemetry yields to
    // streaming inference. The counters below still update, so the next idle poll
    // publishes the value that changed while a request was in flight.
    if (this.serviceReady && this.jobs.length === 0 && runningNow !== this.lastPublishedRunning) {
      const previousRunning = this.lastPublishedRunning;
      this.lastPublishedRunning = runningNow;
      const status = toDeviceInfoReply('status-' + String(Date.now()), this.clusterSelfEntry());
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
      modelRequests: self.modelRequests
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
        modelRequests: stats?.modelRequests
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
        epoch: -1, name: name, id: id || name, ready: extra.ready !== false, jobs: 0,
        role: role, model: extra.model, memUsage: extra.memUsage,
        thermalLevel: extra.thermalLevel, batteryTemp: extra.batteryTemp, cpuUsage: extra.cpuUsage,
        modelRequests: extra.modelRequests
      });
    }
    const views: JobView[] = [];
    // The task rail is local evidence, not a cluster-wide coordinator ledger.
    // A job with workerEpoch != 0 is only passing through this device on its way
    // to another compute. The executing compute creates its own workerEpoch=0 job,
    // so filtering here leaves exactly the tasks this box actually inferred.
    for (const job of this.jobs) {
      if (job.workerEpoch === 0) views.push(this.toJobView(job, now));
    }
    for (const job of this.finishedJobs) {
      if (job.workerEpoch === 0) views.push(this.toJobView(job, now));
    }
    const localRunning = this.jobs.filter((job: ActiveJob) => job.workerEpoch === 0).length;
    devices.sort(compareDevices);
    this.emit({
      kind: 'dashboard',
      text: this.connectionError || this.channel.getStatus(),
      available: true,
      connectLabel: this.serviceReady ? '停用近场' : '启用近场',
      connecting: this.connecting || this.channel.isConnecting(),
      running: localRunning,
      selfLabel: this.selfComputeLabel(),
      devices: devices,
      jobs: views
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
      this.cancelDroppedPeers();
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
      if (job.peer && !this.channel.hasEpoch(job.epoch) && job.workerEpoch === 0) this.model?.cancel(job.key);
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
      const image = this.pendingImage;
      const error = this.startLocal(id, messages, false, 0, image);
      if (error) return error;
      this.pendingImage = '';
    } else {
      this.activeId = id; this.answer = ''; this.question = question;
      this.channel?.send({ type: 'request', requestId: id, messages: messages }).then((sent: boolean) => {
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
  private startModel(key: string, messages: ChatMessage[]): string {
    if (this.transport !== null) {
      return this.transport.start(messages, (update: ChatUpdate) => this.localUpdate(key, update), key);
    }
    if (!this.model) return '模型服务尚未初始化。';
    return this.model.start(messages, (update: ChatUpdate) => this.localUpdate(key, update), key);
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

  private chooseNode(nodes: ScheduleNode[], originEpoch: number): ScheduleNode | null {
    if (this.routeMode !== 'split') return pickRoute(nodes, this.routeMode, true);
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
    const node = pickRoute(nodes, 'split', preferSelf);
    if (node !== null && prior !== 1 && prior !== 2) this.splitTarget.set(originEpoch, node.isSelf ? 1 : 2);
    return node;
  }

  private logRoute(job: ActiveJob): void {
    if (job.routeMode.length === 0 || job.routeMode === 'auto') return;
    hilog.info(0, 'NearbyChat',
      'EXP-ROUTE mode=%{public}s origin=%{public}s worker=%{public}s hop=%{public}d id=%{public}s',
      job.routeMode, job.origin, job.source, job.workerEpoch === 0 ? 0 : 1, job.id);
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
      'EXP mode=%{public}s origin=%{public}s worker=%{public}s ttft=%{public}d total=%{public}d chars=%{public}d hop=%{public}d err=%{public}s start=%{public}d mem=%{public}d thermal=%{public}d id=%{public}s',
      job.routeMode, job.origin, job.source, ttft, total, job.answer.length,
      job.workerEpoch === 0 ? 0 : 1, job.error ? '1' : '0', job.startedAt, mem, thermal, job.id);
  }

  private startLocal(id: string, messages: ChatMessage[], peer: boolean, epoch: number, image: string = '',
    originLabel: string = '', routeMode: string = ''): string {
    if (this.transport === null && this.model === null) return '模型服务尚未初始化。';
    if (!peer && this.localBusy()) return '模型正在回答上一条问题，请稍后再发。';
    // The rail only streams while one card owns the composer; a second peer request
    // would otherwise stream into whichever card happened to be first.
    if (this.webActiveId.length === 0) this.webActiveId = id;
    if (peer) this.router.beginSelf();
    const key = Index.jobKey(epoch, id);
    const error = this.startModel(key, messages);
    if (error) {
      if (peer) this.router.endSelf();
      if (this.webActiveId === id) this.webActiveId = '';
      return error;
    }
    const job = this.createJob(id, messages, peer, epoch, 0, image, originLabel, routeMode);
    this.jobs.push(job);
    this.logRoute(job);
    hilog.info(0, 'NearbyChat', 'accepted request=%{public}s remote=%{public}s jobs=%{public}d',
      id, String(peer), this.jobs.length);
    if (peer) this.emit({ kind: 'remote-start', text: messages[messages.length - 1].content, requestId: id });
    this.emitDashboard();
    return '';
  }

  private selfEntry(): DeviceInfoEntry {
    const running = this.model === null ? 0 : this.model.activeCount();
    return buildSelfEntry(this.filesDir, this.router.selfLoad(running), '本机', 'self');
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
      node.requests = self.modelRequests === undefined ? 0 : self.modelRequests;
      node.memAvail = self.memAvail === undefined ? -1 : self.memAvail;
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
      node.requests = this.router.workerLoad(peer.epoch, stats?.modelRequests === undefined ? 0 : stats.modelRequests);
      node.memAvail = stats?.memAvail === undefined ? -1 : stats.memAvail;
      nodes.push(node);
    }
    return nodes;
  }

  private scheduleRequest(id: string, messages: ChatMessage[], originEpoch: number, sched: boolean,
    forwardedOrigin: string = ''): string {
    if (sched) return this.startLocal(id, messages, true, originEpoch, '', forwardedOrigin || '聊天设备');
    if (this.channel.selfComputeNumber() !== 1) return '请连接算力设备1，由它统一调度。';
    const nodes = this.scheduleNodes();
    const node = this.chooseNode(nodes, originEpoch);
    if (node === null) {
      if (this.routeMode === 'pin1') return '实验路由找不到算力设备1。';
      if (this.routeMode === 'pin2') return '实验路由找不到算力设备2。';
      return '集群中无已部署模型的可用设备。';
    }
    if (node.isSelf) return this.startLocal(id, messages, true, originEpoch, '', '', this.routeMode);
    const entry = new DispatchEntry();
    entry.originEpoch = originEpoch;
    entry.originRequestId = id;
    entry.workerEpoch = node.epoch;
    entry.workerName = node.name;
    // The forwarded id is ours, not the origin's: the worker echoes it back
    // verbatim and that is the only way to tell two same-id requests apart.
    const dispatch = this.router.beginDispatch(id, entry);
    const job = this.createJob(id, messages, true, originEpoch, node.epoch, '', '', this.routeMode);
    this.jobs.push(job);
    this.logRoute(job);
    this.emitDashboard();
    this.channel.send({
      type: 'request', requestId: dispatch.forwardId, messages: messages, sched: true, origin: job.origin
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
    if (job !== undefined && job.peer && job.epoch === epoch) this.model?.cancel(job.key);
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
    if (message.type === 'delta') {
      const job = this.findJob(id, dispatch.originEpoch);
      if (job === undefined) return;
      job.answer += message.text || '';
      if (job.firstAt === 0) job.firstAt = Date.now();
      this.emitDashboard();
      this.channel.send({ type: 'delta', requestId: id, text: message.text || '' }, dispatch.originEpoch);
      return;
    }
    const job = this.router.finishForward(forwardId) === undefined ? undefined : this.findJob(id, dispatch.originEpoch);
    if (message.type === 'error') {
      this.channel.send({ type: 'error', requestId: id, error: message.error || '执行设备推理失败' },
        dispatch.originEpoch);
      this.completeJob(id, dispatch.originEpoch, message.error || '执行设备推理失败', true);
      return;
    }
    this.channel.send({
      type: 'done', requestId: id, finishReason: message.finishReason,
      source: workerTail(dispatch.workerEpoch, this.channel.peerInfos(), this.selfComputeLabel())
    }, dispatch.originEpoch);
    this.completeJob(id, dispatch.originEpoch, job === undefined ? '' : job.answer, false);
  }

  private handleDeviceInfo(message: WireMessage, epoch: number): void {
    if (message.memUsage !== undefined || message.model !== undefined ||
      message.thermalLevel !== undefined || message.batteryTemp !== undefined ||
      message.cpuUsage !== undefined) {
      let entry = this.peerStats.get(epoch);
      if (entry === undefined) {
        entry = { role: this.channel.peerRole(epoch) || 'compute' };
      }
      applyDeviceInfo(entry, message);
      this.peerStats.set(epoch, entry);
      if (entry.memAvail !== undefined) this.channel.setPeerMem(epoch, entry.memAvail);
      this.emitDashboard();
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
        modelRequests: stats?.modelRequests
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
      id: entry.deviceUid || entry.id, role: entry.role, slot: entry.slot, ready: entry.ready
    }));
    // Publish only self and direct peers. Re-forwarding another compute's roster
    // created a cycle in which a disconnected chat survived forever as a ghost.
    for (const peer of peers) {
      if (!peer.ready) continue;
      // Chat peers neither consume the cluster roster nor supply scheduling
      // metrics. Avoid sending a multi-frame snapshot to every chat phone.
      if (peer.role !== 'compute') continue;
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
            this.channel.send({ type: 'deviceInfo', requestId: 'info-' + String(peer.epoch) }, peer.epoch);
          }
        });
      } else if (!busy) {
        this.channel.send({ type: 'deviceInfo', requestId: 'info-' + String(peer.epoch) }, peer.epoch);
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
    const id = job.id;
    if (update.kind === 'delta') {
      job.answer += update.text;
      if (job.firstAt === 0) job.firstAt = Date.now();
      // requestId lets the page update that one card instead of waiting for the next
      // dashboard poll; without it the rail lagged the reply by up to five seconds.
      if (this.webActiveId === id) this.emit({ kind: 'text', text: job.answer, requestId: id });
      this.emitDashboard();
      if (job.peer) this.channel?.send({ type: 'delta', requestId: id, text: update.text }, job.epoch);
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
          source: workerTail(0, this.channel.peerInfos(), this.selfComputeLabel()) };
      this.channel?.send(message, job.epoch);
      this.router.endSelf();
    } else if (!update.error && update.finishReason !== 'cancelled' &&
      job.question.indexOf('Write only the integers') < 0) {
      this.history.push({ role: 'user', content: job.question });
      this.history.push({ role: 'assistant', content: job.answer });
    }
    hilog.info(0, 'NearbyChat', 'finished request=%{public}s reason=%{public}s', id, update.finishReason || 'error');
    if (this.webActiveId === id) this.webActiveId = '';
    this.completeJob(id, job.epoch, update.text, !!update.error);
  }

  private receive(message: WireMessage, epoch: number): void {
    if (IS_SERVER) {
      if (message.type === 'deviceInfo') {
        this.handleDeviceInfo(message, epoch);
      } else if (message.type === 'deviceInfoSync') {
        this.handleClusterSync(message, epoch);
      } else if (message.type === 'prepare' && message.requestId) {
        const error = this.model?.readinessError() ?? '模型服务尚未初始化。';
        const reply: WireMessage = { type: 'prepared', requestId: message.requestId };
        if (error) reply.error = error;
        this.channel.send(reply, epoch);
        hilog.info(0, 'NearbyChat', 'service prepared request=%{public}s ready=%{public}s',
          message.requestId, String(!error));
        this.replyDeviceInfo(message.requestId, epoch);
      } else if (message.type === 'request' && message.messages && message.requestId) {
        const error = this.scheduleRequest(message.requestId, message.messages, epoch, message.sched === true,
          message.origin || '');
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
      this.jobs.splice(this.jobs.indexOf(job), 1);
      // A reused request id must not evict the earlier card with the same wire id.
      for (let i = this.finishedJobs.length - 1; i >= 0; i--) {
        if (this.finishedJobs[i].key === key) this.finishedJobs.splice(i, 1);
      }
      this.finishedJobs.unshift(job);
      if (this.finishedJobs.length > 8) this.finishedJobs.pop();
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

  private finish(text: string, error: boolean): void {
    this.activeId = '';
    this.emit({ kind: 'done', text: text, error: error });
  }

  private stop(): void {
    if (IS_SERVER) {
      const local = this.jobs.find((item: ActiveJob) => !item.peer);
      if (local !== undefined) this.model?.cancel(local.key);
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
        .javaScriptProxy({ object: this.bridge, name: 'chatBridge', methodList: ['send', 'stop', 'connect', 'prepare', 'pickImage'], controller: this.controller })
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
