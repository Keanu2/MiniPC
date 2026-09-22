// node IndexFocus.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile, transpileSource } = require('../../../../../../tests/harness.cjs');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function loadEts(file) {
  const box = { exports: {}, Error, Map, Math, Number, Date, Promise, JSON };
  vm.runInNewContext(transpile(file), box);
  return box.exports;
}
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function setup(isServer) {
  let connected = false, operation = 0, connections = 0, disconnects = 0, checks = 0;
  const events = [], sent = [];
  const behavior = { devices: [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }],
    check: async () => '', connect: async () => { connected = true; }, wait: async () => connected };
  const channel = {
    isConnected: () => connected, isConnecting: () => false, operation: () => operation,
    devices: async () => behavior.devices,
    computeDevices: async () => behavior.devices,
    hasComputeHits: () => !!behavior.hits,
    connectToAdvertisers: async () => { connections++; await behavior.connect(); },
    connect: async (id, expected) => { assert.equal(id, 'current'); assert.equal(expected, operation); connections++; await behavior.connect(); },
    waitUntilConnected: () => behavior.wait(), checkService: () => { checks++; return behavior.check(); },
    connectedCount: () => connected ? 1 : 0, hasEpoch: () => connected, peerInfos: () => [],
    peerRole: () => '', connectOtherComputes: async () => { behavior.meshCalls = (behavior.meshCalls || 0) + 1; },
    setActiveJobs: count => { behavior.activeJobs = count; },
    localName: () => '算力设备',
    localUid: () => 'self-uid',
    isListening: () => !!behavior.listening, prepare: async () => { behavior.listening = true; },
    selfLabel: () => '算力设备1',
    selfComputeNumber: () => 1,
    applyRemoteRoster() {},
    setSelfMem() {}, setPeerMem() {}, setRemoteChats(names) { behavior.remoteChats = names.slice(); },
    disconnect: () => { disconnects++; operation++; connected = false; behavior.listening = false; },
    getStatus: () => connected ? '近场已连接' : '未连接',
    send: async message => { sent.push(message); return true; }
  };
  const context = { exports: {}, Error, Map, Math, Number, Date, Promise, JSON, setInterval() { return 1; }, clearInterval() {},
    require(name) {
    if (name === '@kit.ArkWeb') return { webview: { WebviewController: class {
      async runJavaScript(script) { events.push(JSON.parse(script.slice('window.onNativeEvent('.length, -1))); }
    } } };
    if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'request-1' } };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {} } };
    if (name === '../nearby/LinkEnhanceChannel') {
      return { nearbyChannel: channel };
    }
    if (name === '../nearby/NearbyConfig') return { IS_SERVER: !!isServer };
    if (name === '../llm/LocalChat') return { LocalChat: class {} };
    if (name === '../llm/LlmTransport') return { LocalLlmTransport: class {
      constructor(chat) { this.chat = chat; }
      start(messages, cb, id) { return this.chat.start(messages, cb, id); }
      cancel(id) { this.chat.cancel(id); }
      readinessError() { return this.chat.readinessError(); }
    } };
    if (name === '../cluster/ComputeRouter') {
      return loadEts(__dirname + '/../cluster/ComputeRouter.ets');
    }
    if (name === '../cluster/DeviceLabels') {
      return loadEts(__dirname + '/../cluster/DeviceLabels.ets');
    }
    if (name === '../ui/ChatBridge') return loadEts(__dirname + '/../ui/ChatBridge.ets');
    if (name === '../cluster/DeviceInfo') return {
      DEVICE_INFO_POLL_MS: 5000,
      applyDeviceInfo(target, message) {
        if (typeof message.name === 'string' && message.name.length > 0) target.name = message.name;
        if (typeof message.memTotal === 'number') target.memTotal = message.memTotal;
        if (typeof message.memAvail === 'number') target.memAvail = message.memAvail;
        if (typeof message.memUsage === 'number') target.memUsage = message.memUsage;
        if (typeof message.model === 'string') target.model = message.model;
        if (typeof message.modelRequests === 'number') target.modelRequests = message.modelRequests;
      },
      buildSelfEntry(_dir, running) {
        return { name: '本机', id: 'self', role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
          modelRequests: running, memUsage: 10, memAvail: 1000, memTotal: 2000 };
      },
      deployedModelName: () => 'Qwen2.5-7B-Instruct-Q4_N_0',
      formatComputeStatus: () => 'Qwen',
      toDeviceInfoReply: (id, entry) => ({
        type: 'deviceInfo', requestId: id, name: entry.name, model: entry.model,
        memUsage: entry.memUsage, modelRequests: entry.modelRequests, peerRole: 'compute'
      })
    };
    if (name === '../media/ImageAttach') return { pickJpegDataUrl: async () => '' };
    return {};
  } };
  let source = fs.readFileSync(__dirname + '/Index.ets', 'utf8');
  source = source.replace(/@Entry\s+@Component\s+struct Index/, 'export class Index');
  source = source.slice(0, source.indexOf('  build() {')) + '\n}';
  vm.runInNewContext(transpileSource(source), context);
  const page = new context.exports.Index(); page.pageReady = true;
  return { page, channel, behavior, events, sent, counts: () => ({ connections, disconnects, checks }), setConnected: value => { connected = value; } };
}
(async () => {
  const c = setup(), check = deferred(); c.behavior.check = () => check.promise;
  const preparing = c.page.ensureCollaborationReady();
  assert.equal(c.page.ensureCollaborationReady(), preparing);
  await flush(); assert.equal(c.counts().connections, 1); assert.equal(c.counts().checks, 1);
  assert(c.events.every(event => !event.available), 'link alone never enables send');
  assert(c.page.send('保留草稿').includes('尚未准备')); assert.equal(c.sent.length, 0);
  assert.equal(c.page.history.length, 0); assert.equal(c.page.activeId, '');
  check.resolve(''); await preparing;
  assert.equal(c.page.serviceReady, true); assert(c.events.at(-1).available);
  await c.page.ensureCollaborationReady();
  assert.deepEqual(c.counts(), { connections: 1, disconnects: 0, checks: 1 }, 'prepared focus reuses session');
  assert.equal(c.page.send('真实问题'), ''); await flush();
  assert.equal(c.sent.length, 1); assert.equal(c.sent[0].type, 'request');
  assert.equal(c.sent[0].messages[0].content, '真实问题');
  for (const error of ['模型忙', '模型文件缺失']) {
    const f = setup(); f.behavior.check = async () => error;
    await f.page.ensureCollaborationReady(); assert.equal(f.page.serviceReady, false);
    assert.equal(f.page.connectionError, error); assert.equal(f.page.activeId, ''); assert.equal(f.sent.length, 0);
    f.behavior.check = async () => ''; await f.page.ensureCollaborationReady();
    assert.equal(f.page.serviceReady, true); assert.equal(f.counts().connections, 1);
    assert.equal(f.counts().disconnects, 0); assert.equal(f.counts().checks, 2);
  }
  const offline = setup(); offline.behavior.devices = [];
  await offline.page.ensureCollaborationReady(); assert(offline.page.connectionError.includes('未发现'));
  assert.equal(offline.sent.length, 0); assert.equal(offline.page.serviceReady, false);
  offline.behavior.devices = [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }];
  await offline.page.ensureCollaborationReady(); assert(offline.page.serviceReady);
  const unnamed = setup(); unnamed.behavior.devices = []; unnamed.behavior.hits = true;
  await unnamed.page.ensureCollaborationReady(); assert(unnamed.page.serviceReady);
  assert.equal(unnamed.counts().connections, 1);
  const stale = setup(), pending = deferred(); stale.behavior.check = () => pending.promise;
  const old = stale.page.ensureCollaborationReady(); await flush();
  stale.channel.disconnect(); pending.resolve(''); await old;
  assert.equal(stale.page.serviceReady, false); assert(stale.events.every(event => !event.available));
  stale.behavior.check = async () => ''; await stale.page.ensureCollaborationReady(); assert(stale.page.serviceReady);
  const hidden = setup(), delayed = deferred(); hidden.behavior.check = () => delayed.promise;
  const hiddenWork = hidden.page.ensureCollaborationReady(); await flush(); hidden.page.pageReady = false;
  delayed.resolve(''); await hiddenWork; assert.equal(hidden.page.serviceReady, false);
  console.log('PASS: focus preparation coalescing, prepared reuse, business-ready send gate, busy/missing/offline retry, stale/hidden result rejection, actual send only after readiness');
})().catch(error => { console.error(error); process.exitCode = 1; });
// Execute the actual HTML event handlers with a small DOM stub.
{
  const makeElement = () => {
    const el = { handlers: {}, value: '', textContent: '', innerHTML: '', style: {}, attrs: {}, classList: { add() {}, remove() {}, toggle() {} },
      addEventListener(type, fn) { this.handlers[type] = fn; },
      setAttribute(k, v) { this.attrs[k] = v; },
      getAttribute(k) { return this.attrs[k]; },
      appendChild() {}, blur() {} };
    return el;
  };
  const elements = Object.fromEntries(['history', 'prompt', 'send', 'connect', 'composer', 'connection',
    'stats', 'devices', 'pick', 'preview', 'previewImg', 'previewClear', 'title'].map(id => [id, makeElement()]));
  const document = { handlers: {}, getElementById: id => elements[id], createElement: makeElement,
    addEventListener(type, fn) { this.handlers[type] = fn; } };
  let preparations = 0;
  const window = { chatBridge: { prepare() { preparations++; }, connect() {}, send() { return '协同尚未准备完成'; } } };
  const html = fs.readFileSync(__dirname + '/../../resources/rawfile/peer-chat.html', 'utf8');
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], { document, window, Date });
  elements.prompt.handlers.pointerdown(); elements.prompt.handlers.focus();
  assert.equal(preparations, 1, 'pointer and resulting focus only prepare once');
  elements.prompt.handlers.focus(); assert.equal(preparations, 1, 'automatic restored focus never retries');
  elements.prompt.handlers.pointerdown(); assert.equal(preparations, 2, 'explicit repeated click retries');
  document.handlers.keydown({ key: 'Tab' }); elements.prompt.handlers.focus();
  assert.equal(preparations, 3, 'explicit keyboard focus prepares');
  elements.prompt.value = '保留草稿';
  window.onNativeEvent({ kind: 'connection', available: false }); assert.equal(elements.send.disabled, true);
  elements.composer.handlers.submit({ preventDefault() {} });
  assert.equal(elements.prompt.value, '保留草稿', 'native readiness rejection preserves draft');
  window.onNativeEvent({ kind: 'connection', available: true }); assert.equal(elements.send.disabled, false);
  window.onNativeEvent({ kind: 'remote-start', text: '远端问题', requestId: 'r1' });
  assert.equal(elements.send.disabled, false, 'remote stream must not lock composer');
  assert.equal(elements.send.getAttribute('aria-label'), '发送');
  let picked = 0, sent = '';
  window.chatBridge.pickImage = () => { picked++; };
  window.chatBridge.send = (text) => { sent = text; return ''; };
  elements.pick.handlers.click();
  assert.equal(picked, 1);
  window.onNativeEvent({ kind: 'image', text: 'data:image/jpeg;base64,xx' });
  elements.prompt.value = '';
  assert.equal(elements.send.disabled, false, 'image alone enables send');
  elements.composer.handlers.submit({ preventDefault() {} });
  assert.equal(sent, '请描述这张图片。');
  window.onNativeEvent({
    kind: 'dashboard', running: 2, jobs: [], selfLabel: '算力设备2',
    devices: [
      { role: 'self', name: '算力设备2', ready: true, jobs: 2, memUsage: 41, model: 'Qwen2.5-7B-Instruct' },
      { role: 'chat', name: '聊天设备1', ready: true, jobs: 1 }
    ]
  });
  assert.equal(elements.title.textContent, '算力设备2');
  assert(elements.devices.innerHTML.includes('算力设备2'));
  assert(elements.devices.innerHTML.includes('推理 2'), 'compute card shows running job count');
  window.onNativeEvent({
    kind: 'dashboard', running: 1, jobs: [], selfLabel: '算力设备1',
    devices: [
      { role: 'self', name: '算力设备1', ready: true, jobs: 1, memUsage: 41, modelRequests: 2, model: 'Qwen2.5-7B-Instruct' }
    ]
  });
  assert(elements.devices.innerHTML.includes('推理 1'), 'card uses jobs, not sampled+inflight');
  assert(!elements.devices.innerHTML.includes('推理 2'), 'inflated modelRequests must not double the badge');
  assert(elements.devices.innerHTML.includes('内存'), 'compute card still shows memory');
  window.onNativeEvent({ kind: 'dashboard', running: 1, selfLabel: '算力设备1', devices: [], jobs: [{
    id: 'time-1', key: '0:time-1', source: '算力设备1', origin: '聊天设备1', question: '时间测试', answer: '',
    chars: 0, startedAt: new Date(2026, 8, 21, 10, 30, 45).getTime(), firstAt: 0, endedAt: 0,
    running: true, error: false, elapsedMs: 1200
  }] });
  assert(elements.history.innerHTML.includes('创建 09-21 10:30:45'), 'task card shows its creation time');
  // A streaming reply patches its own card immediately, instead of waiting up to five
  // seconds for the next dashboard poll.
  window.onNativeEvent({ kind: 'text', requestId: 'time-1', text: '流式第一段' });
  assert(elements.history.innerHTML.includes('流式第一段'), 'streaming text reaches its card at once');
  window.onNativeEvent({ kind: 'done', requestId: 'time-1', text: '流式完成', error: false });
  assert(elements.history.innerHTML.includes('流式完成'), 'the final text replaces the partial one');
  assert(!elements.history.innerHTML.includes('进行中'), 'the card leaves the running state');
  window.onNativeEvent({ kind: 'text', requestId: 'not-on-the-board', text: '无关文本' });
  assert(!elements.history.innerHTML.includes('无关文本'), 'an event for an unknown job patches nothing');
  window.onNativeEvent({
    kind: 'dashboard', running: 0, jobs: [], selfLabel: '算力设备',
    devices: [{ role: 'self', name: '算力设备', ready: true, jobs: 0 }]
  });
  assert.equal(elements.title.textContent, '算力设备1', 'numbered title must not fall back to bare 算力设备');
  assert(!elements.devices.innerHTML.includes('聊天设备2'), 'chat slots must not fall back to list index');
  console.log('PASS: HTML pointer/focus dedup, automatic focus no retry, explicit click/Tab retries, send availability and draft preservation');
}

