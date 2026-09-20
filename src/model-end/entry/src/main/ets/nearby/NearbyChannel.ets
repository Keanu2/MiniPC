import { abilityConnectionManager as acm, distributedDeviceManager as dm } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { encodeMessage, MessageAssembler, WireMessage } from '../protocol/ChatProtocol';
import { IS_SERVER } from './NearbyConfig';

const BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-chat';
/** recv = 在收到 hello 的那条会话上回；pending = 在新建的那条会话上回。实验用。 */
const EXTRA_HELLO_ACK: string = 'pending';

function connectFailure(code?: number): string {
  const reasons: string[] = ['已存在协同会话', '模型手机拒绝连接', '聊天手机的Wi-Fi未开启',
    '模型手机近场链路冲突或Wi-Fi不可用，请关闭个人热点后重试', '模型手机缺少协同入口', '系统协同服务内部错误'];
  return '连接失败：' + (code !== undefined && code >= 0 && code < reasons.length ? reasons[code] : '未知原因') +
    '（' + String(code) + '）。';
}

class Peer {
  epoch: number;
  sessionId: number;
  deviceId: string;
  ready: boolean = false;
  opened: boolean = false;
  hello: boolean = false;
  pending: number = 0;
  sequence: number = 0;
  timer: number = -1;
  fragmentTimer: number = -1;
  writes: Promise<boolean> = Promise.resolve(true);
  assembler: MessageAssembler = new MessageAssembler();
  ended: Promise<void>;
  connectionReady: Promise<boolean>;
  settleConnection: (ready: boolean) => void = () => {};
  serviceCheck: Promise<string> | null = null;
  serviceReply: ((error: string) => void) | null = null;
  serviceId: string = '';
  serviceTimer: number = -1;
  end: () => void = () => {};
  constructor(sessionId: number, epoch: number, deviceId: string) {
    this.sessionId = sessionId; this.epoch = epoch; this.deviceId = deviceId;
    this.ended = new Promise<void>(resolve => { this.end = resolve; });
    this.connectionReady = new Promise<boolean>(resolve => { this.settleConnection = resolve; });
  }
}

/** Ability-owned text session. No IP socket or automatic remote relaunch. */
export class NearbyChannel {
  private context: common.UIAbilityContext | null = null;
  private manager: dm.DeviceManager | null = null;
  private peers: Peer[] = [];
  private epoch: number = 0;
  private lifecycle: number = 0;
  private foreground: boolean = true;
  private permissionPending: Promise<void> | null = null;
  private onMessage: ((message: WireMessage, epoch: number) => void) | null = null;
  private onConnection: ((connected: boolean, epoch: number) => void) | null = null;
  private status: string = IS_SERVER ? '可本机对话 · 请启用近场连接' : '请连接模型手机';

  initialize(context: common.UIAbilityContext): void { this.context = context; }
  operation(): number { return this.lifecycle; }
  resume(): void { this.foreground = true; }
  suspend(): void { this.foreground = false; this.disconnect(); }
  private checkOperation(operation: number): void {
    if (!this.foreground || operation !== this.lifecycle || this.context === null) {
      throw new Error('连接操作已取消，请回到应用后重试。');
    }
  }
  isConnected(): boolean { return this.peers.some((item: Peer) => item.ready); }
  isConnecting(): boolean { return this.peers.some((item: Peer) => !item.ready); }
  connectedCount(): number { return this.peers.filter((item: Peer) => item.ready).length; }
  getStatus(): string { return this.status; }
  waitUntilConnected(): Promise<boolean> {
    const pending = this.peers.find((item: Peer) => !item.ready);
    const ready = this.peers.find((item: Peer) => item.ready);
    return (pending || ready)?.connectionReady || Promise.resolve(false);
  }

