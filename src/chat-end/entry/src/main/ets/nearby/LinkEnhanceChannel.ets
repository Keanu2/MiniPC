import { distributedDeviceManager as dm, linkEnhance } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection as btConnection, ble } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { encodeMessage, MessageAssembler, WireMessage } from './ChatProtocol';
import { COMPUTE_ADV_TYPE, COMPUTE_MANUFACTURE_ID, IS_SERVER } from './NearbyConfig';

const BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-compute';
const CONNECT_TRY_MS = 8000;
const COMPUTE_SCAN_MS = 4500;

class BleHit {
  mac: string;
  name: string;
  rssi: number;
  compute: boolean;
  constructor(mac: string, name: string, rssi: number, compute: boolean) {
    this.mac = mac;
    this.name = name;
    this.rssi = rssi;
    this.compute = compute;
  }
}

export class AdvertisedCompute {
  name: string;
  mac: string;
  constructor(name: string, mac: string) {
    this.name = name;
    this.mac = mac;
  }
}

function namesMatch(left: string, right: string): boolean {
  return left.length > 0 && right.length > 0 &&
    (left === right || left.indexOf(right) >= 0 || right.indexOf(left) >= 0);
}

function computeManufacture(): ble.ManufactureData {
  const bytes = new Uint8Array(1);
  bytes[0] = COMPUTE_ADV_TYPE;
  return {
    manufactureId: COMPUTE_MANUFACTURE_ID,
    manufactureValue: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
  };
}

function advMarksCompute(data: ArrayBuffer): boolean {
  const bytes = new Uint8Array(data);
  let index = 0;
  while (index + 1 < bytes.length) {
    const length = bytes[index];
    if (length === 0) break;
    const end = index + 1 + length;
    if (end > bytes.length) break;
    const type = bytes[index + 1];
    if (type === 0xFF && length >= 4) {
      const id = bytes[index + 2] | (bytes[index + 3] << 8);
      if (id === COMPUTE_MANUFACTURE_ID && bytes[index + 4] === COMPUTE_ADV_TYPE) return true;
    }
    index = end;
  }
  return false;
}

class Peer {
  epoch: number;
  peerId: string;
  connection: linkEnhance.Connection;
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
  constructor(epoch: number, peerId: string, connection: linkEnhance.Connection) {
    this.epoch = epoch;
    this.peerId = peerId;
    this.connection = connection;
    this.ended = new Promise<void>(resolve => { this.end = resolve; });
    this.connectionReady = new Promise<boolean>(resolve => { this.settleConnection = resolve; });
  }
}

function toBuffer(text: string): ArrayBuffer {
  const bytes = new util.TextEncoder().encodeInto(text);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function fromBuffer(data: ArrayBuffer): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(data));
}