{
  const s = setup(true);
  const callbacks = new Map();
  s.page.model = {
    start(messages, cb, id) {
      callbacks.set(id, cb);
      return '';
    },
    isBusy() { return callbacks.size > 0; },
    activeCount() { return callbacks.size; },
    readinessError() { return ''; },
    cancel(id) {
      const cb = callbacks.get(id);
      if (!cb) return;
      callbacks.delete(id);
      cb({ kind: 'done', text: '已停止生成', finishReason: 'cancelled' });
    }
  };
  s.page.pageReady = true;
  s.page.receive({ type: 'prepare', requestId: 'p1' }, 1);
  assert.equal(s.sent.find(item => item.type === 'prepared').error, undefined);
  assert.equal(s.sent.filter(item => item.type === 'deviceInfo').length, 1);
  s.page.receive({ type: 'request', requestId: 'r1', messages: [{ role: 'user', content: 'A' }] }, 1);
  s.page.receive({ type: 'request', requestId: 'r2', messages: [{ role: 'user', content: 'B' }] }, 2);
  assert.equal(s.page.jobs.length, 2);
  assert.equal(s.page.jobs[0].source, '算力设备1');
  assert.equal(s.page.jobs[0].origin.indexOf('聊天设备') >= 0 || s.page.jobs[0].origin.length > 0, true);
  s.page.receive({ type: 'prepare', requestId: 'p2' }, 2);
  const prepared = s.sent.filter(item => item.type === 'prepared');
  assert.equal(prepared.at(-1).error, undefined, 'prepare stays ready while two jobs run');
  s.page.receive({ type: 'request', requestId: 'r3', messages: [{ role: 'user', content: 'C' }] }, 1);
  assert.equal(s.page.jobs.length, 3, 'third peer job is accepted without a fixed cap');
  assert.notEqual(s.sent.at(-1).type, 'error');
  s.channel.hasEpoch = epoch => epoch === 2;
  s.page.connectionChanged(true, 1);
  assert.equal(s.page.jobs.length, 1);
  assert.equal(s.page.jobs[0].id, 'r2');
  console.log('PASS: three peer jobs in parallel, prepare not gated, disconnect cancels only that epoch');
}