  checkService(): Promise<string> {
    const peer = this.peers.find((item: Peer) => item.ready);
    if (peer === undefined) return Promise.resolve('近场连接尚未完成。');
    if (peer.serviceCheck !== null) return peer.serviceCheck;
    peer.serviceId = 'prepare-' + String(peer.epoch) + '-' + String(++peer.sequence);
    const requestId = peer.serviceId;
    peer.serviceCheck = new Promise<string>(resolve => { peer.serviceReply = resolve; });
    const result = peer.serviceCheck;
    peer.serviceTimer = setTimeout(() => {
      if (peer.serviceId === requestId) this.completeServiceCheck(peer, '协同准备超时，请点击输入框重试。');
    }, 5000);
    this.send({ type: 'prepare', requestId: requestId }, peer.epoch).then(sent => {
      if (!sent && peer.serviceId === requestId) this.completeServiceCheck(peer, '协同准备发送失败，请重新连接。');
    });
    return result;
  }

  private completeServiceCheck(peer: Peer, error: string): void {
    clearTimeout(peer.serviceTimer);
    const reply = peer.serviceReply;
    peer.serviceReply = null;
    peer.serviceCheck = null;
    peer.serviceId = '';
    reply?.(error);
  }

  subscribe(message: (message: WireMessage, epoch: number) => void,
    connection: (connected: boolean, epoch: number) => void): void {
    this.onMessage = message;
    this.onConnection = connection;
    connection(this.isConnected(), this.epoch);
    for (const peer of this.peers) {
      if (peer.hello && IS_SERVER) this.acknowledge(peer);
    }
  }

  unsubscribe(): void { this.onMessage = null; this.onConnection = null; }

  async prepare(): Promise<void> {
    if (this.permissionPending !== null) return this.permissionPending;
    const context = this.context;
    if (context === null) throw new Error('应用尚未就绪。');
    this.permissionPending = this.authorize(context);
    try { await this.permissionPending; } finally { this.permissionPending = null; }
  }