/** Near-field data plane over linkEnhance. Device list still comes from DeviceManager. */
export class LinkEnhanceChannel {
  private context: common.UIAbilityContext | null = null;
  private manager: dm.DeviceManager | null = null;
  private server: linkEnhance.Server | null = null;
  private peers: Peer[] = [];
  private lastHits: BleHit[] = [];
  private epoch: number = 0;
  private lifecycle: number = 0;
  private foreground: boolean = true;
  private permissionPending: Promise<void> | null = null;
  private onMessage: ((message: WireMessage, epoch: number) => void) | null = null;
  private onConnection: ((connected: boolean, epoch: number) => void) | null = null;
  private status: string = IS_SERVER ? '可本机对话 · 请启用近场连接' : '正在寻找算力设备…';

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
    const token = context.applicationInfo.accessTokenId;
    if (access.verifyAccessTokenSync(token, 'ohos.permission.DISTRIBUTED_DATASYNC') !==
      abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      const syncResult = await access.requestPermissionsFromUser(context, ['ohos.permission.DISTRIBUTED_DATASYNC']);
      if (syncResult.authResults.length !== 1 || syncResult.authResults[0] !== 0) {
        throw new Error('请在设置中允许附近设备权限，再点击连接。');
      }
    }
    if (access.verifyAccessTokenSync(token, 'ohos.permission.ACCESS_BLUETOOTH') !==
      abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      const btResult = await access.requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      if (btResult.authResults.length !== 1 || btResult.authResults[0] !== 0) {
        throw new Error('请在设置中允许蓝牙权限，再点击连接。');
      }
    }
    if (access.verifyAccessTokenSync(token, 'ohos.permission.APPROXIMATELY_LOCATION') !==
      abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      const locResult = await access.requestPermissionsFromUser(context, ['ohos.permission.APPROXIMATELY_LOCATION']);
      if (locResult.authResults.length !== 1 || locResult.authResults[0] !== 0) {
        throw new Error('请在设置中允许大致位置权限，再点击连接。');
      }
    }
    this.checkOperation(operation);
    if (this.context !== context) throw new Error('应用已关闭。');
    if (this.manager === null) this.manager = dm.createDeviceManager(BUNDLE);
    if (IS_SERVER) this.startServer();
    else if (this.peers.length === 0) this.update('正在寻找算力设备…');
  }

  private startServer(): void {
    if (this.server !== null) {
      this.update(this.peers.length === 0 ? '可本机对话 · 等待聊天手机连接' :
        '近场已连接（' + String(this.connectedCount()) + '台）');
      return;
    }
    try {
      const server = linkEnhance.createServer(SERVICE);
      server.on('connectionAccepted', (incoming: linkEnhance.Connection) => {
        const peerId = incoming.getPeerDeviceId() || ('accept-' + String(this.epoch + 1));
        hilog.info(0, 'NearbyChat', 'le-accept peer=%{public}s count=%{public}d', peerId, this.peers.length + 1);
        const existing = this.peers.find((item: Peer) => item.peerId === peerId);
        if (existing !== undefined) this.drop(existing, '对端重新连接。');
        this.attach(incoming, peerId, true);
      });
      server.on('serverStopped', (reason: number) => {
        hilog.warn(0, 'NearbyChat', 'le-server stopped reason=%{public}d', reason);
        this.server = null;
        this.disconnect();
        this.update('增强连接服务已停止（' + String(reason) + '），请重新启用近场。');
      });
      server.start();
      this.server = server;
      this.advertise();
      hilog.info(0, 'NearbyChat', 'le-server start name=%{public}s', SERVICE);
      this.update('可本机对话 · 等待聊天手机连接');
    } catch (error) {
      const code = (error as BusinessError).code;
      hilog.error(0, 'NearbyChat', 'le-server start failed code=%{public}s', String(code));
      throw new Error('无法启动增强连接（' + String(code) + '）。');
    }
  }

  async devices(): Promise<dm.DeviceBasicInfo[]> {
    await this.prepare();
    const devices = this.manager!.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
      typeof device.networkId === 'string' && device.networkId.length > 0);
    hilog.info(0, 'NearbyChat', 'available devices=%{public}d', devices.length);
    for (const device of devices) {
      hilog.info(0, 'NearbyChat', 'available name=%{public}s deviceId=%{public}s networkId=%{public}s',
        device.deviceName, device.deviceId, device.networkId || '');
    }
    return devices;
  }

  async computeDevices(): Promise<dm.DeviceBasicInfo[]> {
    const devices = await this.devices();
    this.update('正在寻找算力设备…');
    this.lastHits = await this.scanHits(COMPUTE_SCAN_MS, true);
    const computeHits = this.lastHits.filter((item: BleHit) => item.compute);
    hilog.info(0, 'NearbyChat', 'compute hits=%{public}d available=%{public}d', computeHits.length, devices.length);
    if (computeHits.length === 0) return [];
    const matched: dm.DeviceBasicInfo[] = [];
    const rssi: number[] = [];
    for (const device of devices) {
      let best = -9999;
      let found = false;
      for (const hit of computeHits) {
        if (!namesMatch(device.deviceName, this.hitName(hit))) continue;
        found = true;
        if (hit.rssi > best) best = hit.rssi;
      }
      if (found) {
        matched.push(device);
        rssi.push(best);
      }
    }
    if (matched.length === 0 && computeHits.length > 0) {
      hilog.info(0, 'NearbyChat', 'compute unnamed hits=%{public}d, connect by MAC', computeHits.length);
      return [];
    }
    for (let i = 0; i < matched.length; i++) {
      let best = i;
      for (let j = i + 1; j < matched.length; j++) {
        if (rssi[j] > rssi[best]) best = j;
      }
      if (best !== i) {
        const device = matched[i]; matched[i] = matched[best]; matched[best] = device;
        const value = rssi[i]; rssi[i] = rssi[best]; rssi[best] = value;
      }
    }
    return matched;
  }

  hasComputeHits(): boolean {
    return this.lastHits.some((item: BleHit) => item.compute);
  }

  advertisedComputes(): AdvertisedCompute[] {
    const hits: BleHit[] = [];
    for (const hit of this.lastHits) {
      if (hit.compute) hits.push(hit);
    }
    hits.sort((left: BleHit, right: BleHit) => right.rssi - left.rssi);
    const result: AdvertisedCompute[] = [];
    for (const hit of hits) {
      const name = this.hitName(hit);
      result.push(new AdvertisedCompute(name.length > 0 ? name : hit.mac, hit.mac));
    }
    return result;
  }

  private advertise(): void {
    try { ble.stopAdvertising(); } catch (_) {}
    const setting: ble.AdvertiseSetting = { interval: 160, connectable: true };
    const adv: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [computeManufacture()],
      serviceData: [],
      includeDeviceName: false
    };
    const response: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [],
      includeDeviceName: true
    };
    try {
      ble.startAdvertising(setting, adv, response);
      hilog.info(0, 'NearbyChat', 'le-adv start type+name');
    } catch (first) {
      hilog.warn(0, 'NearbyChat', 'le-adv type+name failed code=%{public}s', String((first as BusinessError).code));
      try {
        ble.startAdvertising(setting, adv);
        hilog.info(0, 'NearbyChat', 'le-adv start type-only');
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'le-adv failed code=%{public}s', String((error as BusinessError).code));
      }
    }
  }

  async bindNearby(device: dm.DeviceBasicInfo): Promise<dm.DeviceBasicInfo> {
    await this.prepare();
    const trusted = this.manager!.getAvailableDeviceListSync().find((item: dm.DeviceBasicInfo) =>
      item.deviceId === device.deviceId && typeof item.networkId === 'string' && item.networkId.length > 0);
    if (trusted !== undefined) return trusted;
    if (typeof device.networkId === 'string' && device.networkId.length > 0) return device;
    throw new Error('设备未组网，请先在超级终端中连接模型手机。');
  }

  async connect(networkId: string, operation: number = this.lifecycle): Promise<void> {
    if (IS_SERVER || this.peers.length > 0) return;
    this.checkOperation(operation);
    const devices = await this.devices();
    this.checkOperation(operation);
    if (this.peers.length > 0) return;
    const target = devices.find((device: dm.DeviceBasicInfo) => device.networkId === networkId);
    if (target === undefined) throw new Error('设备已离线，请检查同账号、Wi-Fi和蓝牙后重试。');
    this.update('正在连接算力设备…');
    const computeMacs = this.advertiserMacs(target.deviceName);
    const candidates: string[][] = [];
    for (const mac of computeMacs) candidates.push(['compute', mac]);
    hilog.info(0, 'NearbyChat', 'le-target name=%{public}s deviceId=%{public}s macs=%{public}d',
      target.deviceName, target.deviceId, computeMacs.length);
    if (computeMacs.length === 0) throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
    for (const item of candidates) {
      this.checkOperation(operation);
      if (this.peers.length > 0) return;
      if (item[1].length === 0) continue;
      const ok = await this.tryConnect(item[0], item[1]);
      if (ok) return;
    }
    throw new Error('增强连接失败：未找到可用的蓝牙地址。');
  }

  async connectToAdvertisers(operation: number = this.lifecycle): Promise<void> {
    if (IS_SERVER || this.peers.length > 0) return;
    this.checkOperation(operation);
    const available = this.manager === null ? [] :
      this.manager.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
        typeof device.networkId === 'string' && device.networkId.length > 0);
    if (available.length === 0) throw new Error('设备未组网，请先在超级终端中连接模型手机。');
    this.update('正在连接算力设备…');
    const macs = this.advertiserMacs('');
    hilog.info(0, 'NearbyChat', 'le-connect advertisers=%{public}d available=%{public}d', macs.length, available.length);
    if (macs.length === 0) throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
    for (const mac of macs) {
      this.checkOperation(operation);
      if (this.peers.length > 0) return;
      if (mac.length === 0) continue;
      const ok = await this.tryConnect('compute', mac);
      if (ok) return;
    }
    throw new Error('增强连接失败：未找到可用的蓝牙地址。');
  }

  async connectAdvertiser(mac: string, operation: number = this.lifecycle): Promise<void> {
    if (IS_SERVER || this.peers.length > 0) return;
    this.checkOperation(operation);
    const available = this.manager === null ? [] :
      this.manager.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
        typeof device.networkId === 'string' && device.networkId.length > 0);
    if (available.length === 0) throw new Error('设备未组网，请先在超级终端中连接模型手机。');
    this.update('正在连接算力设备…');
    hilog.info(0, 'NearbyChat', 'le-connect advertiser=%{public}s available=%{public}d', mac, available.length);
    if (mac.length === 0) throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
    const ok = await this.tryConnect('compute', mac);
    if (ok) return;
    throw new Error('增强连接失败：未找到可用的蓝牙地址。');
  }

  private hitName(hit: BleHit): string {
    if (hit.name.length > 0) return hit.name;
    try { return btConnection.getRemoteDeviceName(hit.mac); } catch (_) { return ''; }
  }

  private advertiserMacs(deviceName: string): string[] {
    const named: string[] = [];
    const rest: BleHit[] = [];
    for (const hit of this.lastHits) {
      if (!hit.compute) continue;
      if (deviceName.length > 0 && namesMatch(deviceName, this.hitName(hit))) named.push(hit.mac);
      else rest.push(hit);
    }
    rest.sort((left: BleHit, right: BleHit) => right.rssi - left.rssi);
    const macs: string[] = [];
    for (const mac of named) macs.push(mac);
    for (const hit of rest) {
      if (macs.indexOf(hit.mac) < 0) macs.push(hit.mac);
    }
    return macs;
  }

  private scanHits(timeoutMs: number, computeOnly: boolean): Promise<BleHit[]> {
    return new Promise<BleHit[]>((resolve) => {
      const hits: BleHit[] = [];
      const options: ble.ScanOptions = {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      };
      const collect = (results: Array<ble.ScanResult>): void => {
        for (const item of results) {
          let compute = false;
          try { compute = advMarksCompute(item.data); } catch (_) { compute = false; }
          const existing = hits.find((hit: BleHit) => hit.mac === item.deviceId);
          if (existing !== undefined) {
            if (compute) existing.compute = true;
            if (existing.name.length === 0 && (item.deviceName || '').length > 0) existing.name = item.deviceName;
            continue;
          }
          const hit = new BleHit(item.deviceId, item.deviceName || '', item.rssi, compute);
          hits.push(hit);
          hilog.info(0, 'NearbyChat', 'le-scan mac=%{public}s name=%{public}s rssi=%{public}d compute=%{public}s',
            hit.mac, hit.name, hit.rssi, String(hit.compute));
        }
      };
      try {
        ble.on('BLEDeviceFind', collect);
        try {
          ble.startBLEScan([{ manufactureId: COMPUTE_MANUFACTURE_ID }], options);
          hilog.info(0, 'NearbyChat', 'le-scan started manufacture');
        } catch (first) {
          ble.startBLEScan(null, options);
          hilog.info(0, 'NearbyChat', 'le-scan started unfiltered after=%{public}s',
            String((first as BusinessError).code));
        }
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'le-scan start failed code=%{public}s', String((error as BusinessError).code));
        resolve([]);
        return;
      }
      setTimeout(() => {
        try { ble.stopBLEScan(); } catch (_) {}
        try { ble.off('BLEDeviceFind', collect); } catch (_) {
          try { ble.off('BLEDeviceFind'); } catch (_) {}
        }
        if (computeOnly) resolve(hits.filter((item: BleHit) => item.compute));
        else resolve(hits);
      }, timeoutMs);
    });
  }

  private tryConnect(kind: string, deviceId: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled = false;
      let handle: linkEnhance.Connection | null = null;
      const finish = (ok: boolean): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (!ok && handle !== null) {
          try { handle.close(); } catch (_) {}
        }
        resolve(ok);
      };
      const timer = setTimeout(() => {
        hilog.warn(0, 'NearbyChat', 'le-connect tried=%{public}s timeout id=%{public}s', kind, deviceId);
        finish(false);
      }, CONNECT_TRY_MS);
      try {
        handle = linkEnhance.createConnection(deviceId, SERVICE);
        handle.on('connectResult', (result: linkEnhance.ConnectResult) => {
          hilog.info(0, 'NearbyChat', 'le-connect tried=%{public}s success=%{public}s reason=%{public}d id=%{public}s',
            kind, String(result.success), result.reason, deviceId);
          if (!result.success) { finish(false); return; }
          if (handle === null) { finish(false); return; }
          this.attach(handle, result.deviceId || deviceId, false);
          finish(true);
        });
        handle.connect();
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'le-connect tried=%{public}s throw code=%{public}s',
          kind, String((error as BusinessError).code));
        finish(false);
      }
    });
  }

  accept(parameters: Record<string, Object>): boolean {
    hilog.warn(0, 'NearbyChat', 'le-accept ignored acm collaborate keys=%{public}d', Object.keys(parameters).length);
    return false;
  }

  private attach(incoming: linkEnhance.Connection, peerId: string, fromServer: boolean): Peer {
    const peer = new Peer(++this.epoch, peerId, incoming);
    this.peers.push(peer);
    incoming.on('disconnected', (reason: number) => {
      hilog.info(0, 'NearbyChat', 'le-disconnect epoch=%{public}d peer=%{public}s reason=%{public}d',
        peer.epoch, peer.peerId, reason);
      this.drop(peer, '连接已断开（原因' + String(reason) + '），请重新连接。');
    });
    incoming.on('dataReceived', (data: ArrayBuffer) => {
      if (!this.holds(peer)) return;
      try {
        const text = fromBuffer(data);
        const message = peer.assembler.receive(text);
        if (message !== null) this.receive(peer, message);
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'le-recv invalid epoch=%{public}d', peer.epoch);
        this.drop(peer, '收到无效消息，连接已结束。');
      }
    });
    peer.timer = setTimeout(() => this.drop(peer, '连接超时，请确认两端应用在前台后重试。'), 20000);
    peer.fragmentTimer = setInterval(() => {
      try { peer.assembler.checkExpiry(); }
      catch (_) { this.drop(peer, '消息传输中断，请重新连接。'); }
    }, 1000);
    hilog.info(0, 'NearbyChat', 'le-attach epoch=%{public}d peer=%{public}s server=%{public}s',
      peer.epoch, peerId, String(fromServer));
    this.opened(peer);
    return peer;
  }

  private holds(peer: Peer): boolean {
    return this.peers.indexOf(peer) >= 0;
  }

  private opened(peer: Peer): void {
    if (!this.holds(peer) || peer.opened) return;
    peer.opened = true;
    if (!IS_SERVER) this.write(peer, { type: 'hello', peerRole: 'chat' });
  }

  private receive(peer: Peer, message: WireMessage): void {
    if (!this.holds(peer)) return;
    hilog.info(0, 'NearbyChat', 'le-recv type=%{public}s epoch=%{public}d peer=%{public}s ready=%{public}s',
      message.type, peer.epoch, peer.peerId, String(peer.ready));
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
      hilog.warn(0, 'NearbyChat', 'le-ignore type=%{public}s epoch=%{public}d', message.type, peer.epoch);
      return;
    }
    this.onMessage(message, peer.epoch);
  }

  private acknowledge(peer: Peer): void {
    if (!this.holds(peer) || peer.ready) return;
    this.write(peer, { type: 'hello_ack', peerRole: 'compute' });
    this.ready(peer);
  }

  private ready(peer: Peer): void {
    peer.ready = true;
    peer.settleConnection(true);
    clearTimeout(peer.timer);
    this.refreshStatus();
    hilog.info(0, 'NearbyChat', 'le-ready epoch=%{public}d peer=%{public}s peers=%{public}d',
      peer.epoch, peer.peerId, this.connectedCount());
    this.onConnection?.(true, peer.epoch);
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
    hilog.info(0, 'NearbyChat', 'le-send type=%{public}s epoch=%{public}d peer=%{public}s frames=%{public}d',
      message.type, peer.epoch, peer.peerId, frames.length);
    ++peer.pending;
    peer.writes = peer.writes.then((): boolean => {
      try {
        for (const frame of frames) {
          if (!this.holds(peer)) return false;
          peer.connection.sendData(toBuffer(frame));
        }
        return this.holds(peer);
      } catch (error) {
        hilog.error(0, 'NearbyChat', 'le-send failed code=%{public}s', String((error as BusinessError).code));
        this.drop(peer, '消息发送失败，请重新连接。');
        return false;
      } finally { --peer.pending; }
    });
    return peer.writes;
  }

  private refreshStatus(): void {
    if (!IS_SERVER) this.status = this.isConnected() ? '近场已连接' : this.status;
    else if (this.connectedCount() > 0) this.status = '近场已连接（' + String(this.connectedCount()) + '台）';
    else if (this.server !== null) this.status = '可本机对话 · 等待聊天手机连接';
  }

  private update(status: string): void {
    this.status = status;
    this.onConnection?.(this.isConnected(), this.epoch);
  }

  private drop(peer: Peer, status: string): void {
    const index = this.peers.indexOf(peer);
    if (index < 0) return;
    this.peers.splice(index, 1);
    peer.end();
    peer.settleConnection(false);
    this.completeServiceCheck(peer, status);
    clearTimeout(peer.timer);
    peer.assembler.clear();
    clearInterval(peer.fragmentTimer);
    try { peer.connection.disconnect(); } catch (_) {}
    try { peer.connection.close(); } catch (_) {}
    hilog.info(0, 'NearbyChat', 'le-dropped epoch=%{public}d peer=%{public}s remain=%{public}d status=%{public}s',
      peer.epoch, peer.peerId, this.peers.length, status);
    if (this.peers.length === 0) this.status = IS_SERVER ?
      (this.server !== null ? '可本机对话 · 等待聊天手机连接' : status) : status;
    else this.refreshStatus();
    this.onConnection?.(this.isConnected(), peer.epoch);
  }

  disconnect(): void {
    ++this.lifecycle;
    const current = this.peers.slice();
    for (const peer of current) this.drop(peer, '连接已结束，请重新连接。');
    if (this.server !== null) {
      try { this.server.stop(); } catch (_) {}
      try { this.server.close(); } catch (_) {}
      this.server = null;
      try { ble.stopAdvertising(); } catch (_) {}
      hilog.info(0, 'NearbyChat', 'le-server closed');
    }
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

export const nearbyChannel: LinkEnhanceChannel = new LinkEnhanceChannel();
