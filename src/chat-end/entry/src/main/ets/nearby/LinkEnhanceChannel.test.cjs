// node LinkEnhanceChannel.test.cjs [path/to/typescript/lib/typescript.js]
//
// Covers the chat end of the data plane. The model end has had its own suite for a
// while; this side did not, which is how its scan window drifted away from the
// serialised version the model end keeps. The two scenes that matter here are the
// ones that were wrong: an overlapping scan must not tear down the newer one, and a
// live slot update from the hub must reach the title.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');

let clock = 0;
let clockSeq = 0;
const clockTimers = new Map();

const flush = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

/** Run everything due within `ms` of virtual time, repeatedly, until nothing is left. */
async function advance(ms) {
  const until = clock + ms;
  await flush();
  for (let round = 0; round < 50; round++) {
    const due = Array.from(clockTimers.entries())
      .filter(([, timer]) => timer.at <= until)
      .sort((left, right) => left[1].at - right[1].at);
    if (due.length === 0) break;
    for (const [id, timer] of due) {
      if (clockTimers.delete(id)) {
        clock = timer.at;
        timer.fn();
      }
    }
    await flush();
  }
  clock = until;
}

const prefs = new Map();

function build(tag) {
  const logs = [];
  const bus = new Map();
  const connections = [];
  const scans = { started: 0, stopped: 0 };
  let scanning = false;
  const behavior = {
    permission: 0,
    localName: '聊天机',
    devices: [],
    scanData: [],
    names: {},
    connectResult: { success: true, reason: 0 }
  };
  const manager = { getAvailableDeviceListSync: () => behavior.devices };
  const linkEnhance = {
    createConnection: (deviceId) => {
      const listeners = new Map();
      const handle = {
        deviceId, listeners, sent: [], connected: false,
        on: (name, fn) => listeners.set(name, fn),
        connect: () => {
          handle.connected = true;
          listeners.get('connectResult')?.({
            deviceId: handle.reportId === undefined ? deviceId : handle.reportId,
            success: behavior.connectResult.success, reason: behavior.connectResult.reason
          });
        },
        sendData: buffer => handle.sent.push(Buffer.from(buffer).toString('utf8')),
        getPeerDeviceId: () => handle.reportId || deviceId,
        disconnect: () => {}, close: () => {},
        deliver: text => listeners.get('dataReceived')?.(new Uint8Array(Buffer.from(text, 'utf8')).buffer),
        drop: reason => listeners.get('disconnected')?.(reason)
      };
      connections.push(handle);
      return handle;
    },
    createServer: () => {
      const listeners = new Map();
      const handle = { listeners, started: false, on: (e, f) => listeners.set(e, f), start: () => { handle.started = true; }, stop() {}, close() {} };
      behavior.server = handle;
      return handle;
    }
  };
  const btConnection = { getLocalName: () => behavior.localName,
    getRemoteDeviceName: id => behavior.names[id] || '' };
  const ble = {
    ScanDuty: { SCAN_MODE_LOW_LATENCY: 2 },
    MatchMode: { MATCH_MODE_AGGRESSIVE: 1 },
    on: (event, fn) => bus.set(event, fn),
    off: event => bus.delete(event),
    startBLEScan: () => {
      // The radio accepts one discovery at a time, exactly as ble.startBLEScan does.
      // A second start while one is running is refused, so a scan that never
      // cancelled its predecessor is left with no results at all.
      if (scanning) throw new Error('scan already running');
      scanning = true;
      scans.started++;
      const listener = bus.get('BLEDeviceFind');
      if (listener !== undefined) listener(behavior.scanData);
    },
    stopBLEScan: () => { scanning = false; scans.stopped++; },
    startAdvertising: () => {},
    stopAdvertising: () => {}
  };
  const storeFor = context => {
    const key = context.tag;
    if (!prefs.has(key)) prefs.set(key, new Map());
    const map = prefs.get(key);
    return {
      getSync: (name, fallback) => (map.has(name) ? map.get(name) : fallback),
      putSync: (name, value) => { map.set(name, value); },
      flush: () => {}
    };
  };
  const modules = {};
  const load = (file, fromDir) => {
    const context = {
      exports: {}, Uint8Array, ArrayBuffer, Date, JSON, Math, Promise, Map, Set, Error, Object, Array,
      Number, String, Boolean, console,
      setTimeout: (fn, delay) => {
        const id = ++clockSeq;
        clockTimers.set(id, { at: clock + (delay || 0), fn });
        return id;
      },
      clearTimeout: id => clockTimers.delete(id),
      setInterval: (fn, delay) => {
        const id = ++clockSeq;
        clockTimers.set(id, { at: clock + (delay || 0), fn });
        return id;
      },
      clearInterval: id => clockTimers.delete(id),
      require: name => {
        if (name === '@kit.ArkTS') return { util: modules.util };
        if (name === '@kit.DistributedServiceKit') return {
          distributedDeviceManager: { createDeviceManager: () => manager, releaseDeviceManager: () => {} },
          linkEnhance
        };
        if (name === '@kit.AbilityKit') return { abilityAccessCtrl: {
          GrantStatus: { PERMISSION_GRANTED: 0 },
          createAtManager: () => ({
            verifyAccessTokenSync: () => behavior.permission,
            requestPermissionsFromUser: () => Promise.resolve({ authResults: [behavior.permission] })
          })
        } };
        if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: (store) => storeFor(store) } };
        if (name === '@kit.PerformanceAnalysisKit') return { hilog: Object.fromEntries(
          ['info', 'warn', 'error'].map(level => [level, (...args) => logs.push({ level, args })])) };
        if (name === '@kit.ConnectivityKit') return { connection: btConnection, ble };
        if (name === '@kit.BasicServicesKit') return { BusinessError: class BusinessError extends Error {} };
        if (name === './NearbyConfig') return modules.config;
        if (name === './ChatProtocol' || name === '../protocol/ChatProtocol') return modules.protocol;
        throw Error(name);
      }
    };
    vm.runInNewContext(transpile((fromDir || __dirname) + '/' + file + '.ets'), context);
    return context.exports;
  };
  modules.util = {
    TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } },
    TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString('utf8') }) },
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
    }
  };
  modules.config = { IS_SERVER: false, USE_LINK_ENHANCE: true, COMPUTE_MANUFACTURE_ID: 0x6E77,
    COMPUTE_ADV_TYPE: 1, COMPUTE_ADV_KEY_BYTES: 4 };
  modules.protocol = load('ChatProtocol', __dirname + '/../protocol');
  const channel = new (load('LinkEnhanceChannel').LinkEnhanceChannel)();
  channel.initialize({ tag: tag || 'chat', applicationInfo: { accessTokenId: 1 } });
  const decode = text => new modules.protocol.MessageAssembler().receive(text);
  return { channel, behavior, logs, connections, scans, modules, decode };
}

