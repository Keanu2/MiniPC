import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalChat, ChatUpdate } from '../nearby/LocalChat';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { WireMessage, ChatMessage } from '../nearby/ChatProtocol';
import { IS_SERVER } from '../nearby/NearbyConfig';

interface PageEvent {
  kind: string;
  text: string;
  error?: boolean;
  available?: boolean;
  connectLabel?: string;
  connecting?: boolean;
  pendingText?: string;
  requestId?: string;
  running?: number;
  devices?: DeviceView[];
  jobs?: JobView[];
}
interface DeviceView {
  epoch: number;
  name: string;
  id: string;
  ready: boolean;
  jobs: number;
}
interface JobView {
  id: string;
  source: string;
  question: string;
  answer: string;
  chars: number;
  startedAt: number;
  firstAt: number;
  endedAt: number;
  running: boolean;
  error: boolean;
  elapsedMs: number;
}
interface ActiveJob {
  id: string;
  epoch: number;
  peer: boolean;
  answer: string;
  question: string;
  startedAt: number;
  firstAt: number;
  endedAt: number;
  error: boolean;
  source: string;
}
class ChatBridge {
  private onSend: (text: string) => string;
  private onStop: () => void;
  private onConnect: () => void;
  private onPrepare: () => void;
  constructor(send: (text: string) => string, stop: () => void, connect: () => void, prepare: () => void) {
    this.onSend = send; this.onStop = stop; this.onConnect = connect; this.onPrepare = prepare;
  }
  send(text: string): string { return this.onSend(text); }
  stop(): void { this.onStop(); }
  connect(): void { this.onConnect(); }
  prepare(): void { this.onPrepare(); }
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
    });
  private channel = nearbyChannel;
  private connecting: boolean = false;
  private preparation: Promise<void> | null = null;
  private serviceReady: boolean = false;
  private preparedOperation: number = -1;
  private selectedDeviceId: string = '';
  private autoConnect: boolean = true;
  private connectManual: boolean = false;
  private model: LocalChat | null = null;
  private pageReady: boolean = false;
  private connectionError: string = '';
  private activeId: string = '';
  private answer: string = '';
  private question: string = '';
  private jobs: ActiveJob[] = [];
  private finishedJobs: ActiveJob[] = [];
  private history: ChatMessage[] = [];
  private pendingB: ChatMessage[] | null = null;
  private pendingBId: string = '';
  private overlapArmed: boolean = false;

  aboutToAppear(): void {
    if (IS_SERVER) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.model = new LocalChat(context.getApplicationContext().filesDir);
    }
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.model?.close();
    this.channel.disconnect();
    this.channel.unsubscribe();
  }

  onPageShow(): void {
    if (this.pageReady && this.autoConnect) this.ensureCollaborationReady(this.connectManual);
  }

  private connectNearby(): void {
    if (this.preparation !== null) return;
    if (this.channel.isConnected()) {
      this.autoConnect = false;
      this.channel.disconnect();
      this.showConnection();
      return;
    }
    this.autoConnect = true;
    this.ensureCollaborationReady(true);
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
        this.serviceReady = true;
        this.preparedOperation = operation;
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

  private emit(event: PageEvent): void {
    if (!this.pageReady) return;
    this.controller.runJavaScript('window.onNativeEvent(' + JSON.stringify(event) + ')').catch(() => this.stop());
  }

  private jobSource(peer: boolean, epoch: number): string {
    if (!peer) return '本机';
    const peers = this.channel.peerInfos();
    for (const info of peers) {
      if (info.epoch === epoch) return info.name;
    }
    return '聊天设备';
  }

  private createJob(id: string, messages: ChatMessage[], peer: boolean, epoch: number): ActiveJob {
    return {
      id: id, epoch: epoch, peer: peer, answer: '', question: messages[messages.length - 1].content,
      startedAt: Date.now(), firstAt: 0, endedAt: 0, error: false, source: this.jobSource(peer, epoch)
    };
  }

  private toJobView(job: ActiveJob, now: number): JobView {
    const ended = job.endedAt > 0;
    const elapsed = (ended ? job.endedAt : now) - job.startedAt;
    return {
      id: job.id, source: job.source, question: job.question, answer: job.answer,
      chars: job.answer.length, startedAt: job.startedAt, firstAt: job.firstAt,
      endedAt: job.endedAt, running: !ended, error: job.error,
      elapsedMs: elapsed < 0 ? 0 : elapsed
    };
  }

  private emitDashboard(): void {
    if (!IS_SERVER || !this.pageReady) return;
    const now = Date.now();
    const peers = this.channel.peerInfos();
    const devices: DeviceView[] = [];
    for (const peer of peers) {
      let count = 0;
      for (const job of this.jobs) {
        if (job.peer && job.epoch === peer.epoch) count++;
      }
      devices.push({ epoch: peer.epoch, name: peer.name, id: peer.peerId, ready: peer.ready, jobs: count });
    }
    const views: JobView[] = [];
    for (const job of this.jobs) views.push(this.toJobView(job, now));
    for (const job of this.finishedJobs) views.push(this.toJobView(job, now));
    this.emit({
      kind: 'dashboard',
      text: this.connectionError || this.channel.getStatus(),
      available: true,
      connectLabel: this.serviceReady ? '停用近场' : '启用近场',
      connecting: this.connecting || this.channel.isConnecting(),
      running: this.jobs.length,
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
      connectLabel: connected ? '断开' : (IS_SERVER ? '启用近场' : '连接'),
      connecting: this.connecting || this.channel.isConnecting() });
    if (IS_SERVER) this.emitDashboard();
  }

  private connectionChanged(connected: boolean, epoch: number): void {
    hilog.info(0, 'NearbyChat', 'connection=%{public}s epoch=%{public}d peers=%{public}d server=%{public}s',
      String(connected), epoch, this.channel.connectedCount(), String(IS_SERVER));
    if (this.channel.isConnected()) this.connectionError = '';
    if (!IS_SERVER && !connected) this.serviceReady = false;
    if (IS_SERVER) this.cancelDroppedPeers();
    else if (!connected && this.activeId) {
      this.finish(this.answer + (this.answer ? '\n\n' : '') + '连接已中断，请连接后重新发送。', true);
    }
    this.showConnection();
  }

  private cancelDroppedPeers(): void {
    for (const job of this.jobs.slice()) {
      if (job.peer && !this.channel.hasEpoch(job.epoch)) this.model?.cancel(job.id);
    }
  }

  private findJob(id: string): ActiveJob | undefined {
    return this.jobs.find((item: ActiveJob) => item.id === id);
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

  private send(text: string): string {
    if (typeof text !== 'string' || !text.trim()) return '请输入问题。';
    if (text.length > 1000) return '这条消息太长，请缩短后再发送。';
    const question = text.trim();
    if (IS_SERVER) {
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
      const error = this.startLocal(id, messages, false, 0);
      if (error) return error;
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

  private queueJob(id: string, messages: ChatMessage[]): string {
    if (!this.model) return '模型服务尚未初始化。';
    const error = this.model.start(messages, (update: ChatUpdate) => this.localUpdate(id, update), id);
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

  private startLocal(id: string, messages: ChatMessage[], peer: boolean, epoch: number): string {
    if (!this.model) return '模型服务尚未初始化。';
    if (!peer && this.localBusy()) return '模型正在回答上一条问题，请稍后再发。';
    const error = this.model.start(messages, (update: ChatUpdate) => this.localUpdate(id, update), id);
    if (error) return error;
    this.jobs.push(this.createJob(id, messages, peer, epoch));
    hilog.info(0, 'NearbyChat', 'accepted request=%{public}s remote=%{public}s jobs=%{public}d',
      id, String(peer), this.jobs.length);
    if (peer) this.emit({ kind: 'remote-start', text: messages[messages.length - 1].content, requestId: id });
    this.emitDashboard();
    return '';
  }

  private localUpdate(id: string, update: ChatUpdate): void {
    const job = this.findJob(id);
    if (job === undefined) return;
    if (update.kind === 'delta') {
      job.answer += update.text;
      if (job.firstAt === 0) job.firstAt = Date.now();
      this.emit({ kind: 'text', text: job.answer, requestId: id });
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
        { type: 'done', requestId: id, finishReason: update.finishReason };
      this.channel?.send(message, job.epoch);
    } else if (!update.error && update.finishReason !== 'cancelled' &&
      job.question.indexOf('Write only the integers') < 0) {
      this.history.push({ role: 'user', content: job.question });
      this.history.push({ role: 'assistant', content: job.answer });
    }
    hilog.info(0, 'NearbyChat', 'finished request=%{public}s reason=%{public}s', id, update.finishReason || 'error');
    this.completeJob(id, update.text, !!update.error);
  }

  private receive(message: WireMessage, epoch: number): void {
    if (IS_SERVER) {
      if (message.type === 'prepare' && message.requestId) {
        const error = this.model?.readinessError() ?? '模型服务尚未初始化。';
        const reply: WireMessage = { type: 'prepared', requestId: message.requestId };
        if (error) reply.error = error;
        this.channel.send(reply, epoch);
        hilog.info(0, 'NearbyChat', 'service prepared request=%{public}s ready=%{public}s',
          message.requestId, String(!error));
      } else if (message.type === 'request' && message.messages && message.requestId) {
        const error = this.startLocal(message.requestId, message.messages, true, epoch);
        if (error) this.channel?.send({ type: 'error', requestId: message.requestId, error: error }, epoch);
      } else if (message.type === 'cancel' && message.requestId) {
        const job = this.findJob(message.requestId);
        if (job !== undefined && job.peer && job.epoch === epoch) this.model?.cancel(message.requestId);
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

  private completeJob(id: string, text: string, error: boolean): void {
    const job = this.findJob(id);
    if (job !== undefined) {
      job.endedAt = Date.now();
      job.error = error;
      if (text && job.answer.length === 0) job.answer = text;
      this.jobs.splice(this.jobs.indexOf(job), 1);
      this.finishedJobs.unshift(job);
      if (this.finishedJobs.length > 8) this.finishedJobs.pop();
    }
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
      if (local !== undefined) this.model?.cancel(local.id);
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
        .javaScriptProxy({ object: this.bridge, name: 'chatBridge', methodList: ['send', 'stop', 'connect', 'prepare'], controller: this.controller })
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
