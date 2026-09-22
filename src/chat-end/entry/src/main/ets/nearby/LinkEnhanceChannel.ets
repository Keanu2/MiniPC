import { distributedDeviceManager as dm, linkEnhance } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection as btConnection, ble } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { encodeMessage, MessageAssembler, WireMessage } from '../protocol/ChatProtocol';
import { COMPUTE_ADV_KEY_BYTES, COMPUTE_ADV_TYPE, COMPUTE_MANUFACTURE_ID, IS_SERVER } from './NearbyConfig';

const BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-compute';
const CONNECT_TRY_MS = 8000;
const COMPUTE_SCAN_MS = 4500;

class BleHit {
  mac: string;
  name: string;
  rssi: number;
  compute: boolean;
  slot: number;
  /** Identity fingerprint advertised by the sender; '' for older builds. */
  key: string;
  constructor(mac: string, name: string, rssi: number, compute: boolean, slot: number = 0, key: string = '') {
    this.mac = mac;
    this.name = name;
    this.rssi = rssi;
    this.compute = compute;
    this.slot = slot;
    this.key = key;
  }
}

export class AdvertisedCompute {
  name: string;
  mac: string;
  slot: number;
  /** Stable across reconnects, unlike the random BLE address in `mac`. */
  key: string;
  constructor(name: string, mac: string, slot: number = 0, key: string = '') {
    this.name = name;
    this.mac = mac;
    this.slot = slot;
    this.key = key;
  }
}

function namesMatch(left: string, right: string): boolean {
  return left.length > 0 && right.length > 0 &&
    (left === right || left.indexOf(right) >= 0 || right.indexOf(left) >= 0);
}

function randomId(): string {
  let id = '';
  while (id.length < 16) id += Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0');
  return id.substring(0, 16);
}

/** Stable identity for protocol/session deduplication; never used as a trust decision. */
function installIdOf(context: common.UIAbilityContext | null): string {
  if (context === null) return '';
  try {
    const store = preferences.getPreferencesSync(context, { name: 'nearby-identity' });
    const stored = store.getSync('installId', '').toString();
    if (stored.length > 0) return stored;
    const drawn = randomId();
    store.putSync('installId', drawn);
    store.flush();
    return drawn;
  } catch (_) { return ''; }
}

function computeManufacture(slot: number, key: string): ble.ManufactureData {
  const bytes = new Uint8Array(2 + COMPUTE_ADV_KEY_BYTES);
  bytes[0] = COMPUTE_ADV_TYPE;
  bytes[1] = slot > 0 && slot < 256 ? slot : 0;
  const keyBytes = keyBytesOf(key);
  for (let i = 0; i < COMPUTE_ADV_KEY_BYTES; i++) bytes[2 + i] = keyBytes[i];
  return {
    manufactureId: COMPUTE_MANUFACTURE_ID,
    manufactureValue: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
  };
}

/** Stable, short fingerprint of a device identity, carried in the advertisement. */
function advKeyOf(value: string): string {
  const text = value.trim().toLowerCase();
  if (text.length === 0) return '';
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash = (hash ^ text.charCodeAt(i)) >>> 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  let hex = (hash >>> 0).toString(16);
  while (hex.length < 8) hex = '0' + hex;
  return hex;
}

function keyBytesOf(value: string): Uint8Array {
  const bytes = new Uint8Array(COMPUTE_ADV_KEY_BYTES);
  const hex = advKeyOf(value);
  for (let i = 0; i < COMPUTE_ADV_KEY_BYTES; i++) {
    const at = i * 2;
    bytes[i] = at + 2 <= hex.length ? parseInt(hex.substring(at, at + 2), 16) : 0;
  }
  return bytes;
}

function advComputeSlot(data: ArrayBuffer): number {
  const at = advComputeOffset(data);
  if (at < 0) return -1;
  const bytes = new Uint8Array(data);
  return at + 1 < bytes.length ? bytes[at + 1] : 0;
}