{
  const s = setup(true);
  s.page.model = {
    start() { return ''; },
    readinessError() { return ''; },
    cancel() {},
    activeCount() { return 0; }
  };
  s.page.pageReady = true;
  s.channel.peerInfos = () => [{ epoch: 7, peerId: 'aa:bb', ready: true, role: 'compute', name: '算力设备2' }];
  s.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 0, memAvail: 8000 });
  s.page.receive({ type: 'request', requestId: 'r1', messages: [{ role: 'user', content: 'A' }] }, 1);
  assert.equal(s.sent.at(-1).type, 'request');
  assert.equal(s.sent.at(-1).sched, true);
  assert.equal(s.sent.at(-1).origin, '聊天设备', 'forwarded work carries the public chat origin');
  // The worker only ever sees the forwarded id, and echoes it back verbatim.
  const forwardId = s.sent.at(-1).requestId;
  assert.equal(forwardId === 'r1', false, 'the wire carries a hand-off id, not the client id');
  assert.equal(s.page.jobs[0].workerEpoch, 7);
  assert.equal(s.page.jobs[0].source, '算力设备2');
  s.page.receive({ type: 'request', requestId: 'r2', messages: [{ role: 'user', content: 'B' }],
    sched: true, origin: '聊天设备3' }, 7);
  assert.equal(s.page.jobs.find(job => job.id === 'r2').workerEpoch, 0, 'sched request stays local');
  assert.equal(s.page.jobs.find(job => job.id === 'r2').origin, '聊天设备3');
  s.page.emitDashboard();
  const board = s.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(board.devices.find(device => device.role === 'self').jobs, 1);
  assert.equal(board.devices.find(device => device.role === 'compute').jobs, 1,
    'the coordinator counts only work actually dispatched to that compute');
  assert.equal(board.running, 1, 'the task rail count includes only work executed by this compute');
  assert.equal(board.jobs.length, 1, 'a coordinator-only hand-off is hidden from this compute task rail');
  assert.equal(board.jobs[0].id, 'r2', 'the locally executed forwarded request remains visible');
  s.page.receive({ type: 'delta', requestId: forwardId, text: 'hi' }, 7);
  assert.equal(s.sent.at(-1).type, 'delta');
  assert.equal(s.sent.at(-1).text, 'hi');
  assert.equal(s.sent.at(-1).requestId, 'r1', 'the origin gets its own id back, not the forwarded one');
  s.page.receive({ type: 'done', requestId: forwardId, finishReason: 'stop' }, 7);
  assert.equal(s.sent.at(-1).type, 'done');
  assert.equal(s.sent.at(-1).source, '由算力设备2推理');
  s.page.receive({ type: 'deviceInfo', requestId: 'info-7', model: 'Qwen', memUsage: 41, modelRequests: 1, memAvail: 7000 }, 7);
  assert.equal(s.page.peerStats.get(7).memUsage, 41);
  s.page.receive({ type: 'deviceInfo', requestId: 'q1' }, 1);
  assert.equal(s.sent.at(-1).type, 'deviceInfo');
  assert.equal(s.sent.at(-1).model, 'Qwen2.5-7B-Instruct-Q4_N_0');
  console.log('PASS: schedule to idle compute, sched stays local, worker reply remapped, deviceInfo poll/reply');
}

