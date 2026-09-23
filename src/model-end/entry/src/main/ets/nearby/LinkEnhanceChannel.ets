import { distributedDeviceManager as dm, linkEnhance } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection as btConnection, ble } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { encodeMessage, MessageAssembler, WireMessage, DeviceInfoEntry } from '../protocol/ChatProtocol';
import { COMPUTE_ADV_KEY_BYTES, COMPUTE_ADV_TYPE, COMPUTE_MANUFACTURE_ID, IS_SERVER } from './NearbyConfig';
import { RankMember, freezeComputeRank, freezeNameRank, rankNames, slotOf } from '../cluster/ClusterRoster';

const BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-compute';
const CONNECT_TRY_MS = 8000;
const SERVER_RESTART_DELAYS: number[] = [800, 2500, 7000, 15000];
const ADVERTISE_RETRY_DELAYS: number[] = [1000, 3000, 8000, 20000, 30000];
const ADV_STATE_WAIT_MS: number = 2000;
const HUB_ELECTION_MS = 10000;
const HUB_FAILOVER_MS = 15000;
const HUB_MISSING_SCANS = 3;
const COMPUTE_SCAN_MS = 4500;

class BleHit {
  observation: number = 0;
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

function namesMatch(left: string, right: string): boolean {
  return left.length > 0 && right.length > 0 &&
    (left === right || left.indexOf(right) >= 0 || right.indexOf(left) >= 0);
}

/**
 * A random id drawn once per install and kept in preferences, so a peer can tell
 * two boxes apart even when both are called 算力设备 and the BLE address rotates.
 * Falls back to the local name when preferences are unavailable, which degrades to
 * the old behaviour rather than to a crash.
 */
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
  } catch (_) {
    return '';
  }
}