/** Advertised identity fingerprint, or '' when the sender predates the field. */
function advComputeKey(data: ArrayBuffer): string {
  const at = advComputeOffset(data);
  if (at < 0) return '';
  const bytes = new Uint8Array(data);
  // The last key byte lives at at + 1 + KEY_BYTES; only a payload shorter than that
  // is absent. Using >= here dropped a key that ends exactly at the packet boundary.
  if (at + 2 + COMPUTE_ADV_KEY_BYTES > bytes.length) return '';
  let hex = '';
  for (let i = 0; i < COMPUTE_ADV_KEY_BYTES; i++) {
    const byte = bytes[at + 2 + i];
    if (byte < 16) hex += '0';
    hex += byte.toString(16);
  }
  return hex;
}

/**
 * Offset of our manufacturer payload inside a raw advertisement, or -1 when this
 * is not one of ours. Payload layout is [type][slot][key bytes...].
 */
function advComputeOffset(data: ArrayBuffer): number {
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
      if (id === COMPUTE_MANUFACTURE_ID && bytes[index + 4] === COMPUTE_ADV_TYPE) return index + 4;
    }
    index = end;
  }
  return -1;
}

class Peer {
  epoch: number;
  peerId: string;
  connection: linkEnhance.Connection;
  deviceUid: string = '';
  fromServer: boolean;
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
  constructor(epoch: number, peerId: string, connection: linkEnhance.Connection, fromServer: boolean) {
    this.epoch = epoch;
    this.peerId = peerId;
    this.connection = connection;
    this.fromServer = fromServer;
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
  private selfSlot: number = 0;
  private scanCancel: (() => void) | null = null;

  initialize(context: common.UIAbilityContext): void { this.context = context; }
  operation(): number { return this.lifecycle; }
  resume(): void { this.foreground = true; }
  suspend(): void { this.foreground = false; this.disconnect(); }
  isForeground(): boolean { return this.foreground; }
  private checkOperation(operation: number): void {
    if (!this.foreground || operation !== this.lifecycle || this.context === null) {
      throw new Error('连接操作已取消，请回到应用后重试。');
    }
  }
  isConnected(): boolean { return this.peers.some((item: Peer) => item.ready); }
  isListening(): boolean { return this.server !== null; }
  isConnecting(): boolean { return this.peers.some((item: Peer) => !item.ready); }
  connectedCount(): number { return this.peers.filter((item: Peer) => item.ready).length; }
  getStatus(): string { return this.status; }
  localName(): string {
    try {
      const name = btConnection.getLocalName();
      if (name && name.length > 0) return name;
    } catch (_) {}
    return '聊天设备';
  }
  localUid(): string { return installIdOf(this.context); }
  selfLabel(): string {
    return this.selfSlot > 0 ? '聊天设备' + String(this.selfSlot) : '';
  }
  private trustedList(): dm.DeviceBasicInfo[] {
    if (this.manager === null) return [];
    try {
      return this.manager.getAvailableDeviceListSync().filter((device: dm.DeviceBasicInfo) =>
        typeof device.networkId === 'string' && device.networkId.length > 0);
    } catch (_) { return []; }
  }
  private compactId(value: string): string {
    return value.replace(/:/g, '').toLowerCase();
  }
  private idsMatch(left: string, right: string): boolean {
    if (left.length === 0 || right.length === 0) return false;
    if (left === right) return true;
    const a = this.compactId(left);
    const b = this.compactId(right);
    return a.length >= 8 && b.length >= 8 && (a === b || a.indexOf(b) >= 0 || b.indexOf(a) >= 0);
  }
  private isTrustedPeer(peerId: string, name: string = ''): boolean {
    const trusted = this.trustedList();
    for (const device of trusted) {
      if (this.idsMatch(peerId, device.deviceId) || this.idsMatch(peerId, device.networkId || '')) return true;
      if (name.length > 0 && namesMatch(device.deviceName, name)) return true;
    }
    return false;
  }
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
    const ads = this.advertisedComputes();
    hilog.info(0, 'NearbyChat', 'compute ads=%{public}d available=%{public}d', ads.length, devices.length);
    if (ads.length === 0) return [];
    // Return one entry per advertised compute, not one per name match. Matching by
    // name collapsed two boxes that both call themselves 算力设备 into a single
    // list entry, and the unmatched case threw the whole list away.
    const matched: dm.DeviceBasicInfo[] = [];
    const rssi: number[] = [];
    for (let i = 0; i < ads.length; i++) {
      const hit = this.lastHits.find((item: BleHit) => item.mac === ads[i].mac);
      const name = hit !== undefined ? this.hitName(hit) : '';
      let linked: dm.DeviceBasicInfo | undefined = undefined;
      for (const device of devices) {
        if (name.length > 0 && namesMatch(device.deviceName, name)) {
          linked = device;
          break;
        }
      }
      if (linked === undefined) {
        // Not in the DeviceManager list (not paired yet): the MAC is still the only
        // handle we have, so keep the card and let connectAdvertiser decide.
        linked = this.virtualDevice(ads[i].mac, ads[i].name);
      }
      matched.push(linked);
      rssi.push(hit === undefined ? -9999 : hit.rssi);
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

  /**
   * A card for an advertised box that DeviceManager does not list yet. The empty
   * networkId is what marks it as a card rather than a dialable device: connect()
   * refuses an id that is not in devices(), so this can only be reached through
   * connectAdvertiser(mac), which speaks BLE and never reads networkId.
   */
  private virtualDevice(mac: string, name: string): dm.DeviceBasicInfo {
    const device: dm.DeviceBasicInfo = { deviceId: mac, deviceName: name, deviceType: '', networkId: '' };
    return device;
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
    const trusted: AdvertisedCompute[] = [];
    const seen: string[] = [];
    for (const hit of hits) {
      // A rotating BLE address makes the MAC useless as identity: dedupe on the
      // advertised fingerprint when we have one, and only fall back to the address.
      const mark = hit.key.length > 0 ? 'key:' + hit.key : 'mac:' + hit.mac;
      if (seen.indexOf(mark) >= 0) continue;
      const name = this.hitName(hit);
      if (!this.isTrustedPeer(hit.mac, name)) continue;
      seen.push(mark);
      const label = hit.slot >= 1 ? '算力设备' + String(hit.slot) : '算力设备';
      trusted.push(new AdvertisedCompute(label, hit.mac, hit.slot, hit.key));
    }
    return trusted;
  }

  /**
   * Every advertised compute, strongest signal first. Handing the caller a single
   * candidate is what made the chooser useless and what made a reconnect silently
   * land on whichever box happened to be strongest.
   */
  connectComputes(): AdvertisedCompute[] {
    // A chat client is never a coordinator. An unnumbered or slot-2 compute may
    // still be discovering the mesh, but only the elected slot-1 hub can accept
    // a chat request. Do not silently fall back to the strongest other box.
    return this.advertisedComputes().filter((item: AdvertisedCompute) => item.slot === 1);
  }

  private advertise(): void {
    try { ble.stopAdvertising(); } catch (_) {}
    const setting: ble.AdvertiseSetting = { interval: 160, connectable: true };
    const adv: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [computeManufacture(0, this.localUid())],
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
    if (this.trustedList().length === 0) {
      throw new Error('还没有已组网设备。请用同一华为账号在超级终端中连接后再试。');
    }
    this.update('正在连接算力设备…');
    // Hub-only, the same list connectComputes() hands the page: dialling a follower
    // ends with it dropping the link, so it is never a fallback worth taking.
    const macs = this.hubAdvertiserMacs();
    hilog.info(0, 'NearbyChat', 'le-connect trusted hubs=%{public}d', macs.length);
    if (macs.length === 0) {
      throw new Error('算力设备1尚未确定或不可用，请等待算力设备组网后重试。');
    }
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
    const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
    const name = hit !== undefined ? this.hitName(hit) : '';
    if (!this.isTrustedPeer(mac, name)) {
      throw new Error('附近的算力还没组网。请用同一华为账号在超级终端中连接后再试。');
    }
    this.update('正在连接算力设备…');
    hilog.info(0, 'NearbyChat', 'le-connect advertiser=%{public}s', mac);
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

  /** Trusted advertisers that announce slot 1; the only hosts a chat may dial. */
  private hubAdvertiserMacs(): string[] {
    return this.advertiserMacsMatching(true);
  }

  private advertiserMacsMatching(hubOnly: boolean): string[] {
    const macs: string[] = [];
    for (const mac of this.advertiserMacs('')) {
      const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
      if (hit === undefined) continue;
      if (hubOnly && hit.slot !== 1) continue;
      if (this.isTrustedPeer(mac, this.hitName(hit))) macs.push(mac);
    }
    return macs;
  }

  private scanHits(timeoutMs: number, computeOnly: boolean): Promise<BleHit[]> {
    this.cancelScan();
    // BLEDeviceFind and stopBLEScan are process-global. Finish an older discovery
    // before installing a new listener: the connect path retries computeDevices()
    // up to three times, and an older scan's timeout would otherwise stop the
    // radio and remove the listener out from under the newer one.
    return new Promise<BleHit[]>((resolve) => {
      const hits: BleHit[] = [];
      let timer: number = -1;
      let settled = false;
      const options: ble.ScanOptions = {
        interval: 0,
        dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
      };
      const collect = (results: Array<ble.ScanResult>): void => {
        for (const item of results) {
          let compute = false;
          let slot = 0;
          let key = '';
          try {
            slot = advComputeSlot(item.data);
            compute = slot >= 0;
            if (slot < 0) slot = 0;
            if (compute) key = advComputeKey(item.data);
          } catch (_) { compute = false; }
          const existing = hits.find((hit: BleHit) => hit.mac === item.deviceId);
          if (existing !== undefined) {
            if (compute) existing.compute = true;
            if (slot > existing.slot) existing.slot = slot;
            if (existing.key.length === 0 && key.length > 0) existing.key = key;
            if (existing.name.length === 0 && (item.deviceName || '').length > 0) existing.name = item.deviceName;
            continue;
          }
          const hit = new BleHit(item.deviceId, item.deviceName || '', item.rssi, compute, compute ? slot : 0,
            compute ? key : '');
          hits.push(hit);
          hilog.info(0, 'NearbyChat',
            'le-scan mac=%{public}s name=%{public}s rssi=%{public}d compute=%{public}s slot=%{public}d key=%{public}s',
            hit.mac, hit.name, hit.rssi, String(hit.compute), hit.slot, hit.key);
        }
      };
      const finish = (): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { ble.stopBLEScan(); } catch (_) {}
        try { ble.off('BLEDeviceFind', collect); } catch (_) {
          try { ble.off('BLEDeviceFind'); } catch (_) {}
        }
        if (this.scanCancel === finish) this.scanCancel = null;
        if (computeOnly) resolve(hits.filter((item: BleHit) => item.compute));
        else resolve(hits);
      };
      this.scanCancel = finish;
      try {
        ble.on('BLEDeviceFind', collect);
        try {
          ble.startBLEScan([{ manufactureId: COMPUTE_MANUFACTURE_ID }], options);
          hilog.info(0, 'NearbyChat', 'le-scan started manufacture');
        } catch (first) {
          if (this.server !== null || this.peers.length > 0) {
            hilog.warn(0, 'NearbyChat', 'le-scan skip unfiltered while serving code=%{public}s',
              String((first as BusinessError).code));
          } else {
            ble.startBLEScan(null, options);
            hilog.info(0, 'NearbyChat', 'le-scan started unfiltered after=%{public}s',
              String((first as BusinessError).code));
          }
        }
      } catch (error) {
        hilog.warn(0, 'NearbyChat', 'le-scan start failed code=%{public}s', String((error as BusinessError).code));
        finish();
        return;
      }
      timer = setTimeout(finish, timeoutMs);
    });
  }

  private cancelScan(): void {
    const cancel = this.scanCancel;
    this.scanCancel = null;
    cancel?.();
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
    const peer = new Peer(++this.epoch, peerId, incoming, fromServer);
    this.peers.push(peer);
    incoming.on('disconnected', (reason: number) => {
      hilog.info(0, 'NearbyChat', 'le-disconnect epoch=%{public}d role=compute peer=%{public}s reason=%{public}d',
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
    if (!IS_SERVER) this.write(peer, {
      type: 'hello', peerRole: 'chat', name: this.localName(), deviceUid: this.localUid()
    });
  }

  private receive(peer: Peer, message: WireMessage): void {
    if (!this.holds(peer)) return;
    hilog.info(0, 'NearbyChat', 'le-recv type=%{public}s epoch=%{public}d peer=%{public}s ready=%{public}s',
      message.type, peer.epoch, peer.peerId, String(peer.ready));
    if (!peer.ready) {
      if (IS_SERVER && message.type === 'hello' && !peer.hello) {
        const name = (typeof message.name === 'string' ? message.name : '');
        if (!this.isTrustedPeer(peer.peerId, name)) {
          hilog.warn(0, 'NearbyChat', 'le-hello untrusted peer=%{public}s name=%{public}s', peer.peerId, name);
          this.drop(peer, '不是同账号或可信设备，请先在超级终端中连接。');
          return;
        }
        peer.hello = true;
        peer.deviceUid = message.deviceUid || '';
        if (this.onMessage !== null) this.acknowledge(peer);
      } else if (!IS_SERVER && message.type === 'hello_ack' && peer.opened) {
        peer.deviceUid = message.deviceUid || '';
        if (typeof message.slot === 'number' && message.slot >= 1) this.selfSlot = Math.floor(message.slot);
        this.ready(peer);
      } else { this.drop(peer, '对端不是兼容的聊天应用。'); }
      return;
    }
    if (!IS_SERVER && message.type === 'hello_ack') {
      // The hub re-sends this when chat numbering changes. It is a live slot update,
      // not a stray frame: re-read the number and let the page retitle itself.
      if (typeof message.slot === 'number' && message.slot >= 1) {
        const slot = Math.floor(message.slot);
        if (slot !== this.selfSlot) {
          this.selfSlot = slot;
          hilog.info(0, 'NearbyChat', 'le-chat slot=%{public}d', slot);
        }
      }
      this.onConnection?.(true, peer.epoch);
      return;
    }
    if (!IS_SERVER && message.type === 'prepared') {
      if (message.requestId === peer.serviceId) this.completeServiceCheck(peer, message.error || '');
      return;
    }
    const allowed = IS_SERVER ? ['prepare', 'request', 'cancel'] : ['delta', 'done', 'error', 'deviceInfo', 'deviceInfoSync'];
    if (!allowed.includes(message.type) || this.onMessage === null) {
      hilog.warn(0, 'NearbyChat', 'le-ignore type=%{public}s epoch=%{public}d', message.type, peer.epoch);
      return;
    }
    this.onMessage(message, peer.epoch);
  }

  private acknowledge(peer: Peer): void {
    if (!this.holds(peer) || peer.ready) return;
    this.write(peer, { type: 'hello_ack', peerRole: 'compute', deviceUid: this.localUid() });
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
    peer.writes = peer.writes.then(async (): Promise<boolean> => {
      try {
        for (const frame of frames) {
          if (!await this.sendFrame(peer, frame)) return false;
        }
        return this.holds(peer);
      } finally { --peer.pending; }
    });
    return peer.writes;
  }

  private sendFrame(peer: Peer, frame: string, attempt: number = 0): Promise<boolean> {
    if (!this.holds(peer)) return Promise.resolve(false);
    const data = toBuffer(frame);
    if (data.byteLength < 1 || data.byteLength > 1024) {
      hilog.error(0, 'NearbyChat', 'le-send rejected bytes=%{public}d', data.byteLength);
      return Promise.resolve(false);
    }
    try {
      peer.connection.sendData(data);
      return Promise.resolve(true);
    } catch (error) {
      const code = (error as BusinessError).code;
      if ((code === 32390205 || code === 32390206 || code === 32390300) && attempt < 2) {
        hilog.warn(0, 'NearbyChat', 'le-send retry code=%{public}s bytes=%{public}d attempt=%{public}d',
          String(code), data.byteLength, attempt + 1);
        return new Promise<boolean>(resolve => setTimeout(() => {
          this.sendFrame(peer, frame, attempt + 1).then(resolve);
        }, 120 * (attempt + 1)));
      }
      hilog.error(0, 'NearbyChat', 'le-send failed code=%{public}s bytes=%{public}d', String(code), data.byteLength);
      // 32390206 is a local parameter rejection. Dropping a healthy link turned one
      // rejected telemetry frame into an endless disconnect/reconnect loop.
      if (code !== 32390206) this.drop(peer, '消息发送失败，请重新连接。');
      return Promise.resolve(false);
    }
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
    this.cancelScan();
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
