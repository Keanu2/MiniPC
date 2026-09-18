import { abilityConnectionManager as acm, distributedDeviceManager as dm } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { encodeMessage, MessageAssembler, WireMessage } from './ChatProtocol';
import { IS_SERVER } from './NearbyConfig';

const BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-chat';

function connectFailure(code?: number): string {
  const reasons: string[] = ['已存在协同会话', '模型手机拒绝连接', '聊天手机的Wi-Fi未开启',
    '模型手机近场链路冲突或Wi-Fi不可用，请关闭个人热点后重试', '模型手机缺少协同入口', '系统协同服务内部错误'];
  return '连接失败：' + (code !== undefined && code >= 0 && code < reasons.length ? reasons[code] : '未知原因') +
    '（' + String(code) + '）。';
}

class Peer {
  epoch: number;
  sessionId: number;
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
  constructor(sessionId: number, epoch: number) {
    this.sessionId = sessionId; this.epoch = epoch;
    this.ended = new Promise<void>(resolve => { this.end = resolve; });
    this.connectionReady = new Promise<boolean>(resolve => { this.settleConnection = resolve; });
  }
}

/** Ability-owned text session. No IP socket or automatic remote relaunch. */
export class NearbyChannel {
  private context: common.UIAbilityContext | null = null;
  private manager: dm.DeviceManager | null = null;
  private peer: Peer | null = null;
  private epoch: number = 0;
  private lifecycle: number = 0;
  private foreground: boolean = true;
  private permissionPending: Promise<void> | null = null;
  private onMessage: ((message: WireMessage, epoch: number) => void) | null = null;
  private onConnection: ((connected: boolean, epoch: number) => void) | null = null;
  private status: string = IS_SERVER ? '可本机对话 · 请启用近场连接' : '请连接模型手机';
  private bindCallback: ((err: BusinessError, data: Object) => void) | null = null;

  initialize(context: common.UIAbilityContext): void { this.context = context; }
  operation(): number { return this.lifecycle; }
  resume(): void { this.foreground = true; }
  suspend(): void { this.foreground = false; this.disconnect(); }
  private checkOperation(operation: number): void {
    if (!this.foreground || operation !== this.lifecycle || this.context === null) {
      throw new Error('连接操作已取消，请回到应用后重试。');
    }
  }
  isConnected(): boolean { return this.peer?.ready === true; }
  isConnecting(): boolean { return this.peer !== null && !this.peer.ready; }
  getStatus(): string { return this.status; }
  waitUntilConnected(): Promise<boolean> { return this.peer?.connectionReady || Promise.resolve(false); }

  checkService(): Promise<string> {
    const peer = this.peer;
    if (peer === null || !peer.ready) return Promise.resolve('近场连接尚未完成。');
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
    connection(this.isConnected(), this.peer?.epoch || this.epoch);
    if (this.peer?.hello && IS_SERVER) this.acknowledge(this.peer);
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
    if (this.peer === null) this.update(IS_SERVER ? '可本机对话 · 等待聊天手机连接' : '请选择模型手机');
  }

