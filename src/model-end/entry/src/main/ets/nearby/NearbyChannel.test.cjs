// node NearbyChannel.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/typescript.js');
const util = {
  TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
  TextDecoder: { create: (encoding, options) => ({ decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }) },
  Base64Helper: class {
    encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
  }
};
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function setup(server) {
  const handlers = new Map(), destroyed = [], sent = [], timers = new Map(), intervals = new Map(), logs = [];
  let nextSession = 0, nextTimer = 0;
  const behavior = { connect: async () => ({ isConnected: true }), accept: async () => {}, send: async () => {}, permission: 0 };
  const manager = { getAvailableDeviceListSync: () => [{ networkId: 'peer' }, { networkId: '' }] };
  const acm = {
    StartOptionParams: { START_IN_FOREGROUND: 1 },
    createAbilityConnectionSession: () => ++nextSession,
    connect: id => behavior.connect(id), acceptConnect: id => behavior.accept(id),
    sendMessage: async (id, text) => { sent.push({ id, text }); await behavior.send(id, text); },
    on: (event, id, fn) => handlers.set(`${id}:${event}`, fn),
    off: (event, id) => handlers.delete(`${id}:${event}`),
    destroyAbilityConnectionSession: id => destroyed.push(id)
  };
  const modules = {};
  const load = (file, fromDir) => {
    const context = { exports: {}, Uint8Array, Date,
      setTimeout: fn => { timers.set(++nextTimer, fn); return nextTimer; }, clearTimeout: id => timers.delete(id),
      setInterval: fn => { intervals.set(++nextTimer, fn); return nextTimer; }, clearInterval: id => intervals.delete(id),
      require: name => {
        if (name === '@kit.ArkTS') return { util };
        if (name === '@kit.DistributedServiceKit') return { abilityConnectionManager: acm,
          distributedDeviceManager: { createDeviceManager: () => manager, releaseDeviceManager: () => { behavior.released = true; } } };
        if (name === '@kit.AbilityKit') return { abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
          verifyAccessTokenSync: () => behavior.permission, requestPermissionsFromUser: () => behavior.authorize ? behavior.authorize() : Promise.resolve({ authResults: [behavior.permission] })
        }) } };
        if (name === '@kit.PerformanceAnalysisKit') return { hilog: Object.fromEntries(
          ['info', 'error', 'warn'].map(level => [level, (...args) => logs.push({ level, args })])) };
        if (name === './NearbyConfig') return { IS_SERVER: server };
        if (name === './ChatProtocol' || name === '../protocol/ChatProtocol') return modules.protocol;
        throw Error(name);
      }
    };
    vm.runInNewContext(ts.transpileModule(fs.readFileSync((fromDir || __dirname) + '/' + file + '.ets', 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText, context);
    return context.exports;
  };
  modules.protocol = load('ChatProtocol', __dirname + '/../protocol');
  const channel = new (load('NearbyChannel').NearbyChannel)();
  channel.initialize({ applicationInfo: { accessTokenId: 1 } });
  const messages = [], states = [];
  const subscribe = () => channel.subscribe((m, epoch) => messages.push({ m, epoch }), (ready, epoch) => states.push({ ready, epoch }));
  const event = (type, id, extra = {}) => handlers.get(`${id}:${type}`)?.({ sessionId: id, ...extra });
  let sequence = 0;
  const receive = (id, message) => modules.protocol.encodeMessage(message, 'remote-' + (++sequence)).forEach(msg => event('receiveMessage', id, { msg }));
  const decoded = () => {
    const assembler = new modules.protocol.MessageAssembler();
    return sent.map(({ text }) => assembler.receive(text)).filter(Boolean);
  };
  const params = { PeerInfo: { deviceId: 'peer', bundleName: 'com.jiuwen.registrychatui', moduleName: 'entry', abilityName: 'EntryAbility' }, 'ohos.dms.collabToken': 'token' };
  return { channel, behavior, handlers, timers, intervals, destroyed, sent, messages, states, logs, subscribe, event, receive, decoded, params };
}
(async () => {
  const client = setup(false); client.subscribe();
  client.behavior.connect = async id => { client.event('connect', id); return { isConnected: true }; };
  await client.channel.connect('peer'); await flush();
  assert.equal(client.decoded().filter(m => m.type === 'hello').length, 1, 'event + promise must send hello once');
  client.receive(1, { type: 'hello_ack' });
  assert(client.channel.isConnected()); assert.equal(client.timers.size, 0);
  client.receive(1, { type: 'delta', requestId: 'r', text: '你好' });
  assert.equal(client.messages[0].m.text, '你好');
  client.event('disconnect', 1, { sessionId: 999 }); assert(client.channel.isConnected());
  client.channel.disconnect(); assert.equal(client.handlers.size, 0); assert.deepEqual(client.destroyed, [1]);

  const server = setup(true);
  assert(server.channel.accept(server.params)); server.event('connect', 1);
  server.receive(1, { type: 'hello' }); await flush();
  assert(!server.channel.isConnected()); assert.equal(server.sent.length, 0, 'cold ability waits for UI subscriber');
  server.subscribe(); await flush();
  assert(server.channel.isConnected()); assert.equal(server.decoded()[0].type, 'hello_ack');
  server.receive(1, { type: 'request', requestId: 'r', messages: [{ role: 'user', content: '你好' }] });
  assert.equal(server.messages[0].m.messages[0].content, '你好');
  const epoch = server.messages[0].epoch;
  let release;
  server.behavior.send = () => new Promise(resolve => { release = resolve; });
  const delta = server.channel.send({ type: 'delta', requestId: 'r', text: '回答' }, epoch);
  const done = server.channel.send({ type: 'done', requestId: 'r' }, epoch);
  await flush(); assert.equal(server.decoded().at(-1).type, 'delta');
  server.behavior.send = async () => {}; release();
  assert(await delta); assert(await done);
  assert.deepEqual(server.decoded().slice(-2).map(m => m.type), ['delta', 'done']);
  const stale = server.channel.send({ type: 'done', requestId: 'r' }, epoch);
  server.channel.disconnect(); assert(server.channel.accept(server.params));
  server.event('connect', 2); server.receive(2, { type: 'hello' }); await flush();
  assert.equal(await stale, false);
  assert.equal(await server.channel.send({ type: 'done', requestId: 'r' }, epoch), false);
  assert.equal(server.sent.filter(s => s.id === 2).length, 1, 'new session only got its handshake');
  server.receive(2, { type: 'delta', requestId: 'r', text: 'wrong direction' });
  assert(!server.channel.isConnected());

  for (const failure of [async () => ({ isConnected: false, errorCode: 1 }), async () => { throw Error('connect'); }]) {
    const c = setup(false); c.behavior.connect = failure;
    await c.channel.connect('peer'); assert(!c.channel.isConnecting()); assert.equal(c.handlers.size, 0); assert.equal(c.destroyed.length, 1);
  }
  for (const [code, reason] of [[2, '聊天手机的Wi-Fi未开启'], [3, '模型手机近场链路冲突或Wi-Fi不可用'], [99, '未知原因']]) {
    const c = setup(false);
    c.behavior.connect = async () => ({ isConnected: false, errorCode: code });
    await c.channel.connect('peer');
    assert(c.channel.getStatus().includes(reason), 'connection status must explain error code ' + code);
    assert(c.channel.getStatus().includes(String(code)));
  }
  const lateFailure = setup(false); let failNative;
  lateFailure.behavior.connect = () => new Promise(resolve => { failNative = resolve; });
  const lateAttempt = lateFailure.channel.connect('peer'); await flush();
  lateFailure.event('disconnect', 1, { reason: 2 }); await lateAttempt;
  failNative({ isConnected: false, errorCode: 3 }); await flush();
  const resultLog = lateFailure.logs.find(log => log.args[2].startsWith('connect result'));
  assert(resultLog, 'native result must remain logged after disconnect removes the peer');
  assert.deepEqual(resultLog.args.slice(3), [1, 'false', '3']);
  assert(!lateFailure.channel.isConnected()); assert.deepEqual(lateFailure.destroyed, [1]);
  assert(lateFailure.channel.getStatus().includes('模型手机近场链路冲突或Wi-Fi不可用'));
  for (const reconnect of [false, true]) {
    const s = setup(false); let rejectNative;
    s.behavior.connect = () => new Promise((resolve, reject) => { rejectNative = reject; });
    const attempt = s.channel.connect('peer'); await flush();
    s.event('disconnect', 1, { reason: 2 }); await attempt;
    if (reconnect) {
      s.behavior.connect = async () => ({ isConnected: true });
      await s.channel.connect('peer'); s.receive(2, { type: 'hello_ack' });
    }
    rejectNative({ code: 801 }); await flush();
    assert(s.logs.some(log => log.args[2].startsWith('connect API failed') && log.args[4] === '801'));
    assert.equal(s.channel.isConnected(), reconnect);
    assert(reconnect ? s.channel.getStatus() === '近场已连接' : s.channel.getStatus().includes('801'));
    s.channel.destroy();
  }
  for (const [stage, change] of [
    ['permission', s => { s.behavior.permission = -1; }],
    ['peer-fields/token', s => { s.params.PeerInfo.bundleName = 'other'; }],
    ['trusted-peer', s => { s.params.PeerInfo.deviceId = 'offline'; }]
  ]) {
    const s = setup(true);
    s.params['ohos.dms.collabToken'] = 'SECRET-COLLAB-TOKEN-DO-NOT-LOG'; change(s);
    assert.equal(s.channel.accept(s.params), false);
    assert(s.logs.some(log => log.level === 'warn' && log.args[2].startsWith('collaborate rejected') && log.args[3] === stage));
    assert(!JSON.stringify(s.logs).includes('SECRET-COLLAB-TOKEN-DO-NOT-LOG'), 'rejection diagnostics must omit token values');
  }
  const denied = setup(false); denied.behavior.permission = -1;
  await assert.rejects(denied.channel.connect('peer')); assert.equal(denied.handlers.size, 0);
  const absent = setup(false); await assert.rejects(absent.channel.connect('other'));
  const reject = setup(true); reject.behavior.accept = async () => { throw Error('accept'); };
  assert(reject.channel.accept(reject.params)); await flush(); assert(!reject.channel.isConnecting()); assert.equal(reject.handlers.size, 0);
  for (const patch of [{ bundleName: 'other' }, { deviceId: 'other' }, { abilityName: 'Other' }]) {
    const s = setup(true); assert.equal(s.channel.accept({ ...s.params, PeerInfo: { ...s.params.PeerInfo, ...patch } }), false);
    assert.equal(s.handlers.size, 0);
  }
  const invalid = setup(false); invalid.subscribe(); await invalid.channel.connect('peer'); invalid.receive(1, { type: 'hello_ack' });
  invalid.event('receiveMessage', 1, { msg: '{}' }); assert(!invalid.channel.isConnected()); assert.equal(invalid.handlers.size, 0);
  const capped = setup(false); capped.subscribe(); await capped.channel.connect('peer'); await flush(); capped.receive(1, { type: 'hello_ack' });
  const queued = Array.from({ length: 65 }, () => capped.channel.send({ type: 'cancel', requestId: 'r' }));
  assert(!capped.channel.isConnected()); assert((await Promise.all(queued)).every(result => result === false));
  capped.channel.destroy(); assert(capped.behavior.released);
  const syncReject = setup(true); syncReject.behavior.accept = () => { throw Error('sync accept'); };
  assert.equal(syncReject.channel.accept(syncReject.params), false);
  assert.equal(syncReject.channel.isConnecting(), false, 'synchronous accept failure must release peer');
  assert.equal(syncReject.handlers.size, 0);
  const readySend = setup(true);
  readySend.channel.subscribe(() => {}, ready => {
    if (ready) readySend.channel.send({ type: 'done', requestId: 'r' });
  });
  assert(readySend.channel.accept(readySend.params)); readySend.event('connect', 1);
  readySend.receive(1, { type: 'hello' }); await flush();
  assert.equal(readySend.decoded()[0].type, 'hello_ack', 'handshake must precede ready callback sends');
  for (const end of ['timeout', 'disconnect']) {
    const hanging = setup(false); let completeNative, returned = false;
    hanging.behavior.connect = () => new Promise(resolve => { completeNative = resolve; });
    const attempt = hanging.channel.connect('peer').then(() => { returned = true; });
    await flush(); assert(hanging.channel.isConnecting()); assert.equal(hanging.intervals.size, 1);
    if (end === 'timeout') [...hanging.timers.values()][0](); else hanging.channel.disconnect();
    await flush(); assert(returned, 'native connect must not keep UI awaiting after ' + end);
    await attempt; assert.equal(hanging.intervals.size, 0); assert.equal(hanging.timers.size, 0);
    assert.equal(hanging.handlers.size, 0);
    completeNative({ isConnected: true }); await flush();
    assert(!hanging.channel.isConnected()); assert.equal(hanging.sent.length, 0, 'late resolution cannot revive dropped session');
  }
  const permissionWait = setup(false); let grant;
  permissionWait.behavior.permission = -1;
  permissionWait.behavior.authorize = () => new Promise(resolve => { grant = resolve; });
  const waitingPermission = permissionWait.channel.connect('peer');
  const permissionRejected = assert.rejects(waitingPermission, /取消/);
  permissionWait.channel.suspend(); grant({ authResults: [0] }); await permissionRejected;
  assert.equal(permissionWait.handlers.size, 0); assert.equal(permissionWait.destroyed.length, 0);
  const deviceWait = setup(false); let resolveDevices;
  deviceWait.channel.devices = () => new Promise(resolve => { resolveDevices = resolve; });
  const waitingDevices = assert.rejects(deviceWait.channel.connect('peer'), /取消/);
  deviceWait.channel.suspend(); resolveDevices([{ networkId: 'peer' }]); await waitingDevices;
  assert.equal(deviceWait.handlers.size, 0); assert.equal(deviceWait.intervals.size, 0);
  const picker = setup(false); const pickerOperation = picker.channel.operation();
  picker.channel.suspend(); picker.channel.resume();
  await assert.rejects(picker.channel.connect('peer', pickerOperation), /取消/);
  assert.equal(picker.handlers.size, 0);
  await picker.channel.connect('peer', picker.channel.operation()); assert(picker.channel.isConnecting());
  picker.channel.disconnect(); assert.equal(picker.intervals.size, 0); assert.equal(picker.timers.size, 0);
  readySend.channel.disconnect(); assert.equal(readySend.intervals.size, 0);
  const handshake = setup(false); handshake.subscribe();
  assert.equal(await handshake.channel.waitUntilConnected(), false);
  await handshake.channel.connect('peer');
  let handshakeReady = false;
  const waited = handshake.channel.waitUntilConnected().then(ready => { handshakeReady = ready; return ready; });
  await flush(); assert.equal(handshakeReady, false, 'native connect alone is not a handshake');
  handshake.receive(1, { type: 'hello_ack' }); assert.equal(await waited, true);
  let serviceDone = false;
  const checking = handshake.channel.checkService();
  assert.equal(handshake.channel.checkService(), checking, 'coalesce simultaneous readiness checks');
  checking.then(() => { serviceDone = true; }); await flush();
  const preparationId = handshake.decoded().at(-1).requestId;
  assert.equal(handshake.decoded().filter(m => m.type === 'prepare').length, 1);
  handshake.receive(1, { type: 'prepared', requestId: 'wrong' }); await flush(); assert(!serviceDone);
  handshake.receive(1, { type: 'prepared', requestId: preparationId }); assert.equal(await checking, '');
  assert.equal(handshake.timers.size, 0);
  const busyCheck = handshake.channel.checkService(); await flush();
  handshake.receive(1, { type: 'prepared', requestId: handshake.decoded().at(-1).requestId, error: '模型忙' });
  assert.equal(await busyCheck, '模型忙');
  const timed = handshake.channel.checkService(); await flush();
  const staleTimeout = [...handshake.timers.values()][0]; staleTimeout();
  assert((await timed).includes('超时'));
  let newerDone = false;
  const newer = handshake.channel.checkService(); newer.then(() => { newerDone = true; }); await flush();
  staleTimeout(); await flush(); assert(!newerDone, 'old timeout cannot complete a newer check');
  handshake.receive(1, { type: 'prepared', requestId: handshake.decoded().at(-1).requestId });
  assert.equal(await newer, '');
  // Isolate delayed send completion without causing a real transport disconnect.
  const originalSend = handshake.channel.send.bind(handshake.channel);
  let finishOldSend;
  handshake.channel.send = () => new Promise(resolve => { finishOldSend = resolve; });
  const oldSendCheck = handshake.channel.checkService();
  [...handshake.timers.values()][0](); assert((await oldSendCheck).includes('超时'));
  handshake.channel.send = originalSend;
  const afterOldSend = handshake.channel.checkService(); let afterOldDone = false;
  afterOldSend.then(() => { afterOldDone = true; }); await flush();
  finishOldSend(false); await flush(); assert(!afterOldDone, 'old send failure cannot resolve a newer check');
  handshake.receive(1, { type: 'prepared', requestId: handshake.decoded().at(-1).requestId });
  assert.equal(await afterOldSend, '');
  const droppedCheck = handshake.channel.checkService(); handshake.channel.disconnect();
  assert((await droppedCheck).length > 0); assert.equal(handshake.timers.size, 0);
  await handshake.channel.connect('peer');
  const droppedHandshake = handshake.channel.waitUntilConnected(); handshake.channel.disconnect();
  assert.equal(await droppedHandshake, false);
  console.log('PASS: readiness handshake gating/coalescing/matched replies/errors/timeout/stale callbacks/disconnect');
  console.log('PASS: both roles, cold collaboration, single handshake, failed connect/accept, Wi-Fi failure status, late failure diagnostics, rejection stages without tokens, permissions/peer/schema rejection, epoch queue isolation, ordered delta/done, disconnect cleanup, 64-message backpressure, native connect cancellation/late completion, suspended permission/device waits, stale picker operation, timer cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