{
  const follower = setup(true);
  follower.channel.selfComputeNumber = () => 2;
  follower.page.model = { start() { throw new Error('a follower must not coordinate'); }, activeCount() { return 0; } };
  follower.page.receive({ type: 'request', requestId: 'not-hub',
    messages: [{ role: 'user', content: 'A' }] }, 1);
  assert.equal(follower.sent.at(-1).type, 'error');
  assert(follower.sent.at(-1).error.includes('算力设备1'));
  assert.equal(follower.page.jobs.length, 0);
}

{
  const worker = setup(true);
  worker.page.pageReady = true;
  worker.page.model = { start() { return ''; }, readinessError() { return ''; }, cancel() {}, activeCount() { return 1; } };
  worker.channel.peerInfos = () => [{ epoch: 7, peerId: 'coordinator', ready: true, role: 'compute',
    name: '算力设备2', deviceUid: 'compute-2' }];
  worker.page.receive({ type: 'request', requestId: 'forwarded', messages: [{ role: 'user', content: 'A' }],
    sched: true, origin: '聊天设备1' }, 7);
  worker.page.emitDashboard();
  const board = worker.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(board.devices.find(device => device.role === 'self').jobs, 1);
  assert.equal(board.devices.find(device => device.role === 'compute').jobs, 0,
    'an upstream coordinator is not an inference worker');
  assert.equal(board.jobs[0].origin, '聊天设备1');
  assert.equal(board.jobs[0].source, '算力设备1');

  const ghost = setup(true);
  ghost.page.pageReady = true;
  ghost.page.serviceReady = true;
  ghost.channel.peerInfos = () => [{ epoch: 7, peerId: 'compute-2', ready: true, role: 'compute',
    name: '算力设备2', helloName: '算力设备2', deviceUid: 'compute-2', slot: 2 }];
  ghost.channel.hasEpoch = epoch => epoch === 7;
  ghost.page.remoteSeen.set(7, [{ id: 'chat-live', name: '聊天A', role: 'chat' }]);
  ghost.page.remoteSeen.set(8, [{ id: 'chat-gone', name: '聊天B', role: 'chat' }]);
  ghost.page.cancelDroppedPeers();
  assert.equal(Array.from(ghost.behavior.remoteChats).join(','), '聊天A',
    'a disconnected reporter cannot keep a chat online');
  ghost.page.pollDeviceInfo();
  const sync = ghost.sent.filter(message => message.type === 'deviceInfoSync').at(-1);
  assert(sync.devices.every(device => device.id !== 'chat-live' && device.id !== 'chat-gone'),
    'remote roster entries must not be forwarded into a permanent gossip cycle');

  const quiet = setup(true);
  quiet.page.serviceReady = true;
  quiet.channel.peerInfos = () => [
    { epoch: 1, peerId: 'chat', name: '聊天设备1', helloName: '聊天设备1', ready: true, role: 'chat', slot: 1 },
    { epoch: 2, peerId: 'worker', name: '算力设备2', helloName: '算力设备2', ready: true, role: 'compute', slot: 2 }
  ];
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 1,
    'only the compute worker, not the chat link, receives the multi-frame roster');
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 1,
    'a five-second status poll does not resend an unchanged full roster');
  quiet.channel.peerInfos = () => [
    { epoch: 1, peerId: 'chat', name: '聊天设备1', helloName: '聊天设备1', ready: true, role: 'chat', slot: 1 },
    { epoch: 3, peerId: 'chat-new', name: '聊天设备2', helloName: '聊天设备2', ready: true, role: 'chat', slot: 2 },
    { epoch: 2, peerId: 'worker', name: '算力设备2', helloName: '算力设备2', ready: true, role: 'compute', slot: 2 }
  ];
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.filter(message => message.type === 'deviceInfoSync').length, 2,
    'joining or leaving devices triggers immediate roster publication');
  quiet.sent.length = 0;
  quiet.page.emitDashboard = () => {};
  quiet.page.jobs.push({ id: 'busy', workerEpoch: 0 });
  quiet.page.pollDeviceInfo();
  assert.equal(quiet.sent.length, 0, 'background polling must not compete with inference traffic');

  const order = setup(true);
  order.page.pageReady = true;
  order.channel.peerInfos = () => [
    { epoch: 4, peerId: 'chat-2', deviceUid: 'chat-2', ready: true, role: 'chat', name: '聊天设备2' },
    { epoch: 2, peerId: 'compute-2', deviceUid: 'compute-2', ready: true, role: 'compute', name: '算力设备2' },
    { epoch: 3, peerId: 'chat-1', deviceUid: 'chat-1', ready: true, role: 'chat', name: '聊天设备1' }
  ];
  order.page.emitDashboard();
  const ordered = order.events.filter(event => event.kind === 'dashboard').at(-1).devices.map(device => device.name);
  assert.equal(Array.from(ordered).join(','), '算力设备1,算力设备2,聊天设备1,聊天设备2',
    'compute devices precede chat devices and both groups are sorted by slot');
  console.log('PASS: worker-only inference counts, forwarded chat origin and disconnected roster cleanup');
}