  trustedDevices(): dm.DeviceBasicInfo[] {
    if (this.manager === null) return [];
    return this.manager.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
      typeof device.networkId === 'string' && device.networkId.length > 0);
  }

  async devices(): Promise<dm.DeviceBasicInfo[]> {
    await this.prepare();
    const trusted = this.trustedDevices();
    hilog.info(0, 'NearbyChat', 'available devices=%{public}d', trusted.length);
    if (trusted.length > 0) return trusted;
    this.update('正在搜索附近设备…');
    const nearby = await this.discoverNearby();
    hilog.info(0, 'NearbyChat', 'discovered devices=%{public}d', nearby.length);
    return nearby;
  }

  async bindNearby(device: dm.DeviceBasicInfo): Promise<dm.DeviceBasicInfo> {
    await this.prepare();
    const trusted = this.trustedDevices().find((item: dm.DeviceBasicInfo) => item.deviceId === device.deviceId);
    if (trusted !== undefined) return trusted;
    this.stopDiscovering();
    this.update('正在绑定模型手机，请在两端确认PIN码…');
    await this.bindTarget(device);
    return this.waitUntilOnline(device.deviceId);
  }

  private discoverNearby(): Promise<dm.DeviceBasicInfo[]> {
    const manager = this.manager!;
    this.stopDiscovering();
    const found: dm.DeviceBasicInfo[] = [];
    return new Promise<dm.DeviceBasicInfo[]>((resolve) => {
      const finish = (): void => {
        this.stopDiscovering();
        resolve(found);
      };
      try {
        manager.on('discoverSuccess', (data: Object) => {
          const device = this.deviceFromDiscover(data);
          if (device === null) return;
          if (found.some((item: dm.DeviceBasicInfo) => item.deviceId === device.deviceId)) return;
          found.push(device);
          hilog.info(0, 'NearbyChat', 'discoverSuccess name=%{public}s id=%{public}s',
            device.deviceName, device.deviceId.substring(0, 8));
        });
        manager.on('discoverFailure', (data: Object) => {
          hilog.warn(0, 'NearbyChat', 'discoverFailure %{public}s', JSON.stringify(data));
        });
        const discoverParam: Record<string, number> = { 'discoverTargetType': 1 };
        const filterOptions: Record<string, number> = {
          'availableStatus': 0,
          'authenticationStatus': 0
        };
        manager.startDiscovering(discoverParam, filterOptions);
        setTimeout(finish, 12000);
      } catch (error) {
        const code = (error as BusinessError).code;
        hilog.error(0, 'NearbyChat', 'startDiscovering failed code=%{public}s', String(code));
        finish();
      }
    });
  }

  private deviceFromDiscover(data: Object): dm.DeviceBasicInfo | null {
    const wrapped = data as Record<string, Object>;
    const nested = wrapped['device'] as dm.DeviceBasicInfo | undefined;
    const device = nested !== undefined ? nested : data as dm.DeviceBasicInfo;
    if (typeof device?.deviceId === 'string' && device.deviceId.length > 0) return device;
    return null;
  }

  private bindTarget(device: dm.DeviceBasicInfo): Promise<void> {
    const manager = this.manager!;
    const bindParam: Record<string, number | string> = {
      'bindLevel': 3,
      'bindType': 1,
      'targetPkgName': BUNDLE,
      'appName': 'MiniPC 聊天',
      'appOperation': '绑定近场聊天',
      'customDescription': 'PIN码认证'
    };
    return new Promise<void>((resolve, reject) => {
      this.bindCallback = (err: BusinessError, data: Object): void => {
        this.bindCallback = null;
        if (err) {
          hilog.error(0, 'NearbyChat', 'bindTarget error code=%{public}s message=%{public}s',
            String(err.code), err.message);
          reject(new Error('PIN绑定失败（' + String(err.code) + '），请在两端确认后重试。'));
          return;
        }
        hilog.info(0, 'NearbyChat', 'bindTarget succeed %{public}s', JSON.stringify(data));
        resolve();
      };
      try {
        hilog.info(0, 'NearbyChat', 'bindTarget begin id=%{public}s name=%{public}s',
          device.deviceId.substring(0, 8), device.deviceName);
        manager.bindTarget(device.deviceId, bindParam, this.bindCallback);
      } catch (error) {
        this.bindCallback = null;
        const code = (error as BusinessError).code;
        hilog.error(0, 'NearbyChat', 'bindTarget throw code=%{public}s', String(code));
        reject(new Error('无法发起PIN绑定（' + String(code) + '）。'));
      }
    });
  }

  private waitUntilOnline(deviceId: string): Promise<dm.DeviceBasicInfo> {
    const manager = this.manager!;
    return new Promise<dm.DeviceBasicInfo>((resolve, reject) => {
      const existing = this.trustedDevices().find((item: dm.DeviceBasicInfo) => item.deviceId === deviceId);
      if (existing !== undefined) {
        resolve(existing);
        return;
      }
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        try { manager.off('deviceStateChange'); } catch (_) {}
        reject(new Error('绑定后设备未上线，请保持两端亮屏后重试。'));
      }, 20000);
      const complete = (device: dm.DeviceBasicInfo): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { manager.off('deviceStateChange'); } catch (_) {}
        resolve(device);
      };
      try {
        manager.on('deviceStateChange', (data: Object) => {
          const event = data as Record<string, Object>;
          const device = event['device'] as dm.DeviceBasicInfo;
          const action = event['action'] as dm.DeviceStateChange;
          if (device === undefined || device.deviceId !== deviceId) return;
          hilog.info(0, 'NearbyChat', 'deviceStateChange action=%{public}s', String(action));
          if (action === dm.DeviceStateChange.AVAILABLE) complete(device);
        });
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'deviceStateChange listen failed code=%{public}s',
          String((error as BusinessError).code));
      }
      const poll = (): void => {
        if (settled) return;
        const online = this.trustedDevices().find((item: dm.DeviceBasicInfo) => item.deviceId === deviceId);
        if (online !== undefined) complete(online);
        else setTimeout(poll, 500);
      };
      poll();
    });
  }

  private stopDiscovering(): void {
    if (this.manager === null) return;
    try { this.manager.stopDiscovering(); } catch (_) {}
    try { this.manager.off('discoverSuccess'); } catch (_) {}
    try { this.manager.off('discoverFailure'); } catch (_) {}
  }

  async connect(networkId: string, operation: number = this.lifecycle): Promise<void> {
    if (IS_SERVER || this.peer !== null) return;
    this.checkOperation(operation);
    const devices = this.trustedDevices();
    this.checkOperation(operation);
    if (this.peer !== null) return;
    if (!devices.some((device: dm.DeviceBasicInfo) => device.networkId === networkId)) {
      throw new Error('设备已离线，请检查同账号、Wi-Fi和蓝牙后重试。');
    }
    const info: acm.PeerInfo = { deviceId: networkId, bundleName: BUNDLE,
      moduleName: 'entry', abilityName: 'EntryAbility' };
    const options: acm.ConnectOptions = { needSendData: true,
      startOptions: acm.StartOptionParams.START_IN_FOREGROUND };
    const peer = this.attach(acm.createAbilityConnectionSession(SERVICE, this.context!, info, options));
    // Observe the native result even when teardown already released the UI wait.
    const attempt = async (): Promise<void> => {
      try {
        const result = await acm.connect(peer.sessionId);
        hilog.info(0, 'NearbyChat', 'connect result epoch=%{public}d connected=%{public}s code=%{public}s',
          peer.epoch, String(result.isConnected), String(result.errorCode));
        if (!result.isConnected) {
          this.connectionFailed(peer, operation, connectFailure(result.errorCode));
        } else if (this.peer === peer) { this.opened(peer); }
      } catch (error) {
        const code = (error as BusinessError).code;
        hilog.error(0, 'NearbyChat', 'connect API failed epoch=%{public}d code=%{public}s', peer.epoch, String(code));
        this.connectionFailed(peer, operation, '连接接口失败（' + String(code) + '），请检查权限后重试。');
      }
    };
    await Promise.race([attempt(), peer.ended]);
  }

  private connectionFailed(peer: Peer, operation: number, status: string): void {
    if (this.peer === peer) this.drop(peer, status);
    else if (this.peer === null && this.epoch === peer.epoch && this.lifecycle === operation && this.foreground) {
      this.update(status);
    }
  }

  accept(parameters: Record<string, Object>): boolean {
    if (!IS_SERVER || this.peer !== null || this.context === null) return this.reject('role/session/context');
    // Authorize on the model phone before a remote request; never grant silently.
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
      const options: acm.ConnectOptions = { needSendData: true,
        startOptions: acm.StartOptionParams.START_IN_FOREGROUND };
      const peer = this.attach(acm.createAbilityConnectionSession(SERVICE, this.context, info, options));
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

  private attach(sessionId: number): Peer {
    const peer = new Peer(sessionId, ++this.epoch);
    this.peer = peer;
    try {
      acm.on('connect', sessionId, (event: acm.EventCallbackInfo) => {
        if (event.sessionId === sessionId) this.opened(peer);
      });
      acm.on('disconnect', sessionId, (event: acm.EventCallbackInfo) => {
        hilog.info(0, 'NearbyChat', 'disconnect event epoch=%{public}d reason=%{public}s', peer.epoch, String(event.reason));
        if (event.sessionId === sessionId) this.drop(peer, '连接已断开（原因' + String(event.reason) + '），请重新连接。');
      });
      acm.on('receiveMessage', sessionId, (event: acm.EventCallbackInfo) => {
        if (this.peer !== peer || event.sessionId !== sessionId) return;
        try {
          if (typeof event.msg !== 'string') throw new Error('Invalid message');
          const message = peer.assembler.receive(event.msg);
          if (message !== null) this.receive(peer, message);
        } catch (_) { this.drop(peer, '收到无效消息，连接已结束。'); }
      });
      // Only connection/handshake has a deadline, never model generation.
      peer.timer = setTimeout(() => this.drop(peer, '连接超时，请确认两端应用在前台后重试。'), 20000);
      peer.fragmentTimer = setInterval(() => {
        try { peer.assembler.checkExpiry(); }
        catch (_) { this.drop(peer, '消息传输中断，请重新连接。'); }
      }, 1000);
      this.update('正在建立近场连接…');
      return peer;
    } catch (error) {
      this.drop(peer, '无法创建近场连接。');
      throw new Error('无法注册近场会话事件。');
    }
  }

  private opened(peer: Peer): void {
    if (this.peer !== peer || peer.opened) return;
    peer.opened = true;
    if (!IS_SERVER) this.write(peer, { type: 'hello' });
  }

  private receive(peer: Peer, message: WireMessage): void {
    if (this.peer !== peer) return;
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
    const allowed = IS_SERVER ? ['prepare', 'request', 'cancel'] : ['delta', 'done', 'error'];
    if (!allowed.includes(message.type) || this.onMessage === null) {
      this.drop(peer, '对端消息与当前会话不匹配。');
      return;
    }
    this.onMessage(message, peer.epoch);
  }

  private acknowledge(peer: Peer): void {
    if (this.peer !== peer || peer.ready) return;
    this.write(peer, { type: 'hello_ack' });
    this.ready(peer);
  }

  private ready(peer: Peer): void {
    peer.ready = true;
    peer.settleConnection(true);
    clearTimeout(peer.timer);
    this.update('近场已连接');
    hilog.info(0, 'NearbyChat', 'softbus ready epoch=%{public}d', peer.epoch);
  }

  async send(message: WireMessage, expectedEpoch?: number): Promise<boolean> {
    const peer = this.peer;
    if (peer === null || !peer.ready || (expectedEpoch !== undefined && expectedEpoch !== peer.epoch)) return false;
    return this.write(peer, message);
  }

  private write(peer: Peer, message: WireMessage): Promise<boolean> {
    if (this.peer !== peer) return Promise.resolve(false);
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
          if (this.peer !== peer) return false;
          await acm.sendMessage(peer.sessionId, frame);
        }
        return this.peer === peer;
      } catch (_) { this.drop(peer, '消息发送失败，请重新连接。'); return false; }
      finally { --peer.pending; }
    });
    return peer.writes;
  }

  private update(status: string): void {
    this.status = status;
    this.onConnection?.(this.isConnected(), this.peer?.epoch || this.epoch);
  }

  private drop(peer: Peer, status: string): void {
    if (this.peer !== peer) return;
    this.peer = null;
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
    this.status = status;
    this.onConnection?.(false, peer.epoch);
    hilog.info(0, 'NearbyChat', 'softbus disconnected epoch=%{public}d status=%{public}s', peer.epoch, status);
  }

  disconnect(): void {
    ++this.lifecycle;
    if (this.peer !== null) this.drop(this.peer, '连接已结束，请重新连接。');
  }

  destroy(): void {
    this.foreground = false;
    this.disconnect();
    this.unsubscribe();
    this.stopDiscovering();
    if (this.manager !== null) {
      try { this.manager.off('deviceStateChange'); } catch (_) {}
      try { dm.releaseDeviceManager(this.manager); } catch (_) {}
    }
    this.manager = null;
    this.context = null;
  }
}

export const nearbyChannel: NearbyChannel = new NearbyChannel();
