import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalChat, ChatUpdate } from '../llm/LocalChat';
import { LocalLlmTransport } from '../llm/LlmTransport';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { WireMessage, ChatMessage, DeviceInfoEntry } from '../protocol/ChatProtocol';
import { buildSelfEntry, toDeviceInfoReply } from '../cluster/DeviceInfo';
import { IS_SERVER } from '../nearby/NearbyConfig';
import { pickJpegDataUrl } from '../media/ImageAttach';
import { ChatBridge } from '../ui/ChatBridge';

interface PageEvent { kind: string; text: string; error?: boolean; available?: boolean; connectLabel?: string; connecting?: boolean; pendingText?: string; selfLabel?: string; }

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
  private autoConnect: boolean = true;
  private connectManual: boolean = false;
  private reconnectTimer: number = -1;
  private reconnectAttempt: number = 0;
  private model: LocalChat | null = null;
  private transport: LocalLlmTransport | null = null;
  private pageReady: boolean = false;
  private connectionError: string = '';
  private activeId: string = '';
  private activeEpoch: number = 0;
  private peerRequest: boolean = false;
  private answer: string = '';
  private question: string = '';
  private history: ChatMessage[] = [];

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.model = new LocalChat(context.getApplicationContext().filesDir);
    this.transport = new LocalLlmTransport(this.model);
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.cancelReconnect();
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
      this.cancelReconnect();
      this.channel.disconnect();
      this.showConnection();
      return;
    }
    this.autoConnect = true;
    this.reconnectAttempt = 0;
    this.ensureCollaborationReady(true);
  }

  private ensureCollaborationReady(manual: boolean = false): Promise<void> {
    if (this.activeId) return Promise.resolve();
    if (this.preparation !== null) return this.preparation;
    if (IS_SERVER && this.preparedOperation === this.channel.operation() && this.serviceReady) {
      return Promise.resolve();
    }
    if (!IS_SERVER && this.serviceReady && this.channel.isConnected() && this.preparedOperation === this.channel.operation()) {
      return Promise.resolve();
    }
    this.cancelReconnect();
    if (manual) this.reconnectAttempt = 0;
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
        await this.channel.computeDevices();
        if (operation !== this.channel.operation() || !this.pageReady) return;
        let ads = this.channel.advertisedComputes();
        if (ads.length === 0) {
          throw new Error(this.channel.hasComputeHits()
            ? '附近的算力还没组网。请用同一华为账号在超级终端中连接后再试。'
            : '未发现算力设备。请打开模型手机并保持近场开启后重试。');
        }
        ads = this.channel.connectComputes();
        if (ads.length === 0) {
          throw new Error('算力设备1尚未确定或不可用，请等待算力设备组网后重试。');
        }
        if (operation !== this.channel.operation() || !this.pageReady) return;
        let linked = false;
        let lastError: Error | null = null;
        for (let attempt = 0; attempt < 3 && !linked; attempt++) {
          if (attempt > 0) {
            await this.delay(1500);
            if (operation !== this.channel.operation() || !this.pageReady) return;
            await this.channel.computeDevices();
            if (operation !== this.channel.operation() || !this.pageReady) return;
            ads = this.channel.connectComputes();
            if (ads.length === 0) {
              lastError = new Error('算力设备1尚未确定或不可用，请等待算力设备组网后重试。');
              continue;
            }
          }
          try {
            await this.channel.connectAdvertiser(ads[0].mac, operation);
            linked = true;
          } catch (error) {
            lastError = error instanceof Error ? error : new Error('增强连接失败。');
          }
        }
        if (!linked) throw (lastError || new Error('增强连接失败：未找到可用的蓝牙地址。'));
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
      if (!IS_SERVER && !this.channel.isConnected()) this.scheduleReconnect();
    }
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer === -1) return;
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = -1;
  }

  /** Give a newly elected hub time to appear, but keep retries bounded. */
  private scheduleReconnect(): void {
    if (IS_SERVER || !this.autoConnect || !this.pageReady || !this.channel.isForeground() ||
      this.activeId.length > 0 || this.preparation !== null || this.reconnectTimer !== -1) return;
    const delays: number[] = [1500, 4000, 9000, 15000, 20000];
    if (this.reconnectAttempt >= delays.length) {
      this.autoConnect = false;
      this.connectionError = '连接已中断，请点击“连接”重试。';
      this.showConnection();
      return;
    }
    const delay = delays[this.reconnectAttempt++];
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      if (!this.channel.isConnected() && this.autoConnect && this.pageReady &&
        this.channel.isForeground() && this.preparation === null && !this.activeId) {
        this.ensureCollaborationReady(false);
      }
    }, delay);
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
  }

  private emit(event: PageEvent): void {
    if (!this.pageReady) return;
    this.controller.runJavaScript('window.onNativeEvent(' + JSON.stringify(event) + ')').catch(() => this.stop());
  }

  private hasLocalModel(): boolean {
    return this.model !== null && this.model.hasModel();
  }

  private showConnection(): void {
    const connected = this.channel?.isConnected() === true;
    const ready = connected && this.serviceReady && this.preparedOperation === this.channel.operation();
    const local = this.hasLocalModel();
    const text = this.connectionError || (this.connecting ? (this.channel.getStatus() || '正在准备协同…') :
      (local && !connected ? '本机模型已就绪' : (!IS_SERVER && ready ? '协同已就绪' : this.channel.getStatus())));
    this.emit({ kind: 'connection', text: text,
      available: local || IS_SERVER || ready, pendingText: local ? '正在推理中' : '正在等待推理端回复',
      connectLabel: connected ? '断开' : (IS_SERVER ? '启用近场' : '连接'),
      connecting: this.connecting || this.channel.isConnecting(),
      selfLabel: this.channel.selfLabel() });
  }

  private connectionChanged(connected: boolean, epoch: number): void {
    hilog.info(0, 'NearbyChat', 'connection=%{public}s epoch=%{public}d server=%{public}s',
      String(connected), epoch, String(IS_SERVER));
    if (connected) {
      this.connectionError = '';
      this.cancelReconnect();
      this.reconnectAttempt = 0;
    } else {
      this.serviceReady = false;
      this.scheduleReconnect();
    }
    if (!connected && this.activeId) {
      if (this.hasLocalModel() && !this.peerRequest) return this.showConnection();
      if (!IS_SERVER) {
        this.finish(this.answer + (this.answer ? '\n\n' : '') + '连接已中断，请连接后重新发送。', true);
        this.scheduleReconnect();
      }
      else if (this.peerRequest && this.activeEpoch === epoch) this.model?.cancel();
    }
    this.showConnection();
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
    if (this.activeId) return;
    pickJpegDataUrl().then((dataUrl: string) => {
      if (dataUrl.length === 0) return;
      this.emit({ kind: 'image', text: dataUrl });
    }).catch(() => {
      this.emit({ kind: 'image-error', text: '图片读取失败，请重试。' });
    });
  }

  private send(text: string): string {
    if (typeof text !== 'string' || !text.trim()) return '请输入问题。';
    if (text.length > 1100) return '这条消息太长，请缩短后再发送。';
    if (this.activeId || this.model?.isBusy()) return '模型正在回答上一条问题，请稍后再发。';
    const useLocal = this.hasLocalModel() && !this.channel.isConnected();
    if (!useLocal && !IS_SERVER && (!this.channel.isConnected() || !this.serviceReady ||
      this.preparedOperation !== this.channel.operation())) {
      this.ensureCollaborationReady();
      return '协同尚未准备完成，请就绪后发送。';
    }
    const question = text.trim();
    const messages = this.recentMessages(question);
    const id = util.generateRandomUUID();
    if (IS_SERVER || useLocal) {
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

  private startLocal(id: string, messages: ChatMessage[], peer: boolean, epoch: number): string {
    if (this.activeId || !this.model || this.model.isBusy()) return '模型正在回答上一条问题，请稍后再发。';
    const error = this.transport !== null ?
      this.transport.start(messages, (update: ChatUpdate) => this.localUpdate(id, update)) :
      this.model.start(messages, (update: ChatUpdate) => this.localUpdate(id, update));
    if (error) return error;
    this.activeId = id; this.activeEpoch = epoch; this.peerRequest = peer;
    this.answer = ''; this.question = messages[messages.length - 1].content;
    hilog.info(0, 'NearbyChat', 'accepted request=%{public}s remote=%{public}s', id, String(peer));
    if (peer) this.emit({ kind: 'remote-start', text: this.question });
    return '';
  }

  private localUpdate(id: string, update: ChatUpdate): void {
    if (this.activeId !== id) return;
    if (update.kind === 'delta') {
      this.answer += update.text;
      this.emit({ kind: 'text', text: this.answer });
      if (this.peerRequest) this.channel?.send({ type: 'delta', requestId: id, text: update.text }, this.activeEpoch);
      return;
    }
    if (this.peerRequest) {
      const message: WireMessage = update.error ? { type: 'error', requestId: id, error: update.error } :
        { type: 'done', requestId: id, finishReason: update.finishReason };
      this.channel?.send(message, this.activeEpoch);
    }
    if (!this.peerRequest && !update.error && update.finishReason !== 'cancelled') this.remember();
    hilog.info(0, 'NearbyChat', 'finished request=%{public}s reason=%{public}s', id, update.finishReason || 'error');
    this.finish(update.text, !!update.error);
  }

  private selfEntry(): DeviceInfoEntry {
    const running = this.model !== null && this.model.isBusy() ? 1 : 0;
    return buildSelfEntry(this.hasLocalModel(), running, '本机', 'self');
  }

  private replyDeviceInfo(requestId: string, epoch: number): void {
    this.channel.send(toDeviceInfoReply(requestId, this.selfEntry()), epoch);
  }

  private receive(message: WireMessage, epoch: number): void {
    if (message.type === 'deviceInfo') {
      if (message.requestId && message.memUsage === undefined && message.model === undefined) {
        this.replyDeviceInfo(message.requestId, epoch);
      }
      return;
    }
    if (message.type === 'deviceInfoSync') return;
    if (IS_SERVER) {
      if (message.type === 'prepare' && message.requestId) {
        const error = this.activeId ? '模型正在回答，请稍后点击输入框重试。' :
          (this.model?.readinessError() ?? '模型服务尚未初始化。');
        const reply: WireMessage = { type: 'prepared', requestId: message.requestId };
        if (error) reply.error = error;
        this.channel.send(reply, epoch);
        hilog.info(0, 'NearbyChat', 'service prepared request=%{public}s ready=%{public}s', message.requestId, String(!error));
      } else if (message.type === 'request' && message.messages && message.requestId) {
        const error = this.startLocal(message.requestId, message.messages, true, epoch);
        if (error) this.channel?.send({ type: 'error', requestId: message.requestId, error: error }, epoch);
      } else if (message.type === 'cancel' && this.peerRequest && message.requestId === this.activeId && epoch === this.activeEpoch) {
        this.model?.cancel();
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
        ((this.answer || '模型没有返回内容，请重试。') +
          (message.source && message.source.length > 0 ? '\n\n' + message.source : '')),
        !stopped && !this.answer);
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

  private finish(text: string, error: boolean): void {
    this.activeId = ''; this.peerRequest = false;
    this.emit({ kind: 'done', text: text, error: error });
  }

  private stop(): void {
    if (!this.activeId) return;
    if (IS_SERVER || this.hasLocalModel()) this.model?.cancel();
    else {
      const id = this.activeId;
      this.channel?.send({ type: 'cancel', requestId: id }).then((sent: boolean) => {
        if (!sent && this.activeId === id) this.finish('连接已中断，停止请求未送达。', true);
      });
    }
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