function randomId(): string {
  let id = '';
  while (id.length < 16) {
    id += Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0');
  }
  return id.substring(0, 16);
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

/**
 * Offset of the manufacturer payload inside a raw advertisement, or -1 when
 * this is not one of our compute advertisements.
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

/** Advertised compute slot, or -1 when the advertisement is not ours. */
function advComputeSlot(data: ArrayBuffer): number {
  const at = advComputeOffset(data);
  if (at < 0) return -1;
  const bytes = new Uint8Array(data);
  return at + 1 < bytes.length ? bytes[at + 1] : 0;
}

/**
 * Advertised identity fingerprint, or '' when this is not our advertisement or
 * the sender predates the fingerprint field. Random BLE addresses change on
 * every reconnect, so the payload is the only stable handle on a peer.
 */
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

class PeerInfo {
  epoch: number = 0;
  peerId: string = '';
  ready: boolean = false;
  name: string = '';
  role: string = '';
  helloName: string = '';
  slot: number = 0;
  deviceUid: string = '';
}

class Peer {
  epoch: number;
  peerId: string;
  slot: number = 0;
  computeSlot: number = 0;
  connection: linkEnhance.Connection;
  deviceUid: string = '';
  fromServer: boolean;
  ready: boolean = false;
  opened: boolean = false;
  hello: boolean = false;
  role: string = '';
  helloName: string = '';
  memAvail: number = -1;
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
  private selfSlot: number = 0;
  private selfComputeSlot: number = 0;
  private lastAdvertisedSlot: number = -1;
  private advertising: boolean = false;
  private rankingSlots: boolean = false;
  private advertiseTimer: number = -1;
  private selfMem: number = -1;
  private frozenComputeKeys: string[] = [];
  private hubLostAt: number = 0;
  private hubMissingScans: number = 0;
  private leadershipPinned: boolean = false;
  private frozenChatKeys: string[] = [];
  private remoteChatKeys: string[] = [];
  private meshSettled: boolean = false;
  private meshBusy: boolean = false;
  private meshRun: number = 0;
  private meshTries: number = 0;
  private meshLastScanAt: number = 0;
  private electionReady: boolean = false;
  private electionTimer: number = -1;
  private activeJobs: number = 0;
  private scanCancel: (() => void) | null = null;
  private lastScanComplete: boolean = false;
  private hubRecoveryUntil: number = 0;
  private advertisingId: number = -1;
  private advertisingStopId: number = -1;
  private advertisingWork: Promise<void> | null = null;
  private advertisingPending: boolean = false;
  private advertisingListening: boolean = false;
  private advertisingEvents: Map<number, ble.AdvertisingState> = new Map();
  private advertisingWaitId: number = -1;
  private advertisingWaitTimer: number = -1;
  private advertisingWaitDone: ((ok: boolean) => void) | null = null;
  private advertisingWaitAccept: ((state: ble.AdvertisingState) => boolean) | null = null;
  private advertisingChanged = (info: ble.AdvertisingStateChangeInfo): void => {
    this.advertisingEvents.set(info.advertisingId, info.state);
    hilog.info(0, 'NearbyChat', 'le-adv state id=%{public}d state=%{public}d', info.advertisingId, info.state);
    this.notifyAdvertisingWait(info.advertisingId, info.state);
    // An ID we asked to stop must not look like an unexpected radio death, or the
    // takeover start is delayed by a retry of the advertisement we just replaced.
    if (info.advertisingId === this.advertisingStopId) return;
    if (info.advertisingId !== this.advertisingId) return;
    if (info.state === ble.AdvertisingState.DISABLED || info.state === ble.AdvertisingState.STOPPED) {
      this.advertising = false;
      if (info.state === ble.AdvertisingState.STOPPED) this.advertisingId = -1;
      this.lastAdvertisedSlot = -1;
      this.scheduleAdvertiseRetry();
    }
  };
  private advertiseRetryAttempt: number = 0;
  private advertiseRetryTimer: number = -1;
  private serverWanted: boolean = false;
  private serverRetryTimer: number = -1;
  private serverRetryAttempt: number = 0;
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
  hasEpoch(epoch: number): boolean { return this.peers.some((item: Peer) => item.epoch === epoch); }
  getStatus(): string { return this.status; }
  peerInfos(): PeerInfo[] {
    const result: PeerInfo[] = [];
    const seen: string[] = [];
    for (const peer of this.peers) {
      if (peer.role.length === 0) continue;
      // Deduplicate on the link, not on the display name: every compute box that
      // has no slot yet is called 算力设备, and keying on that name hid the second
      // one entirely (算力设备1 上看不到 2).
      const key = peer.deviceUid.length > 0 ? 'uid:' + peer.deviceUid :
        (peer.peerId.length > 0 ? 'id:' + this.compactId(peer.peerId) : 'epoch:' + String(peer.epoch));
      if (seen.indexOf(key) >= 0) continue;
      seen.push(key);
      const info = new PeerInfo();
      info.epoch = peer.epoch;
      info.peerId = peer.peerId;
      info.ready = peer.ready;
      info.role = peer.role;
      info.helloName = peer.helloName;
      info.slot = peer.slot;
      info.deviceUid = peer.deviceUid;
      if (peer.role === 'compute') {
        info.slot = peer.computeSlot;
        info.name = peer.computeSlot > 0 ? '算力设备' + String(peer.computeSlot) : '算力设备';
      } else {
        info.name = peer.slot > 0 ? '聊天设备' + String(peer.slot) : '聊天设备';
      }
      result.push(info);
    }
    return result;
  }
  peerRole(epoch: number): string {
    const peer = this.peers.find((item: Peer) => item.epoch === epoch);
    return peer === undefined ? '' : peer.role;
  }
  localName(): string {
    try {
      const name = btConnection.getLocalName();
      if (name && name.length > 0) return name;
    } catch (_) {}
    return '算力设备';
  }
  localUid(): string { return installIdOf(this.context); }
  selfLabel(): string {
    if (IS_SERVER) {
      return this.selfComputeSlot > 0 ? '算力设备' + String(this.selfComputeSlot) : '算力设备';
    }
    return this.selfSlot > 0 ? '聊天设备' + String(this.selfSlot) : '';
  }
  selfComputeNumber(): number {
    return this.selfComputeSlot;
  }
  /** Discovery is suspended while any request uses the radio or model engine. */
  setActiveJobs(count: number): void {
    const next = Math.max(0, count);
    if (this.activeJobs === next) return;
    this.activeJobs = next;
    if (next > 0 && this.meshBusy) {
      ++this.meshRun;
      this.meshBusy = false;
      this.meshTries = 0;
      this.meshLastScanAt = 0;
      this.cancelScan();
    }
    if (next === 0) {
      this.refreshAdvertisedSlot();
      this.dropNonHubChats();
      this.pruneWorkerLinks();
    }
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

  /**
   * Identity we put in the advertisement. The BLE address is random per connection
   * and the display name is not unique (every unranked box is 算力设备), so the
   * stable handle is a random id drawn once per install and kept in preferences.
   * It is a deduplication hint only — trust still comes from isTrustedPeer, and
   * nothing is authorized on the strength of a matching fingerprint.
   */
  private advertiseKey(): string {
    return this.localUid();
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
    if (name.length === 0) {
      const resolved = this.peerName(peerId);
      if (resolved.length > 0 && resolved !== '聊天设备' && resolved !== '算力设备') {
        for (const device of trusted) {
          if (namesMatch(device.deviceName, resolved)) return true;
        }
      }
    }
    return false;
  }
  private peerName(peerId: string): string {
    try {
      const name = btConnection.getRemoteDeviceName(peerId);
      if (name && name.length > 0) return name;
    } catch (_) {}
    if (this.manager !== null) {
      const devices = this.manager.getAvailableDeviceListSync();
      for (const device of devices) {
        if (device.deviceId === peerId && device.deviceName) return device.deviceName;
      }
    }
    for (const hit of this.lastHits) {
      if (hit.mac === peerId && hit.name.length > 0) return hit.name;
    }
    return '聊天设备';
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
    this.serverWanted = true;
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
        const existing = this.peers.find((item: Peer) => this.idsMatch(item.peerId, peerId));
        if (existing !== undefined) this.drop(existing, '对端重新连接。');
        this.attach(incoming, peerId, true);
      });
      server.on('serverStopped', (reason: number) => {
        if (this.server !== server) return;
        hilog.warn(0, 'NearbyChat', 'le-server stopped reason=%{public}d', reason);
        this.server = null;
        // This callback cannot be caused by the user's stop: disconnect() detaches
        // this.server before calling server.stop(). Preserve the enabled intent and
        // rebuild the listener/advertisement instead of leaving the UI enabled but
        // undiscoverable.
        this.disconnect(true);
        this.update('增强连接服务已停止（' + String(reason) + '），正在自动恢复近场…');
      });
      server.start();
      this.server = server;
      this.meshSettled = false;
      this.meshTries = 0;
      this.meshLastScanAt = 0;
      this.selfComputeSlot = slotOf(this.frozenComputeKeys, this.computeKey(this.localUid(), this.localName()));
      this.electionReady = this.selfComputeSlot > 0;
      this.advertise();
      this.electionTimer = setTimeout(() => {
        this.electionTimer = -1;
        if (this.server !== server || !this.serverWanted) return;
        this.electionReady = true;
        this.refreshComputeSlots();
      }, HUB_ELECTION_MS);
      this.cancelServerRestart();
      this.serverRetryAttempt = 0;
      let localName = '';
      try { localName = btConnection.getLocalName(); } catch (_) {}
      hilog.info(0, 'NearbyChat', 'le-server start name=%{public}s local=%{public}s slot=%{public}d',
        SERVICE, localName, this.selfComputeSlot);
      this.update('可本机对话 · 等待聊天手机连接');
    } catch (error) {
      this.serverWanted = false;
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

  private advertise(): void {
    // Serialise the asynchronous stop/start operations. The legacy void API only
    // accepted a request; it did not confirm that a replacement was on the air.
    if (this.advertisingWork !== null) {
      this.advertisingPending = true;
      return;
    }
    this.advertisingWork = this.syncAdvertising().catch((error: BusinessError) => {
      hilog.warn(0, 'NearbyChat', 'le-adv reconcile failed code=%{public}s', String(error.code));
      this.scheduleAdvertiseRetry();
    }).finally(() => {
      this.advertisingWork = null;
      if (this.advertisingPending) {
        this.advertisingPending = false;
        this.advertise();
      }
    });
  }

  private wantsAdvertising(): boolean {
    return IS_SERVER && this.serverWanted && this.foreground && this.server !== null;
  }

  private finishAdvertisingWait(ok: boolean): void {
    const resolve = this.advertisingWaitDone;
    if (this.advertisingWaitTimer !== -1) {
      clearTimeout(this.advertisingWaitTimer);
      this.advertisingWaitTimer = -1;
    }
    this.advertisingWaitId = -1;
    this.advertisingWaitAccept = null;
    this.advertisingWaitDone = null;
    resolve?.(ok);
  }

  private notifyAdvertisingWait(id: number, state: ble.AdvertisingState): void {
    if (this.advertisingWaitDone === null || id !== this.advertisingWaitId) return;
    const accept = this.advertisingWaitAccept;
    if (accept !== null && accept(state)) this.finishAdvertisingWait(true);
  }

  private waitAdvertisingState(id: number, accept: (state: ble.AdvertisingState) => boolean): Promise<boolean> {
    const seen = this.advertisingEvents.get(id);
    if (seen !== undefined && accept(seen)) return Promise.resolve(true);
    if (this.advertisingWaitDone !== null) this.finishAdvertisingWait(false);
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      this.advertisingWaitId = id;
      this.advertisingWaitAccept = accept;
      this.advertisingWaitDone = resolve;
      const again = this.advertisingEvents.get(id);
      if (again !== undefined && accept(again)) {
        this.finishAdvertisingWait(true);
        return;
      }
      this.advertisingWaitTimer = setTimeout(() => {
        if (this.advertisingWaitId !== id) return;
        this.finishAdvertisingWait(false);
      }, ADV_STATE_WAIT_MS);
    });
  }

  private liveAdvertising(state: ble.AdvertisingState | undefined): boolean {
    return state === ble.AdvertisingState.STARTED || state === ble.AdvertisingState.ENABLED;
  }

  private deadAdvertising(state: ble.AdvertisingState | undefined): boolean {
    return state === ble.AdvertisingState.STOPPED || state === ble.AdvertisingState.DISABLED;
  }

  private async syncAdvertising(): Promise<void> {
    if (this.wantsAdvertising() && this.advertising && this.lastAdvertisedSlot === this.selfComputeSlot) return;
    this.ensureAdvertisingListener();
    if (this.advertisingId >= 0) {
      const oldId = this.advertisingId;
      this.advertising = false;
      this.lastAdvertisedSlot = -1;
      this.advertisingStopId = oldId;
      try {
        try { await ble.stopAdvertising(oldId); }
        catch (error) {
          // An already-released ID needs no further stop. Other errors must retry
          // cleanup, not start overlapping advertisements with an unknown old ID.
          if ((error as BusinessError).code !== 2902055) {
            throw new Error('stop advertising failed code=' + String((error as BusinessError).code));
          }
          this.advertisingEvents.set(oldId, ble.AdvertisingState.STOPPED);
        }
        if (this.advertisingEvents.get(oldId) !== ble.AdvertisingState.STOPPED) {
          await this.waitAdvertisingState(oldId, (state: ble.AdvertisingState) =>
            state === ble.AdvertisingState.STOPPED);
        }
      } finally {
        if (this.advertisingStopId === oldId) this.advertisingStopId = -1;
        if (this.advertisingId === oldId) this.advertisingId = -1;
        this.advertisingEvents.delete(oldId);
        hilog.info(0, 'NearbyChat', 'le-adv stopped id=%{public}d', oldId);
      }
    }
    if (!this.wantsAdvertising()) {
      if (this.advertisingListening) {
        ble.off('advertisingStateChange', this.advertisingChanged);
        this.advertisingListening = false;
      }
      return;
    }
    const operation = this.lifecycle;
    const slot = this.selfComputeSlot;
    const setting: ble.AdvertiseSetting = { interval: 160, connectable: true };
    const adv: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [computeManufacture(slot, this.advertiseKey())],
      serviceData: [],
      includeDeviceName: false
    };
    const response: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [],
      includeDeviceName: true
    };
    let startedId = -1;
    try {
      startedId = await ble.startAdvertising({ advertisingSettings: setting,
        advertisingData: adv, advertisingResponse: response, duration: 0 });
    } catch (first) {
      hilog.warn(0, 'NearbyChat', 'le-adv type+name failed code=%{public}s', String((first as BusinessError).code));
      if (operation !== this.lifecycle || !this.wantsAdvertising()) return;
      startedId = await ble.startAdvertising({ advertisingSettings: setting,
        advertisingData: adv, duration: 0 });
    }
    this.advertisingId = startedId;
    // A late successful start after disable/re-enable belongs to the old
    // lifecycle. The queued reconciliation will dispose of that exact ID.
    if (operation !== this.lifecycle || !this.wantsAdvertising() || slot !== this.selfComputeSlot) {
      this.advertisingPending = true;
      return;
    }
    if (!this.liveAdvertising(this.advertisingEvents.get(startedId)) &&
      !this.deadAdvertising(this.advertisingEvents.get(startedId))) {
      await this.waitAdvertisingState(startedId, (state: ble.AdvertisingState) =>
        this.liveAdvertising(state) || this.deadAdvertising(state));
    }
    if (operation !== this.lifecycle || !this.wantsAdvertising() || slot !== this.selfComputeSlot ||
      this.advertisingId !== startedId) {
      this.advertisingPending = true;
      return;
    }
    const state = this.advertisingEvents.get(startedId);
    if (!this.liveAdvertising(state)) {
      hilog.warn(0, 'NearbyChat', 'le-adv not on-air id=%{public}d state=%{public}s',
        startedId, String(state === undefined ? -1 : state));
      if (this.deadAdvertising(state) && state === ble.AdvertisingState.STOPPED) this.advertisingId = -1;
      this.scheduleAdvertiseRetry();
      return;
    }
    this.advertising = true;
    this.lastAdvertisedSlot = slot;
    this.advertiseRetryAttempt = 0;
    this.cancelAdvertiseRetry();
    hilog.info(0, 'NearbyChat', 'le-adv confirmed id=%{public}d slot=%{public}d', this.advertisingId, slot);
  }

  private ensureAdvertisingListener(): void {
    if (this.advertisingListening) return;
    ble.on('advertisingStateChange', this.advertisingChanged);
    this.advertisingListening = true;
  }

  private scheduleAdvertiseRetry(): void {
    if (!IS_SERVER || (!this.wantsAdvertising() && this.advertisingId < 0) || this.advertiseRetryTimer !== -1) return;
    const at = Math.min(this.advertiseRetryAttempt, ADVERTISE_RETRY_DELAYS.length - 1);
    const delay = ADVERTISE_RETRY_DELAYS[at];
    this.advertiseRetryAttempt++;
    this.advertiseRetryTimer = setTimeout(() => {
      this.advertiseRetryTimer = -1;
      if (this.advertising) return;
      this.advertise();
    }, delay);
  }

  private cancelAdvertiseRetry(): void {
    if (this.advertiseRetryTimer === -1) return;
    clearTimeout(this.advertiseRetryTimer);
    this.advertiseRetryTimer = -1;
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
    const macs = this.connectComputes();
    hilog.info(0, 'NearbyChat', 'le-connect trusted hubs=%{public}d', macs.length);
    if (macs.length === 0) {
      throw new Error('算力设备1尚未确定或不可用，请等待算力设备组网后重试。');
    }
    for (const mac of macs) {
      this.checkOperation(operation);
      if (this.peers.length > 0) return;
      if (mac.length === 0) continue;
      hilog.info(0, 'NearbyChat', 'le-connect attempting mac=%{public}s', mac);
      const ok = await this.tryConnect('compute', mac);
      hilog.info(0, 'NearbyChat', 'le-connect attempted mac=%{public}s ok=%{public}s', mac, String(ok));
      if (ok) return;
    }
    throw new Error('增强连接失败：未找到可用的蓝牙地址。');
  }

  /** 算力机再连其它算力广播，供调度选点。失败忽略。 */
  async connectOtherComputes(operation: number = this.lifecycle): Promise<void> {
    // BLE discovery on the hub overlaps LinkEnhance's radio traffic. The live
    // trace shows chat links dropping during the idle discovery burst, so defer
    // rediscovery while any chat session is attached. Startup election finishes
    // before chats can connect because slot 1 is not advertised until then.
    if (!IS_SERVER || this.meshBusy || this.activeJobs > 0 ||
      this.peers.some((peer: Peer) => peer.ready && peer.role === 'chat')) return;
    // After takeover, leave the radio available for advertisement and incoming
    // chat handshakes instead of starting another scan 2.5 seconds later.
    if (this.selfComputeSlot === 1 && (this.advertisingWork !== null || Date.now() < this.hubRecoveryUntil)) return;
    if (this.selfComputeSlot > 1 && this.peers.some((peer: Peer) =>
      peer.ready && peer.role === 'compute' && peer.computeSlot === 1)) return;
    const now = Date.now();
    // Keep a low-duty discovery pass after the startup burst. Otherwise every
    // surviving compute permanently stops scanning before a disabled peer returns.
    if (this.selfComputeSlot <= 1 && this.meshTries >= 4 && now - this.meshLastScanAt <
      (this.computeLinkCount() > 0 ? 120000 : 30000)) return;
    this.meshBusy = true;
    const run = ++this.meshRun;
    this.meshTries++;
    this.meshLastScanAt = now;
    try {
      this.checkOperation(operation);
      let localName = '';
      try { localName = btConnection.getLocalName(); } catch (_) {}
      this.lastHits = await this.scanHits(COMPUTE_SCAN_MS, true);
      this.checkOperation(operation);
      if (this.activeJobs > 0 || this.peers.some((peer: Peer) => peer.ready && peer.role === 'chat')) return;
      this.considerHubFailover();
      const macs = this.trustedAdvertiserMacs();
      const localKey = advKeyOf(this.localUid());
      hilog.info(0, 'NearbyChat', 'le-mesh scan trusted=%{public}d peers=%{public}d',
        macs.length, this.peers.length);
      // The four-try cap used to be permanent, so one bad scan window disabled mesh
      // discovery for the rest of the session. Reset it while there is still an
      // unconnected advertiser in range, and let it stay capped when there isn't.
      for (const mac of macs) {
        const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
        if (hit !== undefined && !this.hasHitPeer(hit)) {
          this.meshTries = 0;
          break;
        }
      }
      for (const mac of macs) {
        this.checkOperation(operation);
        if (mac.length === 0) continue;
        const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
        if (hit === undefined || this.hasHitPeer(hit)) continue;
        const hitName = hit !== undefined ? this.hitName(hit) : '';
        if (hit.key.length > 0 && localKey.length > 0 && hit.key === localKey) continue;
        // Once numbered, workers must only link to the hub, never one another.
        if (this.selfComputeSlot > 1 && hit.slot > 1) continue;
        // An unnumbered/new worker and a returning follower dial an advertised
        // hub themselves. The hub can therefore suspend discovery while chats
        // are attached without preventing workers from joining or recovering.
        if (hit.slot === 1 && this.selfComputeSlot !== 1) {
          await this.tryConnect('compute', mac);
          continue;
        }
        if (this.selfComputeSlot === 1 && hit.slot === 0) continue;
        if (hit.key.length === 0 && localName.length > 0 && namesMatch(localName, hitName)) continue;
        // Exactly one side dials. The old fallback made both sides dial after the
        // same scan, producing two sessions for one physical compute box.
        if (hit.key.length > 0 && localKey.length > 0 && localKey <= hit.key) continue;
        if (hit.key.length === 0 && localName.length > 0 && hitName.length > 0 && localName <= hitName) continue;
        await this.tryConnect('compute', mac);
      }
    } finally {
      // A scan cancelled by stop/re-enable belongs to the old lifecycle. It must
      // not clear meshBusy or mark the replacement mesh settled after a new scan
      // has already started.
      if (run === this.meshRun) {
        this.meshBusy = false;
        if (operation === this.lifecycle && this.foreground) {
          this.meshSettled = true;
          this.refreshComputeSlots();
        }
      }
    }
  }

  /** How many compute links this device holds; used to decide whether to keep scanning. */
  private computeLinkCount(): number {
    let count = 0;
    for (const peer of this.peers) {
      if (peer.role === 'compute') count++;
    }
    return count;
  }

  /** Promote the next ranked worker only after repeated scans find no old hub. */
  private considerHubFailover(): void {
    if (this.selfComputeSlot < 2 || !this.lastScanComplete ||
      this.peers.some((peer: Peer) => peer.ready && peer.role === 'compute' && peer.computeSlot === 1)) return;
    if (this.hubLostAt === 0) this.hubLostAt = Date.now();
    const localKey = advKeyOf(this.localUid());
    const previousHub = this.frozenComputeKeys[0] || '';
    const previousHubKey = previousHub.indexOf('uid:') === 0 ? advKeyOf(previousHub.substring(4)) : '';
    const formerHubVisible = this.lastHits.some((hit: BleHit) => hit.compute && hit.key !== localKey &&
      ((previousHubKey.length > 0 && hit.key === previousHubKey) ||
        (hit.slot === 1 && this.isTrustedPeer(hit.mac, this.hitName(hit)))));
    if (formerHubVisible) {
      this.hubMissingScans = 0;
      return;
    }
    this.hubMissingScans++;
    if (this.hubMissingScans < HUB_MISSING_SCANS || Date.now() - this.hubLostAt < HUB_FAILOVER_MS) return;
    const self = this.computeKey(this.localUid(), this.localName());
    // Every worker evaluates the same previous rank. Keep only surviving known
    // identities; the highest-ranked survivor is the sole takeover candidate.
    const survivors = this.frozenComputeKeys.slice(1).filter((key: string) => key === self ||
      this.peers.some((peer: Peer) => peer.ready && peer.role === 'compute' &&
        this.computeKey(peer.deviceUid || peer.peerId, peer.helloName) === key) ||
      (key.indexOf('uid:') === 0 && this.lastHits.some((hit: BleHit) => hit.compute &&
        hit.key === advKeyOf(key.substring(4)))));
    if (survivors.length === 0 || survivors[0] !== self) return;
    this.frozenComputeKeys = survivors;
    this.hubRecoveryUntil = Date.now() + 20000;
    this.leadershipPinned = true;
    this.hubLostAt = 0;
    this.hubMissingScans = 0;
    hilog.warn(0, 'NearbyChat', 'le-hub failover self=%{public}s', self);
    this.applyComputeSlots();
    this.update('已接管为算力设备1，等待聊天设备重连…');
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

  private trustedAdvertiserMacs(): string[] {
    return this.advertiserMacsMatching(false);
  }

  /**
   * Trusted advertisers that announce slot 1, strongest signal first. A chat client
   * may only ever dial the elected hub: a follower answers a chat hello by dropping
   * the link with 「请连接算力设备1。」, so dialling one is an endless connect/drop loop
   * rather than a working session. Both the named path (computeDevices) and the
   * unnamed fallback in the page go through this list.
   */
  connectComputes(): string[] {
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
    // BLEDeviceFind and stopBLEScan are process-global. Finish an older discovery
    // before installing a new listener, especially across a rapid stop/start.
    this.cancelScan();
    return new Promise<BleHit[]>((resolve) => {
      const hits: BleHit[] = [];
      let observation = 0;
      let timer: number = -1;
      let settled = false;
      let started = false;
      this.lastScanComplete = false;
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
            if (compute) {
              existing.compute = true;
              // A valid slot 0 withdraws an old hub claim after restart. Only a
              // name-only response (compute=false) must preserve the last slot.
              existing.slot = slot;
              existing.observation = ++observation;
            }
            if (key.length > 0) existing.key = key;
            if (existing.name.length === 0 && (item.deviceName || '').length > 0) existing.name = item.deviceName;
            continue;
          }
          const hit = new BleHit(item.deviceId, item.deviceName || '', item.rssi, compute, compute ? slot : 0,
            compute ? key : '');
          if (compute) hit.observation = ++observation;
          hits.push(hit);
          hilog.info(0, 'NearbyChat',
            'le-scan mac=%{public}s name=%{public}s rssi=%{public}d compute=%{public}s slot=%{public}d key=%{public}s',
            hit.mac, hit.name, hit.rssi, String(hit.compute), hit.slot, hit.key);
        }
      };
      const finish = (completed: boolean = true): void => {
        if (settled) return;
        settled = true;
        this.lastScanComplete = completed && started;
        clearTimeout(timer);
        try { ble.stopBLEScan(); } catch (_) {}
        try { ble.off('BLEDeviceFind', collect); } catch (_) {
          try { ble.off('BLEDeviceFind'); } catch (_) {}
        }
        if (this.scanCancel === cancel) this.scanCancel = null;
        if (computeOnly) resolve(hits.filter((item: BleHit) => item.compute));
        else resolve(hits);
      };
      const cancel = (): void => finish(false);
      this.scanCancel = cancel;
      try {
        ble.on('BLEDeviceFind', collect);
        try {
          ble.startBLEScan([{ manufactureId: COMPUTE_MANUFACTURE_ID }], options);
          started = true;
          hilog.info(0, 'NearbyChat', 'le-scan started manufacture');
        } catch (first) {
          if (this.server !== null || this.peers.length > 0) {
            hilog.warn(0, 'NearbyChat', 'le-scan skip unfiltered while serving code=%{public}s',
              String((first as BusinessError).code));
          } else {
            ble.startBLEScan(null, options);
            started = true;
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

  private cancelServerRestart(): void {
    if (this.serverRetryTimer === -1) return;
    clearTimeout(this.serverRetryTimer);
    this.serverRetryTimer = -1;
  }

  private scheduleServerRestart(): void {
    if (!IS_SERVER || !this.serverWanted || !this.foreground || this.context === null ||
      this.server !== null || this.serverRetryTimer !== -1) return;
    const at = Math.min(this.serverRetryAttempt, SERVER_RESTART_DELAYS.length - 1);
    const delay = SERVER_RESTART_DELAYS[at];
    this.serverRetryAttempt++;
    this.serverRetryTimer = setTimeout(() => {
      this.serverRetryTimer = -1;
      if (!this.serverWanted || !this.foreground || this.context === null || this.server !== null) return;
      try {
        this.startServer();
      } catch (_) {
        // startServer clears the intent on an ordinary startup failure. This path
        // is recovery from a previously enabled service, so retain it and back off.
        this.serverWanted = true;
        this.scheduleServerRestart();
      }
    }, delay);
  }

  private tryConnect(kind: string, deviceId: string): Promise<boolean> {
    const operation = this.lifecycle;
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
          if (settled || operation !== this.lifecycle || !this.foreground) {
            // A timed-out or disabled attempt must not attach a late connection.
            if (handle !== null && (operation !== this.lifecycle || !this.peers.some((peer: Peer) => peer.connection === handle))) {
              try { handle.close(); } catch (_) {}
            }
            finish(false);
            return;
          }
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

  setSelfMem(memAvail: number): void {
    if (this.selfMem === memAvail) return;
    this.selfMem = memAvail;
    this.refreshComputeSlots();
  }

  setPeerMem(epoch: number, memAvail: number): void {
    const peer = this.peers.find((item: Peer) => item.epoch === epoch);
    if (peer === undefined || peer.memAvail === memAvail) return;
    peer.memAvail = memAvail;
    this.refreshComputeSlots();
  }

  setRemoteChats(names: string[]): void {
    this.remoteChatKeys = rankNames(names);
    this.refreshChatSlots();
  }

  /**
   * Only the link id identifies a peer. Fuzzy name matching used to be in here so a
   * reconnect could close the old link, but every unranked box advertises the same
   * name — it closed healthy links and made the app "连上 1 又去连 2". The server
   * drops a reconnect by exact peer id when it accepts the new session.
   *
   * `name` is still accepted for call sites that only have a name to offer, but it
   * is never matched: a name alone cannot say which peer is meant.
   */
  private hasPeer(peerId: string, name: string): boolean {
    if (peerId.length === 0) return false;
    for (const peer of this.peers) {
      if (peer.peerId === peerId) return true;
    }
    return false;
  }

  private hasHitPeer(hit: BleHit): boolean {
    for (const peer of this.peers) {
      if (peer.peerId === hit.mac || this.idsMatch(peer.peerId, hit.mac)) return true;
      if (hit.key.length > 0 && peer.deviceUid.length > 0 && advKeyOf(peer.deviceUid) === hit.key) return true;
    }
    return false;
  }

  applyRemoteRoster(fromEpoch: number, devices: DeviceInfoEntry[]): boolean {
    const reporter = this.peers.find((peer: Peer) => peer.epoch === fromEpoch && peer.role === 'compute');
    if (!IS_SERVER || reporter === undefined) return false;
    const reporterKey = this.computeKey(reporter.deviceUid || reporter.peerId, reporter.helloName);
    const self = this.computeKey(this.localUid(), this.localName());
    const ordered: (string | undefined)[] = [];
    for (const entry of devices) {
      const role = entry.role || '';
      if (role !== 'compute' && role !== 'self') continue;
      const slot = entry.slot === undefined ? 0 : entry.slot;
      if (!Number.isInteger(slot) || slot < 1 || slot > 64) return false;
      const key = this.computeKey(entry.deviceUid || entry.id || '', entry.name || '');
      if (key.length === 0) return false;
      while (ordered.length < slot) ordered.push(undefined);
      if (ordered[slot - 1] !== undefined || ordered.indexOf(key) >= 0) return false;
      ordered[slot - 1] = key;
    }
    const keys: string[] = [];
    for (const key of ordered) {
      if (key === undefined || key.length === 0) return false;
      keys.push(key);
    }
    // Only a connected center may assign the global slots. Worker snapshots
    // cannot overwrite them. Resolve reunited centers by the same stable key.
    if (keys.length === 0 || keys[0] !== reporterKey) return false;
    if (this.selfComputeSlot === 1 && self < reporterKey) return false;
    if (slotOf(keys, self) === 0) return false;
    this.frozenComputeKeys = keys;
    this.leadershipPinned = false;
    this.applyComputeSlots();
    this.pruneWorkerLinks();
    return true;
  }

  private applyComputeSlots(): void {
    const self = this.computeKey(this.localUid(), this.localName());
    const previous = this.selfComputeSlot;
    const next = slotOf(this.frozenComputeKeys, self);
    this.selfComputeSlot = next > 0 ? next : previous;
    for (const peer of this.peers) {
      if (peer.role !== 'compute') continue;
      const assigned = slotOf(this.frozenComputeKeys,
        this.computeKey(peer.deviceUid || peer.peerId, peer.helloName || this.peerName(peer.peerId)));
      if (assigned > 0) peer.computeSlot = assigned;
    }
    if (this.selfComputeSlot > 1 && this.peers.some((peer: Peer) =>
      peer.ready && peer.role === 'compute' && peer.computeSlot === 1)) {
      this.hubLostAt = 0;
      this.hubMissingScans = 0;
    }
    if (IS_SERVER && previous !== this.selfComputeSlot) {
      hilog.info(0, 'NearbyChat', 'le-slot self=%{public}d hub=%{public}s',
        this.selfComputeSlot, String(this.selfComputeSlot === 1));
      this.refreshAdvertisedSlot();
      this.dropNonHubChats();
    }
  }

  private refreshAdvertisedSlot(): void {
    if (!IS_SERVER || this.server === null || (this.activeJobs > 0 && this.peers.length > 0)) return;
    this.advertise();
  }

  private dropNonHubChats(): void {
    if (this.selfComputeSlot < 1 || this.activeJobs > 0 || this.selfComputeSlot === 1) return;
    for (const peer of this.peers.slice()) {
      if (peer.role === 'chat') this.drop(peer, '请连接算力设备1。');
    }
  }

  private pruneWorkerLinks(): void {
    if (this.selfComputeSlot < 2 || this.activeJobs > 0) return;
    for (const peer of this.peers.slice()) {
      if (peer.role === 'compute' && peer.computeSlot > 1) {
        this.drop(peer, '算力节点只与算力设备1保持组网。');
      }
    }
  }

  private scheduleAdvertise(): void {
    this.refreshAdvertisedSlot();
  }

  private refreshComputeSlots(): void {
    if (this.rankingSlots) return;
    this.rankingSlots = true;
    try {
      const selfKey = this.computeKey(this.localUid(), this.localName());
      const establishedHub = this.selfComputeSlot === 1 && this.frozenComputeKeys[0] === selfKey;
      // A star worker only sees the hub, not all members. It must never derive
      // global numbering from that partial view or provisionally claim slot 2.
      if (!establishedHub && (this.frozenComputeKeys.length > 0 ||
        this.peers.some((peer: Peer) => peer.role === 'compute' && peer.computeSlot === 1))) {
        this.applyComputeSlots();
        this.pruneWorkerLinks();
        return;
      }
      // Once elected, the hub allocates membership even when discovery is
      // suspended for chat/inference or meshSettled was cleared by a peer drop.
      if (!establishedHub && (!this.meshSettled || !this.electionReady)) return;
      const members: RankMember[] = [];
      const self = new RankMember();
      self.key = this.computeKey(this.localUid(), this.localName());
      self.memAvail = this.selfMem;
      members.push(self);
      for (const peer of this.peers) {
        if (peer.role !== 'compute') continue;
        const item = new RankMember();
        item.key = this.computeKey(peer.deviceUid || peer.peerId, peer.helloName || this.peerName(peer.peerId));
        item.memAvail = peer.memAvail;
        members.push(item);
      }
      if (this.frozenComputeKeys.length === 0) {
        // Do not publish a provisional hub while another trusted compute is
        // visible but its link or memory report has not arrived yet.
        for (const mac of this.trustedAdvertiserMacs()) {
          const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
          if (hit !== undefined && hit.key !== advKeyOf(this.localUid()) && !this.hasHitPeer(hit)) return;
        }
        if (members.some((item: RankMember) => item.memAvail < 0)) return;
      }
      // A transient radio drop must not make a worker advertise itself as a
      // second "算力设备1" while the original hub is still running. Explicit
      // stop/start clears frozenComputeKeys and permits a fresh election.
      if (establishedHub) {
        this.frozenComputeKeys = freezeNameRank(this.frozenComputeKeys,
          members.map((item: RankMember) => item.key));
      } else {
        this.frozenComputeKeys = freezeComputeRank(this.frozenComputeKeys, members);
      }
      this.applyComputeSlots();
      this.pruneWorkerLinks();
    } finally {
      this.rankingSlots = false;
    }
  }

  private computeKey(peerId: string, name: string): string {
    // Display names are neither unique nor stable. All hello/roster paths must
    // use exactly the same per-install identity key.
    if (peerId.length > 0) return 'uid:' + peerId.trim().toLowerCase();
    const trimmed = name.trim();
    if (trimmed.length > 0 && trimmed !== '算力设备' && trimmed !== '聊天设备' &&
      trimmed.indexOf('算力设备') !== 0 && trimmed.indexOf('聊天设备') !== 0) {
      return 'name:' + trimmed;
    }
    const id = this.compactId(peerId);
    return id.length > 0 ? id : '';
  }

  private chatKey(peer: Peer): string {
    return peer.deviceUid.length > 0 ? 'uid:' + peer.deviceUid : 'link:' + peer.peerId;
  }

  private refreshChatSlots(): void {
    const names: string[] = [];
    for (const peer of this.peers) {
      if (peer.role !== 'chat') continue;
      names.push(this.chatKey(peer));
    }
    // The hub alone allocates chat numbers. Reserve slots until this service
    // session ends so a reconnect cannot steal another phone's visible number.
    const keys = this.frozenChatKeys.slice();
    for (const key of rankNames(names)) {
      if (keys.indexOf(key) < 0) keys.push(key);
    }
    this.frozenChatKeys = keys;
    for (const peer of this.peers) {
      if (peer.role !== 'chat') continue;
      const next = slotOf(keys, this.chatKey(peer));
      if (next <= 0) continue;
      if (peer.slot !== next) {
        peer.slot = next;
        if (peer.ready) this.pushChatSlot(peer);
      }
    }
  }

  private pushChatSlot(peer: Peer): void {
    if (!this.holds(peer) || peer.role !== 'chat' || peer.slot < 1) return;
    this.write(peer, {
      type: 'hello_ack', peerRole: 'compute', name: this.localName(), slot: peer.slot, deviceUid: this.localUid()
    });
  }

  private attach(incoming: linkEnhance.Connection, peerId: string, fromServer: boolean): Peer {
    const peer = new Peer(++this.epoch, peerId, incoming, fromServer);
    this.peers.push(peer);
    incoming.on('disconnected', (reason: number) => {
      hilog.info(0, 'NearbyChat',
        'le-disconnect epoch=%{public}d role=%{public}s activeJobs=%{public}d peer=%{public}s reason=%{public}d',
        peer.epoch, peer.role, this.activeJobs, peer.peerId, reason);
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
    this.opened(peer, fromServer);
    return peer;
  }

  private holds(peer: Peer): boolean {
    return this.peers.indexOf(peer) >= 0;
  }

  /**
   * A rotating BLE address must not create a second logical device. Compute peers
   * keep the direction selected by the advertised stable identity; chat clients
   * keep the newest connection so a genuine reconnect can replace its stale link.
   */
  private claimIdentity(peer: Peer, deviceUid: string, role: string): boolean {
    if (deviceUid.length === 0) return true;
    peer.deviceUid = deviceUid;
    const existing = this.peers.find((item: Peer) => item !== peer && item.deviceUid === deviceUid);
    if (existing === undefined) return true;
    if (role !== 'compute') {
      this.drop(existing, '同一聊天设备已重新连接。');
      return this.holds(peer);
    }
    // connectOtherComputes lets the larger identity dial. Both endpoints therefore
    // agree that this is the one physical session to retain if two handshakes race.
    const preferInbound = this.localUid() < deviceUid;
    if (peer.fromServer === preferInbound && existing.fromServer !== preferInbound) {
      this.drop(existing, '同一算力设备已建立规范连接。');
      return this.holds(peer);
    }
    this.drop(peer, '已保留同一算力设备的现有连接。');
    return false;
  }

  private opened(peer: Peer, fromServer: boolean): void {
    if (!this.holds(peer) || peer.opened) return;
    peer.opened = true;
    if (!fromServer) {
      this.write(peer, {
        type: 'hello', peerRole: IS_SERVER ? 'compute' : 'chat', name: this.localName(), deviceUid: this.localUid(),
        slot: this.selfComputeSlot > 0 ? this.selfComputeSlot : undefined
      });
    }
  }

  private receive(peer: Peer, message: WireMessage): void {
    if (!this.holds(peer)) return;
    hilog.info(0, 'NearbyChat', 'le-recv type=%{public}s epoch=%{public}d peer=%{public}s ready=%{public}s',
      message.type, peer.epoch, peer.peerId, String(peer.ready));
    if (!peer.ready) {
      if (message.type === 'hello' && !peer.hello) {
        const name = (typeof message.name === 'string' ? message.name : '') || this.peerName(peer.peerId);
        if (typeof message.name === 'string') peer.helloName = message.name;
        if (!this.isTrustedPeer(peer.peerId, name)) {
          hilog.warn(0, 'NearbyChat', 'le-hello untrusted peer=%{public}s name=%{public}s', peer.peerId, name);
          this.drop(peer, '不是同账号或可信设备，请先在超级终端中连接。');
          return;
        }
        const role = message.peerRole === 'compute' ? 'compute' : 'chat';
        if (IS_SERVER && role === 'chat' && this.selfComputeSlot !== 1) {
          this.drop(peer, '请连接算力设备1。');
          return;
        }
        if (!this.claimIdentity(peer, message.deviceUid || '', role)) return;
        peer.hello = true;
        peer.role = role;
        if (peer.role === 'compute') {
          if (message.slot !== undefined) peer.computeSlot = message.slot;
          this.refreshComputeSlots();
        } else {
          this.refreshChatSlots();
        }
        if (this.onMessage !== null) this.acknowledge(peer);
      } else if (message.type === 'hello_ack' && peer.opened) {
        if (!this.claimIdentity(peer, message.deviceUid || '', 'compute')) return;
        peer.role = 'compute';
        if (IS_SERVER && message.slot !== undefined) peer.computeSlot = message.slot;
        if (typeof message.name === 'string') peer.helloName = message.name;
        if (!IS_SERVER && typeof message.slot === 'number' && message.slot >= 1) this.selfSlot = Math.floor(message.slot);
        this.refreshComputeSlots();
        this.ready(peer);
      } else { this.drop(peer, '对端不是兼容的聊天应用。'); }
      return;
    }
    if (!IS_SERVER && message.type === 'prepared') {
      if (message.requestId === peer.serviceId) this.completeServiceCheck(peer, message.error || '');
      return;
    }
    const allowed = IS_SERVER ?
      ['prepare', 'request', 'cancel', 'deviceInfo', 'deviceInfoSync', 'delta', 'done', 'error'] :
      ['delta', 'done', 'error', 'deviceInfo', 'deviceInfoSync'];
    if (!allowed.includes(message.type) || this.onMessage === null) {
      hilog.warn(0, 'NearbyChat', 'le-ignore type=%{public}s epoch=%{public}d', message.type, peer.epoch);
      return;
    }
    this.onMessage(message, peer.epoch);
  }

  private acknowledge(peer: Peer): void {
    if (!this.holds(peer) || peer.ready) return;
    if (peer.role === 'chat') this.refreshChatSlots();
    const ack: WireMessage = {
      type: 'hello_ack', peerRole: 'compute', name: this.localName(), deviceUid: this.localUid()
    };
    if (peer.role === 'chat' && peer.slot >= 1) ack.slot = peer.slot;
    if (peer.role === 'compute' && this.selfComputeSlot >= 1) ack.slot = this.selfComputeSlot;
    this.write(peer, ack);
    this.ready(peer);
  }

  private ready(peer: Peer): void {
    peer.ready = true;
    peer.settleConnection(true);
    clearTimeout(peer.timer);
    if (peer.role === 'chat' && this.meshBusy) {
      // A chat may finish its handshake while a mesh scan started earlier is
      // still running. Stop that scan before streaming or service preparation.
      ++this.meshRun;
      this.meshBusy = false;
      this.meshTries = 0;
      this.meshLastScanAt = 0;
      this.cancelScan();
    }
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
      // A local invalid-parameter rejection does not prove that the radio link died.
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
    const wasCompute = peer.role === 'compute';
    const lostHub = wasCompute && this.selfComputeSlot > 1 && (peer.computeSlot === 1 ||
      this.computeKey(peer.deviceUid || peer.peerId, peer.helloName) === this.frozenComputeKeys[0]);
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
    if (wasCompute) {
      if (lostHub) {
        this.hubLostAt = Date.now();
        this.hubMissingScans = 0;
      }
      this.meshTries = 0;
      this.meshLastScanAt = 0;
      this.refreshComputeSlots();
      this.meshSettled = false;
    }
    // Publish only after renumbering survivors; otherwise the immediate snapshot
    // contains gaps and is rejected by every worker.
    this.onConnection?.(this.isConnected(), peer.epoch);
  }

  disconnect(preserveServerIntent: boolean = false): void {
    const recoverServer = preserveServerIntent && IS_SERVER && this.serverWanted;
    const savedRank = recoverServer ? this.frozenComputeKeys.slice() : [];
    const savedLeadership = this.leadershipPinned;
    this.cancelServerRestart();
    this.cancelAdvertiseRetry();
    this.advertiseRetryAttempt = 0;
    if (!recoverServer) this.serverWanted = false;
    ++this.lifecycle;
    ++this.meshRun;
    this.meshBusy = false;
    this.cancelScan();
    this.frozenComputeKeys = [];
    this.hubLostAt = 0;
    this.hubMissingScans = 0;
    this.leadershipPinned = false;
    this.frozenChatKeys = [];
    this.selfComputeSlot = 0;
    this.meshSettled = false;
    this.meshTries = 0;
    this.meshLastScanAt = 0;
    this.electionReady = false;
    if (!recoverServer) this.hubRecoveryUntil = 0;
    if (this.electionTimer !== -1) {
      clearTimeout(this.electionTimer);
      this.electionTimer = -1;
    }
    this.lastAdvertisedSlot = -1;
    this.finishAdvertisingWait(false);
    if (this.advertiseTimer !== -1) {
      clearTimeout(this.advertiseTimer);
      this.advertiseTimer = -1;
    }
    const current = this.peers.slice();
    for (const peer of current) this.drop(peer, '连接已结束，请重新连接。');
    if (this.server !== null) {
      const server = this.server;
      this.server = null;
      // Detach before stop: its delayed callback must not tear down a new server.
      try { server.stop(); } catch (_) {}
      try { server.close(); } catch (_) {}
      hilog.info(0, 'NearbyChat', 'le-server closed');
    }
    this.advertising = false;
    this.finishAdvertisingWait(false);
    this.advertise();
    if (recoverServer) {
      this.frozenComputeKeys = savedRank;
      this.selfComputeSlot = slotOf(savedRank, this.computeKey(this.localUid(), this.localName()));
      this.leadershipPinned = savedLeadership;
      this.serverWanted = true;
      this.scheduleServerRestart();
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