  private async authorize(context: common.UIAbilityContext): Promise<void> {
    const operation = this.lifecycle;
    this.checkOperation(operation);
    const access = abilityAccessCtrl.createAtManager();
    if (access.verifyAccessTokenSync(context.applicationInfo.accessTokenId,
      'ohos.permission.DISTRIBUTED_DATASYNC') !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      const result = await access.requestPermissionsFromUser(context, ['ohos.permission.DISTRIBUTED_DATASYNC']);
      if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
        throw new Error('请在设置中允许附近设备权限，再点击连接。');
      }
    }
    this.checkOperation(operation);
    if (this.context !== context) throw new Error('应用已关闭。');
    if (this.manager === null) this.manager = dm.createDeviceManager(BUNDLE);
    if (this.peers.length === 0) this.refreshStatus();
  }

  async devices(): Promise<dm.DeviceBasicInfo[]> {
    await this.prepare();
    const devices = this.manager!.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
      typeof device.networkId === 'string' && device.networkId.length > 0);
    hilog.info(0, 'NearbyChat', 'available devices=%{public}d', devices.length);
    return devices;
  }

  async connect(networkId: string, operation: number = this.lifecycle): Promise<void> {
    if (IS_SERVER || this.peers.length > 0) return;
    this.checkOperation(operation);
    const devices = await this.devices();
    this.checkOperation(operation);
    if (this.peers.length > 0) return;
    if (!devices.some((device: dm.DeviceBasicInfo) => device.networkId === networkId)) {
      throw new Error('设备已离线，请检查同账号、Wi-Fi和蓝牙后重试。');
    }
    const info: acm.PeerInfo = { deviceId: networkId, bundleName: BUNDLE,
      moduleName: 'entry', abilityName: 'EntryAbility' };
    const options: acm.ConnectOptions = { needSendData: true,
      startOptions: acm.StartOptionParams.START_IN_FOREGROUND };
    const peer = this.attach(acm.createAbilityConnectionSession(SERVICE, this.context!, info, options), networkId);
    const attempt = async (): Promise<void> => {
      try {
        const result = await acm.connect(peer.sessionId);
        hilog.info(0, 'NearbyChat', 'connect result epoch=%{public}d connected=%{public}s code=%{public}s',
          peer.epoch, String(result.isConnected), String(result.errorCode));
        if (!result.isConnected) {
          this.connectionFailed(peer, operation, connectFailure(result.errorCode));
        } else if (this.holds(peer)) { this.opened(peer); }
      } catch (error) {
        const code = (error as BusinessError).code;
        hilog.error(0, 'NearbyChat', 'connect API failed epoch=%{public}d code=%{public}s', peer.epoch, String(code));
        this.connectionFailed(peer, operation, '连接接口失败（' + String(code) + '），请检查权限后重试。');
      }
    };
    await Promise.race([attempt(), peer.ended]);
  }

  private connectionFailed(peer: Peer, operation: number, status: string): void {
    if (this.holds(peer)) this.drop(peer, status);
    else if (this.peers.length === 0 && this.epoch === peer.epoch && this.lifecycle === operation && this.foreground) {
      this.status = status;
      this.onConnection?.(false, peer.epoch);
    }
  }

  accept(parameters: Record<string, Object>): boolean {
    if (!IS_SERVER || this.context === null) return this.reject('role/context');
    const access = abilityAccessCtrl.createAtManager();
    if (access.verifyAccessTokenSync(this.context.applicationInfo.accessTokenId,
      'ohos.permission.DISTRIBUTED_DATASYNC') !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) return this.reject('permission');
    try {
      const info = parameters['PeerInfo'] as acm.PeerInfo;
      const token = parameters['ohos.dms.collabToken'] as string;
      if (!info || info.bundleName !== BUNDLE || info.moduleName !== 'entry' ||
        info.abilityName !== 'EntryAbility' || typeof info.deviceId !== 'string' ||
        typeof token !== 'string' || token.length === 0) return this.reject('peer-fields/token');
      if (this.manager === null) this.manager = dm.createDeviceManager(BUNDLE);
      if (!this.manager.getAvailableDeviceListSync().some((device: dm.DeviceBasicInfo) =>
        device.networkId === info.deviceId)) return this.reject('trusted-peer');
      const existing = this.peers.find((item: Peer) => item.deviceId === info.deviceId);
      if (existing !== undefined) this.drop(existing, '对端重新连接。');
      const options: acm.ConnectOptions = { needSendData: true,
        startOptions: acm.StartOptionParams.START_IN_FOREGROUND };
      const serviceName = SERVICE + '-' + info.deviceId.substring(0, 8);
      const peer = this.attach(acm.createAbilityConnectionSession(serviceName, this.context, info, options),
        info.deviceId);
      hilog.info(0, 'NearbyChat', 'accept begin epoch=%{public}d session=%{public}d service=%{public}s peers=%{public}d',
        peer.epoch, peer.sessionId, serviceName, this.peers.length);
      try {
        acm.acceptConnect(peer.sessionId, token).then(() => {
          hilog.info(0, 'NearbyChat', 'accept completed epoch=%{public}d', peer.epoch);
        }).catch((error: BusinessError) => {
          hilog.error(0, 'NearbyChat', 'accept failed code=%{public}s', String(error.code));
          this.drop(peer, '接收连接失败（' + String(error.code) + '），请重新连接。');
        });
      } catch (_) { this.drop(peer, '接收连接失败，请重新连接。'); return false; }
      return true;
    } catch (error) {
      hilog.error(0, 'NearbyChat', 'accept exception code=%{public}s', String((error as BusinessError).code));
      return this.reject('exception');
    }
  }

  private reject(stage: string): boolean {
    hilog.warn(0, 'NearbyChat', 'collaborate rejected stage=%{public}s', stage);
    return false;
  }

  private holds(peer: Peer): boolean {
    return this.peers.some((item: Peer) => item.epoch === peer.epoch);
  }

  private attach(sessionId: number, deviceId: string): Peer {
    const peer = new Peer(sessionId, ++this.epoch, deviceId);
    this.peers.push(peer);
    try {
      acm.on('connect', sessionId, (event: acm.EventCallbackInfo) => {
        if (event.sessionId === sessionId) this.opened(peer);
      });
      acm.on('disconnect', sessionId, (event: acm.EventCallbackInfo) => {
        hilog.info(0, 'NearbyChat', 'disconnect event epoch=%{public}d reason=%{public}s', peer.epoch, String(event.reason));
        if (event.sessionId === sessionId) this.drop(peer, '连接已断开（原因' + String(event.reason) + '），请重新连接。');
      });
      acm.on('receiveMessage', sessionId, (event: acm.EventCallbackInfo) => {
        hilog.info(0, 'NearbyChat', 'recv-cb listen=%{public}d eventSession=%{public}s epoch=%{public}d',
          sessionId, String(event.sessionId), peer.epoch);
        if (!this.holds(peer) || event.sessionId !== sessionId) return;
        try {
          if (typeof event.msg !== 'string') throw new Error('Invalid message');
          const message = peer.assembler.receive(event.msg);
          if (message !== null) {
            hilog.info(0, 'NearbyChat', 'recv-msg type=%{public}s epoch=%{public}d session=%{public}d ready=%{public}s',
              message.type, peer.epoch, sessionId, String(peer.ready));
            this.receive(peer, message);
          }
        } catch (_) { this.drop(peer, '收到无效消息，连接已结束。'); }
      });
      peer.timer = setTimeout(() => this.drop(peer, '连接超时，请确认两端应用在前台后重试。'), 20000);
      peer.fragmentTimer = setInterval(() => {
        try { peer.assembler.checkExpiry(); }
        catch (_) { this.drop(peer, '消息传输中断，请重新连接。'); }
      }, 1000);
      this.refreshStatus();
      this.onConnection?.(this.isConnected(), peer.epoch);
      return peer;
    } catch (error) {
      this.drop(peer, '无法创建近场连接。');
      throw new Error('无法注册近场会话事件。');
    }
  }

  private opened(peer: Peer): void {
    if (!this.holds(peer) || peer.opened) return;
    peer.opened = true;
    hilog.info(0, 'NearbyChat', 'session opened epoch=%{public}d session=%{public}d', peer.epoch, peer.sessionId);
    if (!IS_SERVER) this.write(peer, { type: 'hello' });
  }

  private receive(peer: Peer, message: WireMessage): void {
    if (!this.holds(peer)) return;
    if (!peer.ready) {
      if (IS_SERVER && message.type === 'hello' && !peer.hello) {
        peer.hello = true;
        if (this.onMessage !== null) this.acknowledge(peer);
      } else if (!IS_SERVER && message.type === 'hello_ack' && peer.opened) {
        this.ready(peer);
      } else { this.drop(peer, '对端不是兼容的聊天应用。'); }
      return;
    }
    if (!IS_SERVER && message.type === 'prepared') {
      if (message.requestId === peer.serviceId) this.completeServiceCheck(peer, message.error || '');
      return;
    }
    if (IS_SERVER && message.type === 'hello') {
      const pending = this.peers.find((item: Peer) => !item.ready);
      hilog.warn(0, 'NearbyChat', 'extra-hello on epoch=%{public}d session=%{public}d pendingEpoch=%{public}s ack=%{public}s',
        peer.epoch, peer.sessionId, pending === undefined ? 'none' : String(pending.epoch), EXTRA_HELLO_ACK);
      if (EXTRA_HELLO_ACK === 'recv') this.probeAck(peer, 'recv');
      else if (EXTRA_HELLO_ACK === 'pending' && pending !== undefined) this.probeAck(pending, 'pending');
      return;
    }
    const allowed = IS_SERVER ? ['prepare', 'request', 'cancel'] : ['delta', 'done', 'error'];
    if (!allowed.includes(message.type) || this.onMessage === null) {
      hilog.warn(0, 'NearbyChat', 'ignore type=%{public}s epoch=%{public}d ready=%{public}s',
        message.type, peer.epoch, String(peer.ready));
      return;
    }
    this.onMessage(message, peer.epoch);
  }

  private acknowledge(peer: Peer): void {
    if (!this.holds(peer) || peer.ready) return;
    this.write(peer, { type: 'hello_ack' });
    this.ready(peer);
  }

  private probeAck(peer: Peer, reason: string): void {
    hilog.info(0, 'NearbyChat', 'probe-ack reason=%{public}s epoch=%{public}d session=%{public}d',
      reason, peer.epoch, peer.sessionId);
    this.write(peer, { type: 'hello_ack' });
  }

  private ready(peer: Peer): void {
    peer.ready = true;
    peer.settleConnection(true);
    clearTimeout(peer.timer);
    this.refreshStatus();
    this.onConnection?.(true, peer.epoch);
    hilog.info(0, 'NearbyChat', 'softbus ready epoch=%{public}d peers=%{public}d', peer.epoch, this.connectedCount());
  }

  async send(message: WireMessage, expectedEpoch?: number): Promise<boolean> {
    const peer = expectedEpoch !== undefined ?
      this.peers.find((item: Peer) => item.epoch === expectedEpoch) :
      this.peers.find((item: Peer) => item.ready);
    if (peer === undefined || !peer.ready) return false;
    return this.write(peer, message);
  }

  private write(peer: Peer, message: WireMessage): Promise<boolean> {
    if (!this.holds(peer)) return Promise.resolve(false);
    if (peer.pending >= 64) {
      this.drop(peer, '连接传输积压，请重新连接。');
      return Promise.resolve(false);
    }
    let frames: string[];
    try { frames = encodeMessage(message, String(peer.epoch) + '-' + String(++peer.sequence)); }
    catch (_) { this.drop(peer, '消息格式或长度超出限制。'); return Promise.resolve(false); }
    ++peer.pending;
    peer.writes = peer.writes.then(async (): Promise<boolean> => {
      try {
        for (const frame of frames) {
          if (!this.holds(peer)) return false;
          hilog.info(0, 'NearbyChat', 'send type=%{public}s epoch=%{public}d session=%{public}d',
            message.type, peer.epoch, peer.sessionId);
          await acm.sendMessage(peer.sessionId, frame);
        }
        return this.holds(peer);
      } catch (_) { this.drop(peer, '消息发送失败，请重新连接。'); return false; }
      finally { --peer.pending; }
    });
    return peer.writes;
  }

  private refreshStatus(): void {
    const ready = this.connectedCount();
    if (ready > 0) {
      this.status = IS_SERVER ? ('近场已连接（' + String(ready) + '台）') : '近场已连接';
    } else if (this.peers.length > 0) {
      this.status = '正在建立近场连接…';
    } else {
      this.status = IS_SERVER ? '可本机对话 · 等待聊天手机连接' : '请连接模型手机';
    }
  }

  private drop(peer: Peer, status: string): void {
    if (!this.holds(peer)) return;
    this.peers = this.peers.filter((item: Peer) => item.epoch !== peer.epoch);
    peer.end();
    peer.settleConnection(false);
    this.completeServiceCheck(peer, status);
    clearTimeout(peer.timer);
    peer.assembler.clear();
    clearInterval(peer.fragmentTimer);
    try { acm.off('connect', peer.sessionId); } catch (_) {}
    try { acm.off('disconnect', peer.sessionId); } catch (_) {}
    try { acm.off('receiveMessage', peer.sessionId); } catch (_) {}
    try { acm.destroyAbilityConnectionSession(peer.sessionId); } catch (_) {}
    if (this.peers.length === 0 && !IS_SERVER) this.status = status;
    else this.refreshStatus();
    this.onConnection?.(false, peer.epoch);
    hilog.info(0, 'NearbyChat', 'softbus disconnected epoch=%{public}d remain=%{public}d status=%{public}s',
      peer.epoch, this.connectedCount(), status);
  }

  disconnect(): void {
    ++this.lifecycle;
    const current = this.peers.slice();
    for (const peer of current) this.drop(peer, '连接已结束，请重新连接。');
  }

  destroy(): void {
    this.foreground = false;
    this.disconnect();
    this.unsubscribe();
    if (this.manager !== null) {
      try { dm.releaseDeviceManager(this.manager); } catch (_) {}
    }
    this.manager = null;
    this.context = null;
  }
}

export const nearbyChannel: NearbyChannel = new NearbyChannel();
