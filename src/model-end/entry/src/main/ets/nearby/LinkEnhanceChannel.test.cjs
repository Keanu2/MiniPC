// node LinkEnhanceChannel.test.cjs [path/to/typescript/lib/typescript.js]
//
// Covers the shipped data plane (linkEnhance + BLE advertisement), not the retired
// acm/softbus channel that NearbyChannel.ets still contains. The identity assertions
// are the ones that matter: every compute box advertises the same display name and a
// BLE address that rotates, so "two boxes look like one" is exactly the bug users
// report as 「算力设备1 上看不到 2」and 「连上 1 又去连 2」.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');

// A virtual clock. The module arms timers from three different places — the scan
// window, the connect attempt and the 20 s no-hello timeout — and draining them in
// one pass would tear down the very links the scene is about, so each timer keeps
// the time it is due and the test decides how far to run.
let clock = Date.now();
let clockSeq = 0;
const clockTimers = new Map();

const flush = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

/** Run everything due within `ms` of virtual time, repeatedly, until nothing is left. */
async function advance(ms) {
  const until = clock + ms;
  // The module arms its first timer only after the awaits it was parked on resume.
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

/**
 * The on-disk preferences store, keyed by install tag and shared across builds: a
 * second build() with the same tag is a restart of the same install, which is the
 * only way the persisted install id can be observed surviving anything.
 */
const prefs = new Map();

function build(server, tag) {
  const logs = [];
  const bus = new Map();
  const connections = [];
  let lastAdvertise = null;
  let advertiseCalls = 0;
  const behavior = {
    permission: 0,
    // Legacy beacons without an identity fingerprint use display-name dial
    // ordering. This fixture sorts above those candidates so it initiates.
    localName: '算力设备9',
    // Two boxes the device manager lists and the mesh is allowed to dial. They are
    // link-scoped tokens, not BLE addresses: an address rotates on every reconnect,
    // so nothing here keys a peer on one.
    devices: [
      { deviceId: 'link-1', deviceName: '算力设备2', deviceType: 'phone', networkId: 'net-1' },
      { deviceId: 'link-2', deviceName: '算力设备3', deviceType: 'phone', networkId: 'net-2' }
    ],
    scanData: [],
    names: {},
    connectResult: { success: true, reason: 0 },
    /** When set, every startAdvertising call throws until the test clears it. */
    advertiseRefused: false
  };
  const manager = { getAvailableDeviceListSync: () => behavior.devices };
  const linkEnhance = {
    createConnection: (deviceId) => {
      const listeners = new Map();
      const handle = {
        deviceId, listeners, sent: [], closed: false, connected: false,
        on: (name, fn) => listeners.set(name, fn),
        connect: () => {
          handle.connected = true;
          if (behavior.deferConnect) return;
          // The platform reports the outcome on the same connection.
          listeners.get('connectResult')?.({
            deviceId: handle.reportId === undefined ? deviceId : handle.reportId,
            success: behavior.connectResult.success, reason: behavior.connectResult.reason
          });
        },
        sendData: buffer => handle.sent.push(Buffer.from(buffer).toString('utf8')),
        getPeerDeviceId: () => handle.reportId || deviceId,
        disconnect: () => { handle.closed = true; },
        close: () => { handle.closed = true; },
        /** Push a frame in as if the peer sent it. */
        deliver: text => listeners.get('dataReceived')?.(new Uint8Array(Buffer.from(text, 'utf8')).buffer),
        drop: reason => listeners.get('disconnected')?.(reason)
      };
      connections.push(handle);
      return handle;
    },
    createServer: (name) => {
      const listeners = new Map();
      const handle = {
        name, listeners, started: false,
        on: (event, fn) => listeners.set(event, fn),
        start: () => { handle.started = true; },
        stop: () => {}, close: () => {}
      };
      behavior.server = handle;
      return handle;
    }
  };
  // Resolution is per address, which is how the platform reports it: two boxes
  // advertising the same display name still resolve to two different names here.
  // An address the cache cannot resolve comes back empty, so the caller falls back.
  const btConnection = { getLocalName: () => behavior.localName,
    getRemoteDeviceName: id => {
      if (process.env.MINIPC_DEBUG) console.log('resolve', JSON.stringify(id), '->', JSON.stringify(behavior.names[id]));
      return behavior.names[id] || '';
    } };
  const ble = {
    AdvertisingState: { STARTED: 1, ENABLED: 2, DISABLED: 3, STOPPED: 4 },
    ScanDuty: { SCAN_MODE_LOW_LATENCY: 2 },
    MatchMode: { MATCH_MODE_AGGRESSIVE: 1 },
    on: (event, fn) => bus.set(event, fn),
    off: (event) => bus.delete(event),
    startBLEScan: () => {
      if (behavior.scanRefused) throw new Error('scanner unavailable');
      const listener = bus.get('BLEDeviceFind');
      if (listener !== undefined) listener(behavior.scanData);
    },
    stopBLEScan: () => {},
    startAdvertising: async params => {
      assert(params.advertisingData, 'use the ID-returning asynchronous API');
      if (behavior.advertiseRefused) throw new Error('adapter not ready');
      advertiseCalls++;
      lastAdvertise = params.advertisingData;
      const id = advertiseCalls;
      behavior.advertisingStarts = (behavior.advertisingStarts || []).concat(id);
      if (behavior.startGate) await behavior.startGate;
      if (behavior.earlyStopped) bus.get('advertisingStateChange')?.({ advertisingId: id, state: 4 });
      else if (!behavior.silentStart) bus.get('advertisingStateChange')?.({ advertisingId: id, state: 1 });
      return id;
    },
    stopAdvertising: async id => {
      assert.equal(typeof id, 'number', 'stop exactly the owned advertising ID, never the global advertiser');
      behavior.advertisingStops = (behavior.advertisingStops || []).concat(id);
      if (behavior.stopGate) await behavior.stopGate;
      bus.get('advertisingStateChange')?.({ advertisingId: id, state: 4 });
    }
  };
  const storeFor = (context) => {
    const tag = context.tag;
    if (process.env.MINIPC_DEBUG) console.log('storeFor tag=', tag);
    if (!prefs.has(tag)) prefs.set(tag, new Map());
    const map = prefs.get(tag);
    return {
      getSync: (name, fallback) => {
        if (process.env.MINIPC_DEBUG) console.log('getSync', name, map.get(name));
        return map.has(name) ? map.get(name) : fallback;
      },
      putSync: (name, value) => {
        if (process.env.MINIPC_DEBUG) console.log('putSync', name, value);
        map.set(name, value);
      },
      flush: () => {}
    };
  };
  const modules = {};
  const load = (file, fromDir) => {
    const context = {
      exports: {}, Uint8Array, ArrayBuffer, Date: class extends Date { static now() { return clock; } }, JSON, Math, Promise, Map, Set, Error, Object, Array,
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
        if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: (store, options) => storeFor(store) } };
        if (name === '@kit.PerformanceAnalysisKit') return { hilog: Object.fromEntries(
          ['info', 'warn', 'error'].map(level => [level, (...args) => logs.push({ level, args })])) };
        if (name === '@kit.ConnectivityKit') return { connection: btConnection, ble };
        if (name === '@kit.BasicServicesKit') return { BusinessError: class BusinessError extends Error {} };
        if (name === './NearbyConfig') return modules.config;
        if (name === './ClusterRoster' || name === '../cluster/ClusterRoster') return modules.roster;
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
  modules.config = { IS_SERVER: server, USE_LINK_ENHANCE: true, COMPUTE_MANUFACTURE_ID: 0x6E77,
    COMPUTE_ADV_TYPE: 1, COMPUTE_ADV_KEY_BYTES: 4 };
  modules.roster = load('ClusterRoster', __dirname + '/../cluster');
  modules.protocol = load('ChatProtocol', __dirname + '/../protocol');
  const channel = new (load('LinkEnhanceChannel').LinkEnhanceChannel)();
  channel.initialize({ tag: tag || (server ? 'server' : 'client'), applicationInfo: { accessTokenId: 1 } });
  const decode = text => {
    const assembler = new modules.protocol.MessageAssembler();
    return assembler.receive(text);
  };
  /** Frames the module has pushed out on an outgoing connection. */
  const sent = handle => handle.sent.map(decode).filter(Boolean);
  return { channel, behavior, logs, connections, modules, decode, sent,
    advState(id, state) { bus.get('advertisingStateChange')?.({ advertisingId: id, state }); },
    accept(deviceId) {
      const link = linkEnhance.createConnection(deviceId);
      behavior.server.listeners.get('connectionAccepted')(link);
      return link;
    },
    get advertise() { return lastAdvertise; },
    get advertiseCalls() { return advertiseCalls; } };
}

/** The last link the module opened itself. */
const outgoing = t => t.connections[t.connections.length - 1];

/** One scan window, the unit of virtual time every discovery scene turns on. */
const SCAN_WINDOW = 4500;

/** Turn the scan on and let the window expire. */
function scan(t) {
  const connecting = t.channel.connectOtherComputes();
  return advance(SCAN_WINDOW).then(() => connecting);
}

(async () => {
  {
    const t = build(true, 'withdraw-stale-hub');
    await t.channel.prepare();
    t.behavior.devices = [{ deviceId: 'old-hub', deviceName: 'Hub', networkId: 'hub-net' }];
    t.behavior.names = { 'hub-mac': 'Hub' };
    const ad = slot => ({ deviceId: 'hub-mac', deviceName: 'Hub', rssi: -40,
      data: new Uint8Array([9, 0xFF, 0x77, 0x6E, 1, slot, 1, 2, 3, 4]).buffer });
    t.behavior.scanData = [ad(1), ad(0),
      { deviceId: 'hub-mac', deviceName: 'Hub', rssi: -40, data: new Uint8Array([0]).buffer }];
    const scanning = t.channel.computeDevices();
    await advance(SCAN_WINDOW); await scanning;
    assert.equal(t.channel.lastHits[0].slot, 0, 'valid unnumbered beacon withdraws the former hub claim');
    assert.equal(t.channel.connectComputes().length, 0, 'a restarted but unelected device is not a chat dial target');
    t.channel.disconnect();
  }
  // An established star hub assigns 2/3/4 even while scanning is suspended.
  {
    const hub = build(true, 'multi-hub');
    hub.behavior.localName = 'SameCompute';
    hub.behavior.devices = [1, 2, 3, 4].map(n => ({ deviceId: 'worker-' + n, deviceName: 'SameCompute', networkId: 'net-' + n }));
    await hub.channel.prepare();
    hub.channel.subscribe(() => {}, () => {});
    hub.channel.frozenComputeKeys = [hub.channel.computeKey(hub.channel.localUid(), 'SameCompute')];
    hub.channel.applyComputeSlots();
    hub.channel.meshSettled = false;
    hub.channel.electionReady = false;
    hub.channel.setActiveJobs(1);
    const links = [];
    const join = async n => {
      const link = hub.accept('worker-' + n);
      for (const frame of hub.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute',
        name: 'SameCompute', deviceUid: 'worker-uid-' + n }, 'multi-hello-' + n)) link.deliver(frame);
      await flush();
      return link;
    };
    for (let n = 1; n <= 3; n++) links.push(await join(n));
    assert.equal(hub.channel.peerInfos().map(p => p.slot).join(','), '2,3,4', JSON.stringify(hub.logs));
    assert.equal(hub.channel.peerInfos().map(p => p.name).join(','), '算力设备2,算力设备3,算力设备4');
    const worker = build(true, 'multi-follower');
    worker.behavior.localName = 'SameCompute';
    worker.behavior.devices = [{ deviceId: 'hub-link', deviceName: 'SameCompute', networkId: 'hub-net' }];
    await worker.channel.prepare();
    worker.channel.subscribe(() => {}, () => {});
    const upstream = worker.accept('hub-link');
    for (const frame of worker.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute',
      name: 'SameCompute', deviceUid: hub.channel.localUid(), slot: 1 }, 'multi-upstream')) upstream.deliver(frame);
    await flush();
    assert.equal(worker.channel.selfComputeNumber(), 0, 'joining nodes never invent slot 2');
    const reporter = worker.channel.peerInfos()[0].epoch;
    const roster = [
      { id: hub.channel.localUid(), role: 'self', slot: 1 },
      { id: 'other-worker', role: 'compute', slot: 2 },
      { id: worker.channel.localUid(), role: 'compute', slot: 3 }
    ];
    assert.equal(worker.channel.applyRemoteRoster(reporter, roster), true);
    worker.channel.meshSettled = true;
    worker.channel.electionReady = true;
    worker.channel.setSelfMem(999999);
    assert.equal(worker.channel.selfComputeNumber(), 3, 'a partial direct view cannot shrink the global roster');
    for (const invalid of [
      [roster[0], { ...roster[2], slot: 2.5 }],
      [roster[0], roster[2]],
      [roster[0], { ...roster[1], slot: 1 }, roster[2]],
      [roster[0], { ...roster[1], id: roster[0].id }, roster[2]],
      [{ ...roster[0], id: 'not-the-reporter' }, roster[1], roster[2]]
    ]) assert.equal(worker.channel.applyRemoteRoster(reporter, invalid), false);
    assert.equal(worker.channel.selfComputeNumber(), 3, 'rejected rosters do not change labels');
    const observed = [];
    hub.channel.subscribe(() => {}, () => observed.push(hub.channel.peerInfos().map(p => p.slot).join(',')));
    links[0].drop(-1);
    assert.equal(observed.at(-1), '2,3', 'disconnect publishes only after survivor renumbering');
    await join(4);
    assert.equal(hub.channel.peerInfos().map(p => p.slot).join(','), '2,3,4', 'join after drop cannot wait for a scan');
    hub.channel.disconnect(); worker.channel.disconnect();
  }
  for (const stopped of [true, false]) {
    const t = build(true, 'late-connect-' + stopped);
    await t.channel.prepare();
    t.behavior.deferConnect = true;
    const attempt = t.channel.tryConnect('compute', 'late-peer');
    const link = outgoing(t);
    if (stopped) t.channel.disconnect();
    else await advance(9000);
    link.listeners.get('connectResult')({ deviceId: 'late-peer', success: true, reason: 0 });
    assert.equal(await attempt, false);
    assert.equal(t.channel.peers.length, 0, 'late completion cannot resurrect a timed-out/stopped connection');
    assert.equal(link.closed, true);
    t.channel.disconnect();
  }
  // --- 1. The advertisement carries a per-install key, not the shared name --------
  {
    const keyOf = t => {
      const value = t.advertise.manufactureData[0].manufactureValue;
      return Array.from(new Uint8Array(value).slice(2, 6)).join(',');
    };
    const t = build(true, 'install-1');
    await t.channel.prepare();
    const first = keyOf(t);
    assert.equal(t.advertise.manufactureData[0].manufactureId, 0x6E77, 'the advertisement must be identified');
    // A second install draws its own id rather than hashing the shared display name.
    const other = build(true, 'install-2');
    await other.channel.prepare();
    assert.notEqual(first, keyOf(other), 'two installs must not advertise the same fingerprint');
    // A restart of the same install keeps the stored id.
    const restarted = build(true, 'install-1');
    await restarted.channel.prepare();
    assert.equal(keyOf(restarted), first, 'the fingerprint must survive a restart of the same install');
  }

  // --- 2. Two compute boxes that share a name are still two peers -----------------
  {
    const t = build(true);
    await t.channel.prepare();
    assert(t.behavior.server.started, 'the server end must listen for accepted links');
    // Bring in the two computes the way connectOtherComputes does. Both advertise
    // the same display name — the case that used to collapse into one peer — so only
    // the per-address resolution tells them apart.
    const macs = ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02'];
    t.behavior.names = { [macs[0]]: '算力设备2', [macs[1]]: '算力设备3' };
    // AD structures as the platform hands them over: [length][type 0xFF][id lo][id hi][payload...].
    // A pure advertisement carries no name, so each address resolves separately.
    t.behavior.scanData = macs.map(mac => ({ deviceId: mac, deviceName: '', rssi: -50,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }));
    await scan(t);
    assert.equal(t.connections.length, 2, 'both advertised boxes must be dialled, not just the strongest');
    assert(t.connections.every(handle => handle.connected), 'each candidate must actually be attempted');
    for (const [at, handle] of t.connections.entries()) {
      handle.deliver(t.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute', name: '算力设备' }, 'h-' + at)[0]);
    }
    await flush();
    const infos = t.channel.peerInfos();
    // Both links are up and both peers call themselves 算力设备; they must not collapse.
    assert.equal(infos.length, 2, 'two compute links must stay two peers');
    assert.notEqual(infos[0].peerId, infos[1].peerId, 'the two peers must be told apart by link id');
  }

  // --- 3. A reconnect from the same link id replaces the old link -----------------
  {
    const t = build(true);
    await t.channel.prepare();
    // One box in range. It is listed by the device manager and resolves to the same
    // name there, which is how a peer earns trust; the name also sorts below the
    // local one, so the mesh dials it rather than deferring to the tie-break.
    t.behavior.devices = [{ deviceId: 'link-1', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:01': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:01', deviceName: '', rssi: -50,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    const link = outgoing(t);
    // The box answers the hello, which is what gives it a role and a slot.
    link.deliver(t.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute', name: '算力设备1' }, 'r-0')[0]);
    await flush();
    const before = t.channel.peerInfos();
    assert.equal(before.length, 1);
    // The same box comes back on a new link reporting the same id; the old link must
    // go, or the box is listed twice and the roster ranks a ghost.
    link.reportId = link.deviceId;
    link.connect();
    await flush();
    const after = t.channel.peerInfos();
    assert.equal(after.length, 1, 'a reconnecting peer must not appear twice');
    assert.deepEqual(after.map(info => info.peerId), before.map(info => info.peerId));
  }

  // --- 3b. A rotating BLE address cannot duplicate one stable device -------------
  {
    const t = build(true, 'stable-dedupe-host');
    await t.channel.prepare();
    t.behavior.devices = [{ deviceId: 'trusted', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:11': '算力设备1', 'aa:bb:cc:dd:ee:12': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:11', deviceName: '', rssi: -45,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    outgoing(t).deliver(t.modules.protocol.encodeMessage({
      type: 'hello', peerRole: 'compute', name: '算力设备1', deviceUid: 'physical-compute-1'
    }, 'stable-1')[0]);
    await flush();
    assert.equal(t.channel.peerInfos().length, 1);

    // The exact same installation reappears with a different private address.
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:12', deviceName: '', rssi: -44,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    outgoing(t).deliver(t.modules.protocol.encodeMessage({
      type: 'hello', peerRole: 'compute', name: '算力设备1', deviceUid: 'physical-compute-1'
    }, 'stable-2')[0]);
    await flush();
    assert.equal(t.channel.peerInfos().length, 1,
      'one stable deviceUid must remain one peer even after its BLE address rotates');
    assert.equal(t.channel.peerInfos()[0].deviceUid, 'physical-compute-1');
  }

  // --- 4. A stray frame is ignored, not treated as a dead link --------------------
  {
    // The compute end: it is the one that dials, and the one that accepts a delta. What
    // it must refuse is the chat end's frames — 'prepared' belongs to the compute side
    // and has no meaning here.
    const t = build(true);
    await t.channel.prepare();
    const seen = [];
    t.channel.subscribe(message => seen.push(message), () => {});
    // One trusted box, named and dialled the same way as scene 3: a peer only earns a
    // link once the device manager lists it and its address resolves to that name.
    t.behavior.devices = [{ deviceId: 'link-1', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:01': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:01', deviceName: '', rssi: -50,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    const link = outgoing(t);
    // The hello is what opens the session on the receiving side.
    link.deliver(t.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute', name: '算力设备1' }, 'r-1')[0]);
    await flush();
    assert(t.channel.isConnected(), 'a hello must open the session');
    const before = seen.length;
    // 'prepared' is the compute end's own reply to the chat end. Arriving here it is a
    // stray frame, not a broken link, so the session stays up and it never reaches the
    // subscriber.
    link.deliver(t.modules.protocol.encodeMessage({ type: 'prepared', requestId: 'r2', error: '' }, 'r-2')[0]);
    // The log call is hilog.warn(0, tag, format, ...args), so the erased type sits after
    // the format string — not at a fixed index in the raw argument list.
    const ignored = t.logs.some(log => log.level === 'warn' &&
      log.args[2].startsWith('le-ignore') && log.args.indexOf('prepared') > 2);
    assert(t.channel.isConnected(), 'a stray frame must not take down a healthy session');
    assert.equal(seen.length, before, 'the stray frame must not reach the subscriber');
    assert(ignored, 'the ignored frame must be logged');

    // A local invalid-parameter rejection is not a radio disconnect. The frame can
    // fail, but a healthy session must remain available for later traffic.
    link.sendData = () => {
      const error = new Error('invalid parameter');
      error.code = 32390206;
      throw error;
    };
    const rejected = t.channel.send({ type: 'deviceInfo', requestId: 'send-error' });
    await advance(400);
    assert.equal(await rejected, false);
    assert(t.channel.isConnected(), '32390206 must not tear down a healthy connection');
  }

  // --- 4b. A stopped/re-enabled compute rejoins the mesh --------------------------
  {
    const t = build(true, 'restart-host');
    await t.channel.prepare();
    const firstServer = t.behavior.server;
    const firstAdvertisement = t.advertise;
    t.behavior.devices = [{ deviceId: 'trusted', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:21': '算力设备1', 'aa:bb:cc:dd:ee:22': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:21', deviceName: '', rssi: -40,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    const firstLink = outgoing(t);
    firstLink.deliver(t.modules.protocol.encodeMessage({
      type: 'hello', peerRole: 'compute', name: '算力设备1', deviceUid: 'returning-compute'
    }, 'restart-1')[0]);
    await flush();
    firstLink.drop(-1);
    await flush();

    // A compute disconnect resets the discovery budget, so its new address is
    // considered immediately instead of being ignored after the four startup scans.
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:22', deviceName: '', rssi: -39,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 2, 3, 4]).buffer }];
    await scan(t);
    assert.equal(t.connections.length, 2, 'a returning compute is dialled after its previous link drops');

    t.channel.disconnect();
    await t.channel.prepare();
    assert.notEqual(t.behavior.server, firstServer, 're-enabling near-field creates a fresh server');
    assert(t.behavior.server.started, 'the replacement server is listening');
    assert.notEqual(t.advertise, firstAdvertisement, 'the replacement server advertises again');

    // A platform-side server stop is not a user request to disable near-field.
    // Rebuild both listening and advertising after a short bounded delay.
    const replacementServer = t.behavior.server;
    const replacementAdvertisement = t.advertise;
    replacementServer.listeners.get('serverStopped')?.(-9);
    assert.equal(t.channel.isListening(), false, 'the stopped handle is detached immediately');
    await advance(800);
    assert.notEqual(t.behavior.server, replacementServer, 'an unexpected stop creates another server automatically');
    assert(t.behavior.server.started, 'the recovered server is listening');
    assert.notEqual(t.advertise, replacementAdvertisement, 'automatic recovery publishes a fresh advertisement');

    // Disabling in the middle of a BLE scan must cancel the old listener. Its late
    // completion must not clear or settle the mesh run started after re-enable.
    const interrupted = t.channel.connectOtherComputes().catch(() => {});
    await flush();
    t.channel.disconnect();
    await interrupted;
    await t.channel.prepare();
    const beforeFreshScan = t.connections.length;
    const fresh = t.channel.connectOtherComputes();
    await advance(SCAN_WINDOW);
    await fresh;
    assert(t.connections.length > beforeFreshScan,
      'a fresh mesh scan runs immediately after stop/start instead of waiting for the stale scan');

    const beforeBusy = t.connections.length;
    t.channel.setActiveJobs(1);
    await t.channel.connectOtherComputes();
    assert.equal(t.connections.length, beforeBusy, 'inference suspends mesh discovery');
    t.channel.setActiveJobs(0);

    const overlapping = t.channel.connectOtherComputes().catch(() => {});
    await flush();
    const chat = { role: 'chat', ready: false, epoch: 99, peerId: 'chat-99', timer: 0,
      settleConnection() {} };
    t.channel.peers.push(chat);
    t.channel.ready(chat);
    await overlapping;
    assert.equal(t.channel.meshBusy, false, 'chat handshake cancels an already-running scan');
    const beforeChat = t.channel.meshTries;
    await t.channel.connectOtherComputes();
    assert.equal(t.channel.meshTries, beforeChat, 'a live chat link defers further discovery');
  }

  // --- 4c. Only the elected hub advertises slot 1 -------------------------------
  {
    const t = build(true, 'star-follower');
    await t.channel.prepare();
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 0,
      'startup beacon stays unnumbered during hub election');
    t.channel.meshSettled = true;
    t.channel.setSelfMem(1000);
    t.channel.refreshComputeSlots();
    assert.equal(t.channel.selfComputeNumber(), 0, 'the hub is not announced before election settles');
    await advance(10000);
    assert.equal(t.channel.selfComputeNumber(), 1, 'a lone compute becomes the hub after election');
    const selfKey = t.channel.computeKey(t.channel.localUid(), t.channel.localName());
    t.channel.frozenComputeKeys = ['elected-hub', selfKey];
    t.channel.applyComputeSlots();
    await flush();
    assert.equal(t.channel.selfComputeNumber(), 2);
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 2,
      'a follower must not keep advertising the unnumbered or hub slot');
    t.channel.refreshComputeSlots();
    assert.equal(t.channel.selfComputeNumber(), 2,
      'loss of the hub link must not promote a worker into a duplicate hub');
  }

  // --- 4d. A joining worker dials the hub even when its identity sorts lower ---
  {
    const t = build(true, 'worker-joins-busy-hub');
    t.behavior.localName = '算力设备0';
    t.behavior.devices = [{ deviceId: 'hub', deviceName: '算力设备1', networkId: 'hub-net' }];
    t.behavior.names = { 'aa:bb:cc:dd:ee:55': '算力设备1' };
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:55', deviceName: '', rssi: -40,
      data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1]).buffer }];
    await t.channel.prepare();
    t.channel.selfComputeSlot = 2;
    await scan(t);
    assert.equal(t.connections.length, 1, 'the worker initiates connection to advertised slot 1');
  }

  // --- 4e. A stopped hub is replaced only after repeated absence checks -------
  {
    const t = build(true, 'verified-hub-failover');
    await t.channel.prepare();
    const self = t.channel.computeKey(t.channel.localUid(), t.channel.localName());
    t.channel.frozenComputeKeys = ['former-hub', self];
    t.channel.applyComputeSlots();
    t.channel.hubLostAt = clock - 16000;
    t.channel.lastScanComplete = true;
    t.channel.lastHits = [{ compute: true, slot: 1, key: 'former-key', mac: 'link-1', name: '算力设备2' }];
    for (let i = 0; i < 3; i++) t.channel.considerHubFailover();
    assert.equal(t.channel.selfComputeNumber(), 2, 'a visible old hub blocks promotion');
    t.channel.lastHits = [];
    for (let i = 0; i < 2; i++) t.channel.considerHubFailover();
    assert.equal(t.channel.selfComputeNumber(), 2, 'one or two empty scans do not create a second hub');
    t.channel.considerHubFailover();
    await flush();
    assert.equal(t.channel.selfComputeNumber(), 1, 'third missing-hub scan promotes the next worker');
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 1,
      'the promoted worker publishes slot 1 for chat reconnect');
    t.channel.peers.push({ role: 'compute', ready: true, deviceUid: 'former-hub',
      peerId: 'former-hub', helloName: 'former-hub', memAvail: 999999, computeSlot: 0 });
    t.channel.meshSettled = true;
    t.channel.electionReady = true;
    t.channel.setSelfMem(100);
    assert.equal(t.channel.selfComputeNumber(), 1,
      'a returning former hub cannot displace the promoted center by memory rank');
    t.channel.applyRemoteRoster(-99, [
      { id: 'former-hub', name: 'former-hub', role: 'compute', slot: 1 },
      { id: self, name: t.channel.localName(), role: 'compute', slot: 2 }
    ]);
    assert.equal(t.channel.selfComputeNumber(), 1,
      'a stale roster from the former hub does not undo takeover');
  }
  {
    const t = build(true, 'former-hub-rejoins');
    t.behavior.localName = 'AFormer';
    await t.channel.prepare();
    t.channel.peers.push({ epoch: 8, role: 'compute', deviceUid: 'new-hub', peerId: 'new-hub', helloName: 'ZNewHub' });
    t.channel.applyRemoteRoster(8, [
      { id: 'new-hub', name: 'ZNewHub', role: 'compute', slot: 1 },
      { id: t.channel.localUid(), name: 'AFormer', role: 'compute', slot: 2 }
    ]);
    assert.equal(t.channel.selfComputeNumber(), 2,
      'a restarted former hub adopts the active hub before its own election timer and despite name ordering');
  }

  // Real handshake -> hub loss -> scans -> promotion -> server recovery -> chats.
  {
    const t = build(true, 'third-worker-full-takeover');
    t.behavior.localName = 'Worker';
    t.behavior.devices = [
      { deviceId: 'hub-link', deviceName: 'Hub', networkId: 'hub-net' },
      { deviceId: 'chat-listed', deviceName: 'SamePhone', networkId: 'chat-net' }
    ];
    await t.channel.prepare();
    t.channel.subscribe(() => {}, () => {});
    const hub = t.accept('hub-link');
    for (const frame of t.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'compute',
      deviceUid: 'old-hub', name: 'Hub', slot: 1 }, 'old-hello')) hub.deliver(frame);
    await flush();
    const hubEpoch = t.channel.peerInfos()[0].epoch;
    t.channel.applyRemoteRoster(hubEpoch, [
      { deviceUid: 'old-hub', name: 'Hub', role: 'compute', slot: 1 },
      { deviceUid: 'absent-worker', name: 'Worker', role: 'compute', slot: 2 },
      { deviceUid: t.channel.localUid(), name: 'Worker', role: 'compute', slot: 3 }
    ]);
    assert.equal(t.channel.selfComputeNumber(), 3, 'UID distinguishes same-name compute nodes');
    hub.drop(-1);
    t.behavior.scanRefused = true;
    for (let i = 0; i < 3; i++) await scan(t);
    assert.equal(t.channel.selfComputeNumber(), 3, 'failed radio scans cannot prove the hub absent');
    t.behavior.scanRefused = false;
    for (let i = 0; i < 3; i++) { await scan(t); await advance(2500); }
    assert.equal(t.channel.selfComputeNumber(), 1, 'the highest surviving rank takes over even if original 2 is gone');
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 1);
    t.behavior.server.listeners.get('serverStopped')(-7);
    await advance(800);
    assert(t.behavior.server.started, 'new center recovers its listener');
    assert.equal(t.channel.selfComputeNumber(), 1, 'server recovery retains the elected center');
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 1);
    const joinChat = async (mac, uid, messageId) => {
      const link = t.accept(mac);
      for (const frame of t.modules.protocol.encodeMessage({ type: 'hello', peerRole: 'chat',
        deviceUid: uid, name: 'SamePhone' }, messageId)) link.deliver(frame);
      await flush();
      return link;
    };
    const first = await joinChat('chat-mac-1', 'phone-1', 'chat-a');
    const second = await joinChat('chat-mac-2', 'phone-2', 'chat-b');
    assert.equal(t.sent(first).find(m => m.type === 'hello_ack').slot, 1);
    assert.equal(t.sent(second).find(m => m.type === 'hello_ack').slot, 2,
      'two same-name chat phones receive distinct acknowledgments from the promoted hub');
    first.drop(-1);
    t.channel.setRemoteChats(['SamePhone', 'stale-phone']);
    const rejoined = await joinChat('new-chat-mac', 'phone-1', 'chat-c');
    assert.equal(t.sent(rejoined).find(m => m.type === 'hello_ack').slot, 1);
    assert.equal(t.channel.peerInfos().find(p => p.deviceUid === 'phone-2').slot, 2,
      'reconnection and stale worker rosters never reassign another live phone');
  }

  // --- 5. The retired acm collaborate entry point refuses -------------------------
  {
    const t = build(true);
    await t.channel.prepare();
    assert.equal(t.channel.accept({ PeerInfo: {}, 'ohos.dms.collabToken': 'token' }), false,
      'the retired acm path must not open a session');
    assert.equal(t.channel.isConnected(), false);
  }

  // --- 6. Only the advertised hub is ever a dial candidate -----------------------
  {
    // Two computes advertise, neither matches a DeviceManager row by name, and the
    // follower has the STRONGER signal. A follower answers a chat hello by dropping
    // the link with 「请连接算力设备1。」, so a regression to "strongest first" is an
    // endless connect/drop loop. connectComputes() is the shared gate both ends use.
    const t = build(false, 'hub-candidates');
    t.behavior.devices = [
      { deviceId: 'listed-1', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-hub' },
      { deviceId: 'listed-2', deviceName: '算力设备2', deviceType: 'phone', networkId: 'net-follower' }
    ];
    t.behavior.names = { 'aa:bb:cc:dd:ee:31': '算力设备2', 'aa:bb:cc:dd:ee:32': '算力设备1' };
    t.behavior.scanData = [
      { deviceId: 'aa:bb:cc:dd:ee:31', deviceName: '', rssi: -30,
        data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 2, 3, 4, 5]).buffer },
      { deviceId: 'aa:bb:cc:dd:ee:32', deviceName: '', rssi: -70,
        data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 1, 9, 9, 9]).buffer }
    ];
    await t.channel.prepare();
    // The scan window only elapses on the virtual clock, so drive it explicitly.
    const scanned = t.channel.computeDevices();
    await advance(SCAN_WINDOW);
    await scanned;
    assert.equal(t.channel.lastHits.length, 2, 'both computes are in range');
    assert.equal(t.channel.connectComputes().join(','), 'aa:bb:cc:dd:ee:32',
      'only the advertised slot-1 hub is a dial candidate, even though slot 2 is stronger');
    assert.equal(t.channel.connectComputes().indexOf('aa:bb:cc:dd:ee:31'), -1,
      'a follower must never be a dial candidate');

    // With only a follower advertising there is nothing to dial, and the fallback
    // must say so rather than landing on slot 2.
    const followerOnly = build(false, 'hub-candidates-follower');
    followerOnly.behavior.devices = [
      { deviceId: 'listed-2', deviceName: '算力设备2', deviceType: 'phone', networkId: 'net-follower' }
    ];
    followerOnly.behavior.names = { 'aa:bb:cc:dd:ee:31': '算力设备2' };
    followerOnly.behavior.scanData = [
      { deviceId: 'aa:bb:cc:dd:ee:31', deviceName: '', rssi: -30,
        data: new Uint8Array([5, 0xFF, 0x77, 0x6E, 1, 2, 3, 4, 5]).buffer }
    ];
    await followerOnly.channel.prepare();
    const followerScan = followerOnly.channel.computeDevices();
    await advance(SCAN_WINDOW);
    await followerScan;
    assert.equal(followerOnly.channel.connectComputes().length, 0,
      'a follower alone leaves no dial candidate');
    let refused = '';
    try {
      await followerOnly.channel.connectToAdvertisers();
      refused = '(no refusal)';
    } catch (error) {
      refused = error.message;
    }
    assert(followerOnly.connections.length === 0, 'a follower must not be dialled');
    assert(refused.includes('算力设备1'), 'the refusal names the missing hub: ' + refused);
  }

  // --- 7. A refused advertisement retries instead of going silent ----------------
  {
    const t = build(true, 'advertise-retry');
    t.behavior.advertiseRefused = true;
    await t.channel.prepare();
    assert.equal(t.advertiseCalls, 0, 'no advertisement was accepted');
    assert.equal(t.advertise, null, 'nothing was pushed to the radio');
    // An asynchronous failure must leave a retry armed even without new peers.
    t.channel.refreshAdvertisedSlot();
    await advance(1000);
    assert.equal(t.advertiseCalls, 0, 'still refused');
    t.behavior.advertiseRefused = false;
    await advance(3000);
    assert(t.advertiseCalls > 0, 'the retry timer publishes once the adapter is ready');
    assert(t.advertise.manufactureData[0].manufactureId, 'a real advertisement reached the radio');
  }

  // The platform's advertising operations complete asynchronously, not when the
  // request is submitted. Exercise pending stops, late starts and state events.
  {
    const t = build(true, 'async-advertise-takeover');
    await t.channel.prepare(); await flush();
    t.channel.selfComputeSlot = 2;
    t.channel.refreshAdvertisedSlot(); await flush();
    const workerId = t.channel.advertisingId;
    const calls = t.advertiseCalls;
    let stopped;
    t.behavior.stopGate = new Promise(resolve => { stopped = resolve; });
    t.channel.selfComputeSlot = 1;
    t.channel.refreshAdvertisedSlot();
    t.channel.refreshAdvertisedSlot();
    await flush();
    assert.equal(t.advertiseCalls, calls, 'new hub start waits for old worker stop completion');
    assert.equal(t.channel.advertising, false, 'a stop in progress is not a live hub advertisement');
    assert.equal(t.behavior.advertisingStops.filter(id => id === workerId).length, 1,
      'multiple refreshes issue only one ID-specific stop');
    stopped(); t.behavior.stopGate = null; await flush();
    assert.equal(t.advertiseCalls, calls + 1);
    assert.equal(t.channel.lastAdvertisedSlot, 1);
    assert.equal(new Uint8Array(t.advertise.manufactureData[0].manufactureValue)[1], 1);
    t.advState(workerId, 4);
    assert.equal(t.channel.advertising, true, 'late stopped event for old ID cannot invalidate new hub');
    const hubId = t.channel.advertisingId;
    t.advState(hubId, 4);
    assert.equal(t.channel.advertising, false, 'unexpected stopped event clears optimistic state');
    await advance(1000);
    assert.equal(t.advertiseCalls, calls + 2, 'stopped hub advertisement automatically recovers');
    t.channel.disconnect(); await flush();
  }
  {
    const t = build(true, 'late-advertise-after-disable');
    let started;
    t.behavior.startGate = new Promise(resolve => { started = resolve; });
    await t.channel.prepare(); await flush();
    assert.equal(t.channel.advertising, false, 'submitted start is not confirmed yet');
    t.channel.disconnect();
    started(); await flush();
    assert.equal(t.channel.advertising, false);
    assert.equal(t.channel.advertisingId, -1);
    assert.deepEqual(t.behavior.advertisingStops, [1], 'late successful start is cleaned up by its own ID');
    assert.equal(t.advertiseCalls, 1, 'manual disable must never restart an advertiser');
  }
  {
    const t = build(true, 'advertise-stopped-before-result');
    t.behavior.earlyStopped = true;
    await t.channel.prepare(); await flush();
    assert.equal(t.channel.advertising, false, 'STOPPED before start promise resolves is not lost');
    t.behavior.earlyStopped = false;
    await advance(1000);
    assert.equal(t.channel.advertising, true);
    t.channel.disconnect(); await flush();
  }
  {
    const t = build(true, 'advertise-start-without-state');
    t.behavior.silentStart = true;
    await t.channel.prepare(); await flush();
    assert.equal(t.channel.advertising, false, 'returning an ID is not the same as being on the air');
    t.behavior.silentStart = false;
    await advance(2000);
    assert.equal(t.channel.advertising, false, 'the failed start only arms a retry');
    await advance(1000);
    assert.equal(t.channel.advertising, true, 'retry waits for STARTED before claiming success');
    t.channel.disconnect(); await flush();
  }

  // --- 8. A key that ends exactly on the packet boundary is still read -----------
  {
    const t = build(true, 'adv-key-boundary');
    await t.channel.prepare();
    // [len][0xFF][id lo][id hi][type][slot][4 key bytes] with nothing after it: the
    // last key byte sits on bytes.length - 1, which the old `>=` guard discarded.
    const exact = new Uint8Array([9, 0xFF, 0x77, 0x6E, 1, 1, 0xDE, 0xAD, 0xBE, 0xEF]).buffer;
    t.behavior.names = { 'aa:bb:cc:dd:ee:41': '算力设备1' };
    t.behavior.devices = [{ deviceId: 'listed', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    t.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:41', deviceName: '', rssi: -50, data: exact }];
    const scanning = t.channel.computeDevices();
    await advance(SCAN_WINDOW);
    await scanning;
    const advertised = t.channel.lastHits;
    assert.equal(advertised.length, 1, 'a boundary-aligned advertisement is still a compute');
    assert.equal(advertised[0].compute, true, 'it is recognised as one of ours');
    assert.equal(advertised[0].slot, 1, 'the slot byte is readable');
    assert.equal(advertised[0].key, 'deadbeef', 'its fingerprint survives the boundary check');
    assert.equal(t.channel.connectComputes().join(','), 'aa:bb:cc:dd:ee:41',
      'and it is a hub candidate, so the key reached the dedup path');

    // A packet one byte short must still be rejected.
    const short = new Uint8Array([8, 0xFF, 0x77, 0x6E, 1, 1, 0xDE, 0xAD, 0xBE]).buffer;
    const second = build(true, 'adv-key-short');
    second.behavior.names = { 'aa:bb:cc:dd:ee:51': '算力设备1' };
    second.behavior.devices = [{ deviceId: 'listed', deviceName: '算力设备1', deviceType: 'phone', networkId: 'net-1' }];
    second.behavior.scanData = [{ deviceId: 'aa:bb:cc:dd:ee:51', deviceName: '', rssi: -50, data: short }];
    await second.channel.prepare();
    const secondScan = second.channel.computeDevices();
    await advance(SCAN_WINDOW);
    await secondScan;
    assert.equal(second.channel.lastHits[0].key, '', 'a truncated key is absent, not misread');
  }

  console.log('PASS: linkEnhance channel advertisement identity, peer links and stray-frame handling');
  console.log('PASS: hub-only dial candidates; refused advertisement retries; boundary-aligned key');
})().catch(error => {
  console.error('SUITE FAILED:', error && error.message);
  console.error(error && error.stack);
  process.exitCode = 1;
});
