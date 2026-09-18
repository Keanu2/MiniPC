import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalChat, ChatUpdate } from '../nearby/LocalChat';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { WireMessage, ChatMessage } from '../nearby/ChatProtocol';
import { IS_SERVER } from '../nearby/NearbyConfig';

interface PageEvent { kind: string; text: string; error?: boolean; available?: boolean; connectLabel?: string; connecting?: boolean; pendingText?: string; }
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
  private activeEpoch: number = 0;
  private peerRequest: boolean = false;
  private answer: string = '';
  private question: string = '';
  private history: ChatMessage[] = [];

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
    if (this.activeId) return Promise.resolve();
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
        await this.channel.computeDevices();
        if (operation !== this.channel.operation() || !this.pageReady) return;
        const ads = this.channel.advertisedComputes();
        if (ads.length === 0) {
          throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
        }
        let index = 0;
        if (this.selectedDeviceId) {
          const found = ads.findIndex(item => item.mac === this.selectedDeviceId);
          if (found >= 0) index = found;
        }
        if (this.connectManual && !this.selectedDeviceId && ads.length > 1) {
          const buttons: [promptAction.Button, promptAction.Button?, promptAction.Button?,
            promptAction.Button?, promptAction.Button?, promptAction.Button?] = [
            { text: '算力 · ' + ads[0].name, color: '#9b5f4c' }
          ];
          for (let i = 1; i < Math.min(ads.length, 6); i++) {
            buttons.push({ text: '算力 · ' + ads[i].name, color: '#9b5f4c' });
          }
          const selection = await this.getUIContext().getPromptAction().showActionMenu({
            title: '选择可用算力设备', buttons: buttons
          });
          index = selection.index;
        }
        if (operation !== this.channel.operation() || !this.pageReady) return;
        if (index < 0 || index >= ads.length) return;
        this.selectedDeviceId = ads[index].mac;
        await this.channel.connectAdvertiser(ads[index].mac, operation);
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

  private showConnection(): void {
    const connected = this.channel?.isConnected() === true;
    const ready = connected && this.serviceReady && this.preparedOperation === this.channel.operation();
    this.emit({ kind: 'connection', text: this.connectionError || (this.connecting ? (this.channel.getStatus() || '正在准备协同…') :
      (!IS_SERVER && ready ? '协同已就绪' : this.channel.getStatus())),
      available: IS_SERVER || ready, pendingText: IS_SERVER ? '正在推理中' : '正在等待推理端回复',
      connectLabel: connected ? '断开' : (IS_SERVER ? '启用近场' : '连接'),
      connecting: this.connecting || this.channel.isConnecting() });
  }

  private connectionChanged(connected: boolean, epoch: number): void {
    hilog.info(0, 'NearbyChat', 'connection=%{public}s epoch=%{public}d server=%{public}s',
      String(connected), epoch, String(IS_SERVER));
    if (connected) this.connectionError = '';
    else this.serviceReady = false;
    if (!connected && this.activeId) {
      if (!IS_SERVER) this.finish(this.answer + (this.answer ? '\n\n' : '') + '连接已中断，请连接后重新发送。', true);
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

  private send(text: string): string {
    if (typeof text !== 'string' || !text.trim()) return '请输入问题。';
    if (text.length > 1000) return '这条消息太长，请缩短后再发送。';
    if (this.activeId || this.model?.isBusy()) return '模型正在回答上一条问题，请稍后再发。';
    if (!IS_SERVER && (!this.channel.isConnected() || !this.serviceReady ||
      this.preparedOperation !== this.channel.operation())) {
      this.ensureCollaborationReady();
      return '协同尚未准备完成，请就绪后发送。';
    }
    const question = text.trim();
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

  private startLocal(id: string, messages: ChatMessage[], peer: boolean, epoch: number): string {
    if (this.activeId || !this.model || this.model.isBusy()) return '模型正在回答上一条问题，请稍后再发。';
    const error = this.model.start(messages, (update: ChatUpdate) => this.localUpdate(id, update));
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

  private receive(message: WireMessage, epoch: number): void {
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
        (this.answer || '模型没有返回内容，请重试。'), !stopped && !this.answer);
    } else if (message.type === 'error') {
      const capacity = (message.error || '').indexOf('两路推理') >= 0;
      if (!capacity) {
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
    if (IS_SERVER) this.model?.cancel();
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