(async () => {
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  s.page.connectNearby();
  assert.equal(s.page.serviceReady, false, 'stop near-field even with no connected peer');
  assert.equal(s.counts().disconnects, 1);
  assert.equal(s.page.autoConnect, false);
  const labels = s.events.map(event => event.connectLabel).filter(Boolean);
  assert.equal(labels.at(-1), '启用近场');
  s.page.connectNearby();
  await flush();
  assert.equal(s.page.serviceReady, true, 'second click starts near-field again');
  assert.equal(s.behavior.meshCalls, 1, 're-enabling near-field restarts compute mesh discovery');
  console.log('PASS: idle compute stop/start near-field toggles without a connected chat phone');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Background telemetry yields to streaming inference, and a chat link dropping is
// reported rather than left as a silent gap the compute side cannot repair itself.
{
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  s.channel.peerInfos = () => [
    { epoch: 2, peerId: 'worker', deviceUid: 'worker', ready: true, role: 'compute', name: '算力设备2', slot: 2 },
    { epoch: 1, peerId: 'chat', deviceUid: 'chat', ready: true, role: 'chat', name: '聊天设备1', slot: 1 }
  ];
  // A chat request lands while the hub has a local job, so the running count changes
  // mid-stream. The status push must wait for the stream to finish.
  s.page.jobs.push({ id: 'busy', key: '0:busy', epoch: 0, peer: false, workerEpoch: 0,
    answer: '', question: 'q', startedAt: 0, firstAt: 0, endedAt: 0, error: false, source: '', origin: '本机', image: '' });
  // Pretend the last published value was 1, so ending the job is a real transition.
  s.page.lastPublishedRunning = 1;
  s.sent.length = 0;
  s.page.emitDashboard();
  assert.equal(s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('status-') === 0).length, 0,
    'no background status push while an inference is in flight');
  assert.equal(s.page.lastPublishedRunning, 1, 'the pending count is not published early');
  s.page.jobs.length = 0;
  s.page.emitDashboard();
  const pushed = s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('status-') === 0);
  assert.equal(pushed.length, 1, 'the deferred count is published once the stream ends');
  assert.equal(pushed[0].modelRequests, 0, 'and it carries the settled value');

  // A chat phone disappearing cannot be re-dialled from here.
  const t = setup(true);
  t.page.pageReady = true;
  t.page.serviceReady = true;
  t.channel.connectedCount = () => 0;
  t.channel.hasEpoch = () => false;
  t.page.connectionChanged(false, 6);
  const status = t.events.filter(e => e.kind === 'connection').at(-1);
  assert(status.text.includes('等待它自动重连'), 'a lost chat link says who has to re-dial: ' + status.text);
  console.log('PASS: status push defers to inference; a lost chat link is reported as the chat side\'s to re-dial');
}