const SCAN_WINDOW = 4500;

(async () => {
  // --- 1. Overlapping scans must not cancel each other --------------------------
  {
    // The connect path retries computeDevices() up to three times. Without the
    // shared cancelScan()/settled pair from the model end, the older window's timeout
    // stops the radio and removes the listener under the newer scan, and the newer
    // one then resolves empty even though the advertiser is still there.
    const t = build('chat-scan-serial');
    await t.channel.prepare();
    t.behavior.devices = [{ deviceId: 'listed', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:01': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:01', deviceName: '', rssi: -50,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];

    const first = t.channel.computeDevices();
    await advance(1000);
    const second = t.channel.computeDevices();   // starts while the first is still open
    await advance(SCAN_WINDOW);
    const firstDevices = await first;
    const secondDevices = await second;

    // Each call must be able to see the advertiser. Without the shared cancelScan()
    // the radio refuses the second start outright, and that retry round comes back
    // with nothing even though the hub is still advertising.
    assert.equal(firstDevices.length, 1, 'the first round found the hub');
    assert.equal(secondDevices.length, 1, 'the retry round found it too');
    assert.equal(t.scans.started >= 2, true, 'both rounds really reached the radio');

    assert.equal(t.channel.lastHits.length, 1, 'the newer scan still saw the advertiser');
    assert.equal(t.channel.lastHits[0].slot, 1, 'and read its advertised slot');
    assert.equal(t.scans.stopped >= 1, true, 'the radio was stopped, not left running');
    assert.equal(t.channel.advertisedComputes().length, 1, 'the candidate list is intact');
  }

  // --- 2. A live slot update from the hub reaches the label ---------------------
  {
    // The hub re-sends hello_ack when chat numbering changes. It arrives on a link
    // that is already ready, so it must be accepted there rather than treated as a
    // stray frame the allow-list drops.
    const t = build('chat-slot-update');
    await t.channel.prepare();
    t.behavior.devices = [{ deviceId: 'listed', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:11': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:11', deviceName: '', rssi: -50,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];

    const scanning = t.channel.computeDevices();
    await advance(SCAN_WINDOW);
    await scanning;
    const ads = t.channel.connectComputes();
    assert.equal(ads.length, 1, 'the hub is a dial candidate');
    await t.channel.connectAdvertiser(ads[0].mac);
    const link = t.connections[ads.length - 1];
    assert(link !== undefined, 'a link was opened');

    // Handshake: the hub accepts the hello and answers with the first number.
    link.deliver(t.modules.protocol.encodeMessage(
      { type: 'hello_ack', peerRole: 'compute', slot: 1 }, 'ack-1')[0]);
    await flush();
    assert(t.channel.isConnected(), 'the handshake completes');
    assert.equal(t.channel.selfLabel(), '聊天设备1');

    // Numbering changes while the link stays up.
    link.deliver(t.modules.protocol.encodeMessage(
      { type: 'hello_ack', peerRole: 'compute', slot: 3 }, 'ack-2')[0]);
    await flush();
    assert.equal(t.channel.selfLabel(), '聊天设备3', 'a live renumber reaches the label');
  }

  console.log('PASS: chat-end scan serialisation and live chat-slot updates');
})().catch(error => {
  console.error('SUITE FAILED:', error && error.message);
  console.error(error && error.stack);
  process.exitCode = 1;
});
