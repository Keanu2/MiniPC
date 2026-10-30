// node IndexFocus.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile, transpileSource } = require('../../../../../../../tests/ets-harness.cjs');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function loadEts(file, requires = {}) {
  const box = { exports: {}, Error, Map, Math, Number, Date, Promise, JSON, require: name => requires[name] || {} };
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
    applyRemoteRoster() { return true; },
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
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
    if (name === '../nearby/LinkEnhanceChannel') {
      return { nearbyChannel: channel };
    }
    if (name === '../nearby/NearbyConfig') return { IS_SERVER: !!isServer };
    if (name === '../llm/LocalChat') return { LocalChat: class {} };
    if (name === '../llm/OutputSettings') return {
      outputSettings:()=>({streaming:behavior.streaming!==false}),
      saveOutputSettings:(_dir,settings)=>{if(behavior.outputSaveError)return behavior.outputSaveError;behavior.streaming=settings.streaming;return '';}
    };
    if (name === '../llm/ModelRegistry') return {
      modelSelection: () => behavior.modelSelection || {model:''},
      readyModelDirs: () => ['7B','VL'],
      isVlLayout: path => path.endsWith('/VL'),
      saveModelSelection: (_dir, selection) => { behavior.modelSelection = selection; return ''; }
    };
    if (name === '../llm/LlmTransport') return { LocalLlmTransport: class {
      constructor(chat) { this.chat = chat; }
      start(messages, cb, id) { return this.chat.start(messages, cb, id); }
      cancel(id) { this.chat.cancel(id); }
      readinessError() { return this.chat.readinessError(); }
    } };
    if (name === '../cluster/DeviceSpeed') {
      return loadEts(__dirname + '/../cluster/DeviceSpeed.ets');
    }
    if (name === '../llm/VlLlmTransport') return { VlLlmTransport: class {
      constructor() { this.starts = 0; }
      start(messages, cb, id, image) { this.starts++; return image && image.length > 0 ? '' : 'no image'; }
      cancel() {} readinessError() { return ''; } isBusy() { return false; }
    } };
    if (name === '../llm/QwenVlManager') return { QwenVlManager: { getInstance: () => ({
      init() { behavior.modelInitializations = (behavior.modelInitializations || 0) + 1; }, isModelEnabled: () => false, getDeployedModelName: () => '', readinessError: () => '',
      isBusy: () => false, unloadIfIdle() {}
    }) } };
    if (name === '../cluster/ComputeRouter') {
      return loadEts(__dirname + '/../cluster/ComputeRouter.ets');
    }
    if (name === '../cluster/TaskRules') {
      return loadEts(__dirname + '/../cluster/TaskRules.ets');
    }
    if (name === '../cluster/DeviceLabels') {
      return loadEts(__dirname + '/../cluster/DeviceLabels.ets');
    }
    if (name === '../ui/ChatBridge') return loadEts(__dirname + '/../ui/ChatBridge.ets');
    if (name === '../ui/InferencePresentation') return loadEts(__dirname + '/../ui/InferencePresentation.ets');
    if (name === '../ui/TaskDisplayRelay') return loadEts(__dirname + '/../ui/TaskDisplayRelay.ets');
    if (name === '../ui/InferenceTaskObserver') return loadEts(__dirname + '/../ui/InferenceTaskObserver.ets', {
      './InferencePresentation': loadEts(__dirname + '/../ui/InferencePresentation.ets')
    });
    if (name === '../ui/TaskBoard') return loadEts(__dirname + '/../ui/TaskBoard.ets', {
      '../protocol/ChatProtocol': loadEts(__dirname + '/../protocol/ChatProtocol.ets')
    });
    if (name === '../ui/CollaborationScreen') return loadEts(__dirname + '/../ui/CollaborationScreen.ets');
    if (name === '../cluster/DeviceInfo') return {
      DEVICE_INFO_POLL_MS: 2000,
      applyDeviceInfo(target, message) {
        if (typeof message.name === 'string' && message.name.length > 0) target.name = message.name;
        if (typeof message.memTotal === 'number') target.memTotal = message.memTotal;
        if (typeof message.memAvail === 'number') target.memAvail = message.memAvail;
        if (typeof message.memUsage === 'number') target.memUsage = message.memUsage;
        if (typeof message.thermalLevel === 'number') target.thermalLevel = message.thermalLevel;
        if (typeof message.batteryTemp === 'number') target.batteryTemp = message.batteryTemp;
        if (typeof message.cpuUsage === 'number') target.cpuUsage = message.cpuUsage;
        if (typeof message.model === 'string') target.model = message.model;
        if (typeof message.modelRequests === 'number') target.modelRequests = message.modelRequests;
        if (typeof message.modelTier === 'number') target.modelTier = message.modelTier;
      },
      buildSelfEntry(_dir, running) {
        return { name: '本机', id: 'self', role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
          modelRequests: running, memUsage: 10, memAvail: 1000, memTotal: 2000,
          thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, capabilities: ['text', 'vision'] };
      },
      deployedModelName: () => 'Qwen2.5-7B-Instruct-Q4_N_0',
      formatComputeStatus: () => 'Qwen',
      toDeviceInfoReply: (id, entry) => ({
        type: 'deviceInfo', requestId: id, name: entry.name, model: entry.model,
        memUsage: entry.memUsage, thermalLevel: entry.thermalLevel, batteryTemp: entry.batteryTemp,
        cpuUsage: entry.cpuUsage, modelRequests: entry.modelRequests, peerRole: 'compute'
      })
    };
    if (name === '../llm/UsageLedger') return loadEts(__dirname + '/../llm/UsageLedger.ets', {
      '@kit.CoreFileKit': { fileIo: {
        OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
        readTextSync() { throw new Error('missing'); },
        openSync() { return { fd: 1 }; }, writeSync() {}, closeSync() {}, renameSync() {}
      } }
    });
    if (name === '../media/ImageAttach') return {
      pickJpegDataUrl: async () => '',
      jpegBase64Payload: d => d.indexOf('data:image/jpeg;base64,') === 0 ? d.slice('data:image/jpeg;base64,'.length) : d
    };
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
    'stats', 'devices', 'pick', 'preview', 'previewImg', 'previewClear', 'clearTasks', 'title'].map(id => [id, makeElement()]));
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
      { role: 'self', name: '算力设备2', ready: true, jobs: 2, memUsage: 41,
        thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, model: 'Qwen2.5-7B-Instruct' },
      { role: 'chat', name: '聊天设备1', ready: true, jobs: 1 }
    ]
  });
  assert.equal(elements.title.textContent, '算力设备2');
  assert(elements.devices.innerHTML.includes('算力设备2'));
  const localAt = elements.devices.innerHTML.indexOf('class="tag local">本机');
  const statusAt = elements.devices.innerHTML.indexOf('>推理中<');
  assert(localAt > elements.devices.innerHTML.indexOf('算力设备2') && statusAt > localAt,
    '本机 is a chip between the device name and the status');
  assert.equal(elements.devices.innerHTML.split('tag local').length - 1, 1, 'only this device is marked 本机');
  assert(elements.devices.innerHTML.includes('推理 2'), 'compute card shows running job count');
  window.onNativeEvent({
    kind: 'dashboard', running: 1, jobs: [], selfLabel: '算力设备1',
    devices: [
      { role: 'self', name: '算力设备1', ready: true, jobs: 1, memUsage: 41,
        thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, modelRequests: 2, model: 'Qwen2.5-7B-Instruct' }
    ]
  });
  assert(elements.devices.innerHTML.includes('推理 1'), 'card uses jobs, not sampled+inflight');
  assert(!elements.devices.innerHTML.includes('推理 2'), 'inflated modelRequests must not double the badge');
  assert(elements.devices.innerHTML.includes('内存'), 'compute card still shows memory');
  assert(elements.devices.innerHTML.includes('42℃ · 温热'), 'compute card shows battery temp and thermal gear');
  assert(elements.devices.innerHTML.includes('class="heat"'), 'heat sits on the model row');
  assert(elements.devices.innerHTML.includes('class="bar cpu"'), 'CPU uses the same meter as memory');
  assert(elements.devices.innerHTML.includes('width:18%'), 'CPU meter fills to occupancy');
  // The channel badge carries the routed tier AND model, and its color follows the side.
  window.onNativeEvent({
    kind: 'dashboard', running: 1, jobs: [], selfLabel: '算力设备1',
    devices: [{ role: 'self', name: '算力设备1', ready: true, jobs: 0, memUsage: 40,
      model: 'Qwen2.5-7B-Instruct', backend: '分档·COMPLEX·云侧GLM-5.3' }]
  });
  assert(elements.devices.innerHTML.includes('分档·COMPLEX·云侧GLM-5.3'), 'channel badge carries the routed tier and model');
  assert(elements.devices.innerHTML.includes('class="side cloud"'), 'cloud-routed badge takes the cloud color');
  assert(elements.stats.innerHTML.includes('分档·COMPLEX·云侧GLM-5.3'), 'stats line mirrors the routed model');
  window.onNativeEvent({
    kind: 'dashboard', running: 0, jobs: [], selfLabel: '算力设备1',
    devices: [{ role: 'self', name: '算力设备1', ready: true, jobs: 0, memUsage: 40,
      model: 'Qwen2.5-7B-Instruct', backend: '分档·SIMPLE·端侧Qwen2.5-7B' }]
  });
  assert(elements.devices.innerHTML.includes('class="side edge"'), 'edge-routed badge takes the edge color');
  window.onNativeEvent({ kind: 'dashboard', running: 1, selfLabel: '算力设备1', devices: [], jobs: [{
    id: 'time-1', key: '0:time-1', source: '算力设备1', origin: '聊天设备1', question: '时间测试', answer: '',
    chars: 0, startedAt: new Date(2026, 8, 21, 10, 30, 45).getTime(), firstAt: 0, endedAt: 0,
    running: true, error: false, elapsedMs: 1200
  }] });
  assert(elements.history.innerHTML.includes('创建 09-21 10:30:45'), 'task card shows its creation time');
  // A streaming reply patches its own card immediately, instead of waiting up to five
  // seconds for the next dashboard poll.
  window.onNativeEvent({ kind: 'text', requestId: 'time-1', text: '流式第一段' });
  assert(!elements.history.innerHTML.includes('流式第一段'), 'model output stays in details rather than the task list');
  window.onNativeEvent({ kind: 'done', requestId: 'time-1', text: '流式完成', error: false });
  assert(!elements.history.innerHTML.includes('流式完成'), 'final output stays in details');
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
    hasPendingNativeJobs() { return false; }, activeCount() { return callbacks.size; },
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
    hasPendingNativeJobs() { return false; }, activeCount() { return 0; }
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
  assert.equal(board.devices.find(device => device.role === 'self').batteryTemp, 42);
  assert.equal(board.devices.find(device => device.role === 'self').cpuUsage, 18);
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
  s.page.receive({ type: 'deviceInfo', requestId: 'info-7', model: 'Qwen', memUsage: 41,
    thermalLevel: 3, batteryTemp: 45.5, cpuUsage: 67, modelRequests: 1, memAvail: 7000 }, 7);
  assert.equal(s.page.peerStats.get(7).memUsage, 41);
  assert.equal(s.page.peerStats.get(7).thermalLevel, 3);
  assert.equal(s.page.peerStats.get(7).batteryTemp, 45.5);
  assert.equal(s.page.peerStats.get(7).cpuUsage, 67);
  s.page.emitDashboard();
  const loadBoard = s.events.filter(event => event.kind === 'dashboard').at(-1);
  assert.equal(loadBoard.devices.find(device => device.role === 'compute').thermalLevel, 3);
  assert.equal(loadBoard.devices.find(device => device.role === 'compute').cpuUsage, 67);
  s.page.receive({ type: 'deviceInfo', requestId: 'q1' }, 1);
  assert.equal(s.sent.at(-1).type, 'deviceInfo');
  assert.equal(s.sent.at(-1).model, 'Qwen2.5-7B-Instruct-Q4_N_0');
  console.log('PASS: schedule to idle compute, sched stays local, worker reply remapped, deviceInfo poll/reply');
}

{
  const follower = setup(true);
  follower.channel.selfComputeNumber = () => 2;
  follower.page.model = { start() { throw new Error('a follower must not coordinate'); }, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  follower.page.receive({ type: 'request', requestId: 'not-hub',
    messages: [{ role: 'user', content: 'A' }] }, 1);
  assert.equal(follower.sent.at(-1).type, 'error');
  assert(follower.sent.at(-1).error.includes('算力设备1'));
  assert.equal(follower.page.jobs.length, 0);
}

{
  const worker = setup(true);
  worker.page.pageReady = true;
  worker.page.model = { start() { return ''; }, readinessError() { return ''; }, cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 1; } };
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
  ghost.channel.selfComputeNumber = () => 2;
  ghost.channel.peerInfos = () => [{ epoch: 7, peerId: 'compute-2', ready: true, role: 'compute',
    name: '算力设备1', helloName: '算力设备1', deviceUid: 'compute-2', slot: 1 }];
  ghost.channel.hasEpoch = epoch => epoch === 7;
  ghost.page.remoteSeen.set(7, [{ id: 'chat-live', name: '聊天A', role: 'chat' }]);
  ghost.page.remoteSeen.set(8, [{ id: 'chat-gone', name: '聊天B', role: 'chat' }]);
  ghost.page.cancelDroppedPeers();
  assert.equal(Array.from(ghost.behavior.remoteChats).join(','), '聊天A',
    'a disconnected reporter cannot keep a chat online');
  ghost.page.pollDeviceInfo();
  assert.equal(ghost.sent.filter(message => message.type === 'deviceInfoSync').length, 0,
    'a worker must not publish its incomplete star view as a global roster');
  assert.equal(ghost.page.remoteEntries().length, 1, 'a worker sees its live hub roster');
  ghost.channel.selfComputeNumber = () => 1;
  assert.equal(ghost.page.remoteEntries().length, 0,
    'promotion immediately hides old indirect chats before the next roster arrives');
  ghost.page.handleClusterSync({ devices: [{ id: 'old-chat', role: 'chat', name: '聊天设备1' }] }, 7);
  assert.equal(ghost.page.remoteSeen.has(7), false, 'a hub cannot import another reporter chat slot');

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
    'a two-second status poll does not resend an unchanged full roster');
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
  assert.equal(quiet.sent.length, 1, 'busy polling publishes only a small load status');
  assert.equal(quiet.sent[0].modelRequests, 1);assert.equal(quiet.sent[0].type, 'deviceInfo');
  assert.equal(quiet.sent[0].memUsage, undefined);

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

(async () => {
  const s = setup(true);
  s.page.serviceReady = true;
  s.page.emitDashboard = () => {};
  let peers = [{ epoch: 2, peerId: 'worker', deviceUid: 'worker', ready: true, role: 'compute', slot: 2 }];
  s.channel.peerInfos = () => peers;
  s.channel.hasEpoch = epoch => peers.some(p => p.epoch === epoch);
  const deliveries = [];
  s.channel.send = (message, epoch) => {
    if (message.type !== 'deviceInfoSync') return Promise.resolve(true);
    const gate = deferred(); deliveries.push({ message, epoch, gate }); return gate.promise;
  };
  s.page.jobs.push({ id: 'busy', workerEpoch: 0 });
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 1, 'new worker gets membership even during inference');
  assert(deliveries[0].message.devices.every(d => d.memAvail === undefined && d.name === undefined),
    'busy control snapshots omit telemetry and duplicated names');
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 1, 'unchanged pending snapshot is not flooded');
  deliveries[0].gate.resolve(false); await flush();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 2, 'failed delivery retries on the next poll, not after 30 seconds');
  peers = [...peers, { epoch: 3, peerId: 'third', deviceUid: 'third', ready: true, role: 'compute', slot: 3 }];
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 4, 'topology change reaches both existing and new workers');
  assert.equal(deliveries.at(-1).message.devices.map(d => d.slot).join(','), '1,2,3');
  deliveries[2].gate.resolve(true); deliveries[3].gate.resolve(true); await flush();
  deliveries[1].gate.resolve(false); await flush();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 4, 'old completion cannot invalidate the newest snapshot');
  peers = peers.map(p => p.epoch === 3 ? { ...p, epoch: 30 } : p);
  s.page.cancelDroppedPeers();
  s.page.pollDeviceInfo();
  assert.equal(deliveries.length, 5, 'same UID reconnecting on a new session must receive unchanged roster');
  assert.equal(deliveries.at(-1).epoch, 30);
  assert.equal(s.page.rosterDeliveries.has(3), false, 'dead session delivery state is removed');
  s.channel.selfComputeNumber = () => 3;
  peers = [{ epoch: 1, peerId: 'hub', ready: true, role: 'compute', slot: 1 }];
  const accepted = [{ id: 'known', role: 'compute', slot: 2 }];
  s.page.remoteSeen.set(1, accepted);
  s.channel.applyRemoteRoster = () => false;
  s.page.handleClusterSync({ devices: [{ id: 'forged', role: 'compute', slot: 2 }] }, 1);
  assert.equal(s.page.remoteSeen.get(1), accepted, 'rejected membership cannot pollute the dashboard cache');
  console.log('PASS: busy multi-node membership, per-session retry and stale completion isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Lightweight load changes remain visible during inference, and a chat link dropping is
// reported rather than left as a silent gap the compute side cannot repair itself.
{
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  s.channel.peerInfos = () => [
    { epoch: 2, peerId: 'worker', deviceUid: 'worker', ready: true, role: 'compute', name: '算力设备2', slot: 2 },
    { epoch: 1, peerId: 'chat', deviceUid: 'chat', ready: true, role: 'chat', name: '聊天设备1', slot: 1 }
  ];
  // A chat request lands while the hub has a local job: publish the count now.
  s.page.jobs.push({ id: 'busy', key: '0:busy', epoch: 0, peer: false, workerEpoch: 0,
    answer: '', question: 'q', startedAt: 0, firstAt: 0, endedAt: 0, error: false, source: '', origin: '本机', image: '' });
  s.page.lastPublishedRunning = 0;
  s.sent.length = 0;
  s.page.emitDashboard();
  assert.equal(s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('load-') === 0).length, 1);
  assert.equal(s.sent[0].modelRequests, 1);assert.equal(s.sent[0].memUsage, undefined);
  assert.equal(s.page.lastPublishedRunning, 1);
  s.page.jobs.length = 0;
  s.page.emitDashboard();
  const pushed = s.sent.filter(m => m.type === 'deviceInfo' && String(m.requestId).indexOf('load-') === 0);
  assert.equal(pushed.length, 2, 'start and completion both publish load changes');
  assert.equal(pushed[1].modelRequests, 0);

  // A chat phone disappearing cannot be re-dialled from here.
  const t = setup(true);
  t.page.pageReady = true;
  t.page.serviceReady = true;
  t.channel.connectedCount = () => 0;
  t.channel.hasEpoch = () => false;
  t.page.connectionChanged(false, 6);
  const status = t.events.filter(e => e.kind === 'connection').at(-1);
  assert(status.text.includes('等待它自动重连'), 'a lost chat link says who has to re-dial: ' + status.text);
  console.log('PASS: small start/stop load pushes during inference; a lost chat link is reported as the chat side\'s to re-dial');
}

{
  const hub=setup(true),worker=setup(true);
  hub.page.serviceReady=true;worker.page.serviceReady=true;worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'worker',deviceUid:'worker',ready:true,role:'compute',name:'算力设备2',slot:2}];
  worker.channel.peerInfos=()=>[{epoch:1,peerId:'hub',deviceUid:'hub',ready:true,role:'compute',name:'算力设备1',slot:1}];
  hub.page.showRelayTask('r',5,7,[{role:'user',content:'问题'}],'普通聊天');
  worker.page.showInferTask('forward',1,'问题','普通聊天');
  const busy=worker.sent.filter(m=>m.modelRequests===1).at(-1);assert(busy);
  hub.page.handleDeviceInfo(busy,7);
  const hd=hub.events.filter(e=>e.kind==='dashboard').at(-1),wd=worker.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(hd.running,0,'hub forwarding work is not local inference');
  assert.equal(hd.devices.find(d=>d.role==='self').jobs,0);assert.equal(hd.devices.find(d=>d.epoch===7).jobs,1);
  assert.equal(wd.running,1);assert.equal(wd.devices.find(d=>d.role==='self').jobs,1);
  worker.page.finishInferTask('forward',1,'答案',false);hub.page.completeJob('r',5,'答案',false);
  const stopped=worker.sent.filter(m=>m.requestId?.startsWith('load-')&&m.modelRequests===0).at(-1);assert(stopped);
  hub.page.handleDeviceInfo(stopped,7);
  assert.equal(hub.events.filter(e=>e.kind==='dashboard').at(-1).devices.find(d=>d.epoch===7).jobs,0);
  const before=hub.sent.length;hub.page.handleDeviceInfo({type:'deviceInfo',requestId:'count-only',modelRequests:0},7);
  assert.equal(hub.sent.length,before,'a count-only response must not trigger a response loop');
  console.log('PASS: actual hub/worker dashboard counts and load-only responses remain correct through a forwarded request');
}

// A split answered by the worker lets the hub observe a provisional parent before the chat's
// snapshot arrives. Publishing it locked the worker onto that parent: every later revision
// carried the chat's startedAt and was rejected, leaving 待分配/待执行 forever.
(async()=>{
  const tick=()=>new Promise(r=>setTimeout(r,5));
  const hub=setup(true), worker=setup(true), sent=[];
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'chat1',role:'chat',ready:true,name:'聊天设备1'},{epoch:8,peerId:'worker2',role:'compute',ready:true,name:'算力设备2'}];
  worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:11,peerId:'hub1',role:'compute',ready:true,name:'算力设备1'}];
  hub.channel.send=async(message,epoch)=>{if(message.type==='infer.task'&&epoch===8){sent.push(message.task.revision);
    worker.page.receiveInference(JSON.parse(JSON.stringify(message)),11);}return true;};
  worker.page.inference={isActive(){return false;},handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.messages.at(-1).content,message.label||'')}};
  const question='查一下明天深圳到北京的高铁票，再查一下北京天气';
  let n=0;
  const forward=(sub,label,content)=>{const id='r'+(++n),messages=[{role:'user',content}];
    hub.page.taskLinks.set(hub.page.constructor.jobKey(7,id),{taskId:'T1',subtaskId:sub,origin:'聊天设备1',input:'[user]\n'+content});
    const message={type:'infer.request',version:2,requestId:'fw_'+id,messages,label,taskId:'T1',subtaskId:sub,origin:'聊天设备1'};
    hub.page.showRelayTask(id,7,8,messages,label);hub.page.forwardTaskDisplay(id,7,8,message);worker.page.receiveInference(message,11);
    return (answer)=>{worker.page.finishInferTask(message.requestId,11,answer,false);hub.page.completeJob(id,7,answer,false);};};
  const kids=(a,b)=>[{id:'s1',title:'高铁票',device:a[1],phase:a[0],detail:''},{id:'s2',title:'北京天气',device:b[1],phase:b[0],detail:''}];
  let revision=0;
  const snap=(phase,a,b,extra={})=>hub.page.receiveInference({type:'infer.task',requestId:'T1',task:{id:'T1',title:question,phase,
    revision:++revision,startedAt:1000,endedAt:0,answer:'',subtasks:kids(a,b),...extra}},7);
  forward('plan','任务拆分','## User request\n'+question)('[{"title":"高铁票","task":"查询明天深圳到北京的高铁票"},{"title":"北京天气","task":"查询北京天气"}]');
  await tick();
  assert.equal(hub.page.taskViews().length,1,'the hub still shows its provisional parent locally');
  assert.deepEqual(sent,[],'a provisional parent is never published to workers');
  snap('running',['queued',''],['queued',''],{});await tick();
  const child=forward('s1','子任务 1/2','User task:\n查询明天深圳到北京的高铁票');await tick();
  snap('running',['running','算力设备2'],['running','算力设备1']);await tick();
  child('Final: G302');await tick();
  snap('done',['done','算力设备2'],['done','算力设备1'],{endedAt:5000,answer:'汇总'});await tick();
  const shown=worker.page.taskBoard.views();
  assert.equal(shown.length,1);
  assert.equal(shown[0].phase,'done','the worker follows the chat snapshot to its final state: '+sent.join(','));
  assert.equal(shown[0].subtasks[0].device,'算力设备2');
  console.log('PASS: worker-run split -> provisional hub parent stays local -> worker follows chat snapshots to done');
})();

// Native display integration: parent ownership is distinct from actual child worker.
{
  const s=setup(true);
  s.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:8,peerId:'compute2',role:'compute',ready:true,name:'算力设备2'}];
  const task={id:'display_parent',title:'原始任务',phase:'running',revision:1,startedAt:1000,endedAt:0,answer:'',subtasks:[
    {id:'s1',title:'本机子任务',device:'算力设备1',phase:'running',detail:'生成中'},
    {id:'s2',title:'远端子任务',device:'算力设备2',phase:'running',detail:'生成中'}]};
  s.page.receiveInference({type:'infer.task',requestId:task.id,task},7);
  let board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups[0].executor,'算力设备1');assert.equal(board.groups[0].origin,'聊天设备2');
  s.page.receiveInference({type:'infer.task',requestId:task.id,task:{...task,revision:2,title:'不可信的算力端主任务'}},8);
  assert.equal(s.page.taskBoard.views()[0].title,'原始任务','compute peer cannot impersonate chat owner');
  s.page.inference={isActive(){return false;},handle(message,epoch){s.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  s.page.receiveInference({type:'infer.request',requestId:'child-call',prompt:'子任务输入',taskId:task.id,subtaskId:'s1'},7);
  board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.jobs[0].groupKey,'7:display_parent');assert.equal(board.jobs[0].subtaskId,'s1');assert.equal(board.jobs[0].origin,'聊天设备2');
  s.page.finishInferTask('child-call',7,'Action: search',false);
  s.page.clearFinishedJobs();assert.equal(s.page.taskBoard.views().length,1,'clearing history preserves running parent');
  assert(s.page.finishedJobs.some(job=>job.id==='child-call'),'an active task keeps its returned model calls after history cleanup');
  s.page.taskBoard.disconnect(7);s.page.clearFinishedJobs();assert.equal(s.page.taskBoard.views().length,0);
  const worker=setup(true);worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=>'算力设备2';worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:8,peerId:'hub',role:'compute',ready:true,name:'算力设备1'}];
  worker.page.inference={isActive(){return false;},handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  worker.page.receiveInference({type:'infer.request',requestId:'forwarded',prompt:'远端输入',taskId:task.id,subtaskId:'s2',origin:'聊天设备2'},8);
  assert.equal(worker.page.jobs[0].origin,'聊天设备2');assert.equal(worker.page.jobs[0].source,'算力设备2');
  console.log('PASS: native group ownership, chat role checks, request correlation, history cleanup and forwarded origin');
}

{
  const s=setup(true);s.page.filesDir='/files';
  s.page.jobs.push(s.page.createJob('active',[{role:'user',content:'active'}],false,0));
  assert.equal(s.page.setOutputMode('complete'),'','a future-request preference is editable while inference runs');
  assert.equal(s.page.modelSettings().streaming,false);
  assert.ok(s.page.setOutputMode('invalid'));assert.equal(s.behavior.streaming,false);
  s.behavior.outputSaveError='save failed';assert.equal(s.page.setOutputMode('stream'),'save failed');
  assert.equal(s.page.modelSettings().streaming,false);
  s.behavior.outputSaveError='';assert.equal(s.page.setOutputMode('stream'),'');
  assert.equal(s.page.modelSettings().streaming,true);
  assert.equal(s.page.saveUsageSettings('{"tasks":"4","tokens":"10","yuan":"1.5","priceMode":"custom","inputYuan":"2","outputYuan":"8"}'),'');
  let usageBoard=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(usageBoard.usage.tasks,4);
  assert.equal(usageBoard.usage.tokens,10);
  assert.equal(usageBoard.usage.microYuan,1500000);
  assert.equal(s.page.saveUsageSettings('{"reset":true}'),'');
  assert.equal(s.page.usage.completedTasks,0);
  assert.equal(s.page.usage.priceMode,'custom');
  assert.ok(s.page.saveUsageSettings('nope'));
  console.log('PASS: output setting validates, persists and changes independently of active inference');
}

// Model changes must not race active native requests or cleanup.
{
  const s = setup(true);
  let pending = true, resets = 0;
  s.page.filesDir = '/files';
  s.page.model = { hasPendingNativeJobs() { return pending; }, activeCount() { return 0; },
    resetIdleSessions() { resets++; } };
  assert(s.page.selectModel('VL').includes('结束后再切换'));
  assert.equal(s.behavior.modelSelection, undefined, 'native cleanup blocks changing persisted selection');
  pending = false;
  s.page.inference = { isActive() { return true; } };
  assert(s.page.selectModel('VL').includes('结束后再切换'));
  s.page.inference = null;
  s.channel.peerInfos = () => [{epoch:7,peerId:'chat',name:'聊天设备1',ready:true,role:'chat'},
    {epoch:8,peerId:'compute',name:'算力设备2',ready:true,role:'compute'}];
  assert.equal(s.page.selectModel('VL'), '');
  assert.equal(s.behavior.modelSelection.model, 'VL');
  assert.equal(resets, 1, 'idle cached text sessions are released before switching');
  assert.equal(s.behavior.modelInitializations, 1, 'the VL manager rescans the active selection');
  assert.equal(s.sent.filter(message => message.type === 'deviceInfo').length, 2,
    'both chat and compute peers receive the updated model advertisement immediately');
  assert.equal(s.events.at(-1).modelSettings.selected, 'VL');
  s.page.model.readinessError = () => '没有启用文字模型';
  s.page.vlTransport = { readinessError() { return ''; } };
  s.page.receive({type:'prepare',requestId:'vl-prepare'}, 7);
  assert.equal(s.sent.find(message => message.requestId === 'vl-prepare' && message.type === 'prepared').error,
    undefined, 'a selected image-only model can still complete connection preparation');
  console.log('PASS: model switching waits for native cleanup and active requests, then refreshes engine and peer telemetry');
}

// Replay a purpose-labelled split using an unchanged chat client (no infer.task messages).
{
  const s=setup(true);
  s.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:8,peerId:'compute2',role:'compute',ready:true,name:'算力设备2'}];
  s.page.inference={isActive(){return false;},handle(message,epoch){s.page.showInferTask(message.requestId,epoch,message.prompt||message.messages.at(-1).content,message.label||'')}};
  const request=(id,prompt,label)=>s.page.receiveInference({type:'infer.request',requestId:id,prompt,label},7);
  request('plan','拆分提示词\n用户请求：\n比较两个模型','任务拆分');
  assert.equal(s.events.filter(e=>e.kind==='dashboard').at(-1).groups.length,0);
  s.page.finishInferTask('plan',7,JSON.stringify([{title:'模型A',task:'介绍模型A'},{title:'模型B',task:'介绍模型B'}]),false);
  request('a','PRIVATE_PROMPT\nUser task:\n介绍模型A\nControl: PRIVATE_CONTROL','子任务 1/2');
  s.page.showRelayTask('b',7,8,[{role:'user',content:'User task:\n介绍模型B\nControl: private'}],'子任务 2/2');
  let board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups.length,1);assert.equal(board.groups[0].executor,'算力设备1');
  assert.equal(board.groups[0].subtasks[1].device,'算力设备2');
  assert(!board.jobs.find(j=>j.id==='a').question.includes('PRIVATE_'));assert(board.jobs.find(j=>j.id==='a').input.includes('PRIVATE_CONTROL'));
  const html=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
  const elements={};const element=()=>({handlers:{},value:'',style:{},textContent:'',innerHTML:'',scrollTop:50,classList:{add(){},remove(){}},addEventListener(t,f){this.handlers[t]=f},setAttribute(){}});
  for(const match of html.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
  const document={getElementById:id=>elements[id],createElement:element,addEventListener(){},activeElement:null};
  const window={chatBridge:{prepare(){},connect(){},pickImage(){},clear(){}}};
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date});
  window.onNativeEvent(board);
  assert(elements.history.innerHTML.includes('比较两个模型'));assert(elements.history.innerHTML.includes('模型A'));assert(elements.history.innerHTML.includes('模型B'));assert(elements.history.innerHTML.includes('算力设备2'));
  assert(!elements.history.innerHTML.includes('PRIVATE_'));
  s.page.finishInferTask('a',7,'A推理返回',false);s.page.completeJob('b',7,'B推理返回',false);
  request('merge','用户请求：\n比较两个模型\n\n【子任务1：模型A｜已完成】\nA返回结果\n\n【子任务2：模型B｜已完成】\nB返回结果','合并结果');
  s.page.finishInferTask('merge',7,'汇总回答',false);
  board=s.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups[0].phase,'done');assert.equal(board.groups[0].answer,'汇总回答');
  window.onNativeEvent(board);assert(elements.history.innerHTML.includes('模型B'));assert(elements.history.innerHTML.includes('汇总回答'));
  s.page.clearFinishedJobs();assert.equal(s.events.filter(e=>e.kind==='dashboard').at(-1).groups.length,0);
  console.log('PASS: unchanged chat request replay -> native split observation -> real HTML grouping and result return, full input isolated from list');
}

// The screenshot on compute 2 exposed this gap: legacy calls had neither a
// parent snapshot nor stable child identity after being handed to the worker.
{
  const hub=setup(true), worker=setup(true), forwarded=[];
  hub.channel.peerInfos=()=>[{epoch:7,peerId:'chat2',role:'chat',ready:true,name:'聊天设备2'},{epoch:9,peerId:'chat3',role:'chat',ready:true,name:'聊天设备3'},
    {epoch:8,peerId:'worker2',role:'compute',ready:true,name:'算力设备2'}];
  worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=> '算力设备2';
  worker.channel.peerInfos=()=>[{epoch:11,peerId:'hub1',role:'compute',ready:true,name:'算力设备1'},
    {epoch:12,peerId:'worker3',role:'compute',ready:true,name:'算力设备3'}];
  hub.channel.send=async(message,epoch)=>{forwarded.push(JSON.parse(JSON.stringify(message)));
    if(epoch===8&&message.type==='infer.task')worker.page.receiveInference(JSON.parse(JSON.stringify(message)),11);return true;};
  worker.page.inference={isActive(){return false;},handle(message,epoch){worker.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  hub.page.inference={isActive(){return false;},handle(message,epoch){hub.page.showInferTask(message.requestId,epoch,message.prompt,message.label||'')}};
  hub.page.receiveInference({type:'infer.request',requestId:'legacy-plan',prompt:'用户请求：\n分别查询车票和天气',label:'任务拆分'},7);
  hub.page.finishInferTask('legacy-plan',7,JSON.stringify([{title:'车票查询',task:'查询深圳到北京的车票'},
    {title:'天气查询',task:'查询北京天气'}]),false);
  const invoke=(id)=>{
    hub.page.showRelayTask(id,7,8,[{role:'user',content:'User task:\n查询北京天气\nControl: PRIVATE_CONTROLLER'}],'子任务 2/2');
    const message={type:'infer.request',requestId:'forward_'+id,prompt:'User task:\n查询北京天气\nControl: PRIVATE_CONTROLLER',label:'子任务 2/2',origin:'聊天设备2'};
    hub.page.forwardTaskDisplay(id,7,8,message);
    worker.page.receiveInference(message,11);
    return message;
  };
  const first=invoke('weather1');
  worker.page.finishInferTask(first.requestId,11,'Action: search',false);hub.page.completeJob('weather1',7,'Action: search',false);
  const second=invoke('weather2');
  assert.equal(first.taskId,second.taskId,'legacy rounds receive the same worker parent identity');
  assert.equal(first.subtaskId,'s2');assert.equal(second.subtaskId,'s2');
  const board=worker.events.filter(e=>e.kind==='dashboard').at(-1);
  assert.equal(board.groups.length,1);assert.equal(board.groups[0].executor,'算力设备1');
  assert.equal(board.groups[0].origin,'聊天设备2');assert.equal(board.jobs.length,2);
  assert(board.jobs.every(j=>j.groupKey===board.groups[0].key));
  const html=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
  const elements={};const element=()=>({handlers:{},value:'',style:{},textContent:'',innerHTML:'',scrollTop:50,classList:{add(){},remove(){}},addEventListener(t,f){this.handlers[t]=f},setAttribute(){}});
  for(const match of html.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
  const document={getElementById:id=>elements[id],createElement:element,addEventListener(){},activeElement:null};
  const window={chatBridge:{prepare(){},connect(){},pickImage(){},clear(){}}};
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date});
  window.onNativeEvent(board);
  assert(elements.history.innerHTML.includes('分别查询车票和天气'));
  assert(elements.history.innerHTML.includes('class="task-children"'));
  assert.equal((elements.history.innerHTML.match(/data-result="s2"/g)||[]).length,1);
  assert(!elements.history.innerHTML.includes('车票查询'),'a worker only lists its own child assignments');
  assert(!elements.history.innerHTML.includes('data-detail="'),'individual calls do not become duplicate task rows');
  assert(!elements.history.innerHTML.includes('PRIVATE_CONTROLLER'));
  assert(elements.history.innerHTML.includes('推理详情'));
  const untrusted={type:'infer.task',requestId:'fake',task:{...board.groups[0],id:'fake',title:'其他算力伪装的结构'},origin:'聊天设备4'};
  worker.page.receiveInference(untrusted,12);assert.equal(worker.page.taskBoard.views().length,1);
  console.log('PASS: unchanged chat -> hub split -> worker snapshots and stable child IDs -> real worker HTML hierarchy, own assignments only');
}

// 带图请求在算力端必须分流到 VL 引擎，而不是纯文本 GEWU 通道。
{
  const s = setup(true);
  s.page.pageReady = true;
  s.page.serviceReady = true;
  let vlStarts = 0, gewuStarts = 0, lastVlImage = null;
  s.page.vlTransport = { start(messages, cb, id, image) { vlStarts++; lastVlImage = image; return ''; }, cancel() {} };
  s.page.transport = { start() { gewuStarts++; return ''; }, cancel() {}, readinessError() { return ''; } };
  const err = s.page.startModel('0:local', [{ role: 'user', content: '这张图里有什么' }], 'QUJD');
  assert.equal(err, '', 'VL enabled hub accepts the local image request');
  assert.equal(vlStarts, 1, '带图请求走 VL 引擎而非 GEWU');
  assert.equal(gewuStarts, 0, '纯文本通道绝不该收到带图请求');
  assert.equal(lastVlImage, 'QUJD', 'VL 通道收到的是裸 base64（管线内格式）');

  // 无图时仍走普通文本通道。
  s.page.vlTransport = { start() { vlStarts++; return ''; }, cancel() {} };
  const textErr = s.page.startModel('0:text', [{ role: 'user', content: 'hi' }], '');
  assert.equal(textErr, '', 'plain text still goes through the GEWU transport');
  assert.equal(vlStarts, 1, '纯文本绝不触发 VL 引擎');
  assert.equal(gewuStarts, 1, '纯文本走 GEWU transport');
  console.log('PASS: image requests route to the VL engine, text stays on GEWU');
}

// Hub 自身发图：本机能力不足时走集群调度，具备 vision 能力时本机直答 VL。
{
  const hub = setup(true);
  hub.page.pageReady = true;
  hub.page.serviceReady = true;
  hub.page.pendingImage = 'data:image/jpeg;base64,QUJD';
  hub.page.vlTransport = { start(messages, cb, id, image) { hub.vlImage = image; return ''; }, cancel() {} };
  hub.page.model = { hasPendingNativeJobs() { return false; }, activeCount() { return 0; }, cancel() {}, readinessError() { return ''; } };
  hub.channel.peerInfos = () => [];
  // selfMeetsNeeds(['vision'])：mock buildSelfEntry 已声明 capabilities=['text','vision']。
  const err = hub.page.send('看图说话');
  assert.equal(err, '', 'hub with local vision answers directly');
  assert.equal(hub.vlImage, 'QUJD', 'hub sends the bare base64 to the local VL engine');

  // 本机无 vision 能力 → 集群无合格节点 → fail closed 提示。
  const weak = setup(true);
  weak.page.pageReady = true;
  weak.page.serviceReady = true;
  weak.page.pendingImage = 'data:image/jpeg;base64,QUJD';
  weak.page.vlTransport = null;
  // 覆盖本机能力声明：纯文本模型（只具备 text），模拟"带图但本机是纯文本"。
  weak.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0', capabilities: ['text'],
    modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  weak.channel.peerInfos = () => [];
  const weakErr = weak.page.send('看图说话');
  assert(weakErr.includes('没有支持'), 'no vision node anywhere fails closed: ' + weakErr);
  console.log('PASS: hub image send routes by self capability, fail-closed without vision nodes');
}

// G5 档位扩展：Hub 自身请求在（仅 auto）任务档位高于本机、且调度器真会选别的
// 节点时交给调度；轻任务仍本机直答。分类器是真实 TaskRules（与 hub 生产路径同一份）。
{
  const hub = setup(true);
  hub.page.pageReady = true;
  hub.page.serviceReady = true;
  let localStarts = 0;
  hub.page.model = { start() { localStarts++; return ''; }, readinessError() { return ''; },
    cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  hub.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
    capabilities: ['text'], modelTier: 1, modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  hub.channel.peerInfos = () => [{ epoch: 7, peerId: 'w', ready: true, role: 'compute', name: '算力设备2' }];
  hub.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 0, memAvail: 8000, modelTier: 2 });
  // 代码围栏 → 复杂档 2 > 本机档 1，调度器选强档对端 → 任务卡转发。
  assert.equal(hub.page.send('```python\nprint(1)\n```'), '');
  assert.equal(hub.sent.at(-1).type, 'request');
  assert.equal(hub.sent.at(-1).sched, true);
  assert.equal(hub.page.jobs[0].workerEpoch, 7, 'complex question goes to the strong peer');
  assert.equal(hub.page.jobs[0].taskTier, 2);
  const board = hub.events.filter(e => e.kind === 'dashboard').at(-1);
  assert.equal(board.devices.find(d => d.role === 'compute').modelTier, 2, 'peer card carries its tier');
  assert.equal(board.devices.find(d => d.role === 'self').modelTier, 1, 'self card carries its tier');
  // "你好" → 简单档 1 ≤ 本机档 1 → 聊天轨道本机直答。
  hub.sent.length = 0;
  assert.equal(hub.page.send('你好'), '');
  assert.equal(localStarts, 1, 'a light question answers on the local rail');
  assert.equal(hub.sent.filter(m => m.type === 'request').length, 0, 'nothing is forwarded for a light question');
  assert.equal(hub.page.jobs.at(-1).workerEpoch, 0);
  assert.equal(hub.page.jobs.at(-1).taskTier, 1);
  console.log('PASS: G5 tier scheduling forwards heavy questions, keeps light ones local');
}

// 强对端忙 → 负载不平手，空闲本机胜出 → 仍聊天轨道直答（降档而非排队）。
{
  const hub = setup(true);
  hub.page.pageReady = true;
  hub.page.serviceReady = true;
  let localStarts = 0;
  hub.page.model = { start() { localStarts++; return ''; }, readinessError() { return ''; },
    cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  hub.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
    capabilities: ['text'], modelTier: 1, modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  hub.channel.peerInfos = () => [{ epoch: 7, peerId: 'w', ready: true, role: 'compute', name: '算力设备2' }];
  hub.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 2, memAvail: 8000, modelTier: 2 });
  assert.equal(hub.page.send('```python\nprint(1)\n```'), '');
  assert.equal(hub.sent.filter(m => m.type === 'request').length, 0, 'a busy strong peer loses to the idle hub');
  assert.equal(localStarts, 1, 'pickNode picking self keeps the question on the chat rail');
  assert.equal(hub.page.jobs[0].workerEpoch, 0);
  // modelTier 单独成帧也走统计更新（handleDeviceInfo 状态门包含 modelTier）。
  hub.page.receive({ type: 'deviceInfo', requestId: 'info-7', modelTier: 2 }, 7);
  assert.equal(hub.page.peerStats.get(7).modelTier, 2);
  console.log('PASS: busy strong peer downgrades to the idle hub; modelTier-only frames update stats');
}

// 全默认档位（老对端/未声明）：本机按强档 2 兜底，复杂档 2 ≤ 2 → 不进调度器，
// 聊天轨道直答（未声明档位时不改变原有行为）；弱档本机 + 同档对端贴近平手时
// 内存决胜；单机时 pickNode 只剩本机 → 仍聊天轨道直答（单机零回归）。
{
  const hub = setup(true);
  hub.page.pageReady = true;
  hub.page.serviceReady = true;
  let localStarts = 0;
  hub.page.model = { start() { localStarts++; return ''; }, readinessError() { return ''; },
    cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  hub.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
    capabilities: ['text'], modelTier: 1, modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  hub.channel.peerInfos = () => [{ epoch: 7, peerId: 'w', ready: true, role: 'compute', name: '算力设备2' }];
  hub.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 0, memAvail: 8000, modelTier: 1 });
  assert.equal(hub.page.send('```python\nprint(1)\n```'), '');
  assert.equal(hub.page.jobs[0].workerEpoch, 7, 'a closeness tie between same-tier nodes falls back to memory');
  // 撤掉弱档声明（= 未声明/老对端形态）：复杂档 2 ≤ 强档兜底 2 → 本机直答。
  hub.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
    capabilities: ['text'], modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  hub.sent.length = 0;
  assert.equal(hub.page.send('```python\nprint(2)\n```'), '');
  assert.equal(hub.sent.filter(m => m.type === 'request').length, 0, 'an undeclared hub defaults to the strong tier and answers locally');
  assert.equal(localStarts, 1);
  // 单机（独立实例，mock 本地推理不会结束，避免 busy 门）：仍聊天轨道直答。
  const solo = setup(true);
  solo.page.pageReady = true;
  solo.page.serviceReady = true;
  let soloStarts = 0;
  solo.page.model = { start() { soloStarts++; return ''; }, readinessError() { return ''; },
    cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  solo.channel.peerInfos = () => [];
  assert.equal(solo.page.send('```python\nprint(3)\n```'), '');
  assert.equal(solo.sent.length, 0);
  assert.equal(soloStarts, 1, 'a single device keeps every question local');
  console.log('PASS: undeclared hub defaults strong and stays local; same-tier ties fall back to memory; single device stays local');
}

// worker（非 hub）没有调度权：重问题不因档位被拒，仍本机直答（tier fail open，
// 否则 scheduleRequest 会回"请连接算力设备1"把质量偏好变成拒绝理由）。
{
  const worker = setup(true);
  worker.page.pageReady = true;
  worker.page.serviceReady = true;
  let localStarts = 0;
  worker.page.model = { start() { localStarts++; return ''; }, readinessError() { return ''; },
    cancel() {}, hasPendingNativeJobs() { return false; }, activeCount() { return 0; } };
  worker.page.selfEntry = () => ({ role: 'self', model: 'Qwen2.5-7B-Instruct-Q4_N_0',
    capabilities: ['text'], modelTier: 1, modelRequests: 0, memAvail: 500, memTotal: 1000, memUsage: 10 });
  worker.channel.selfComputeNumber = () => 2;
  worker.channel.peerInfos = () => [{ epoch: 7, peerId: 'hub', ready: true, role: 'compute', name: '算力设备1' }];
  worker.page.peerStats.set(7, { model: 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequests: 0, memAvail: 8000, modelTier: 2 });
  assert.equal(worker.page.send('```python\nprint(1)\n```'), '');
  assert.equal(worker.sent.filter(m => m.type === 'request').length, 0, 'a worker without scheduling rights answers locally instead of erroring');
  assert.equal(localStarts, 1);
  console.log('PASS: a non-hub worker answers heavy questions locally instead of refusing on tier');
}

// 算力端↔算力端 roster 同步后的空 deviceInfo 轮询帧必须带 capabilities 字段：
{
  const h=setup(true),job=h.page.createJob('timing',[{role:'user',content:'timing'}],false,0);
  h.page.jobs.push(job);
  h.page.localUpdate(job.key,{kind:'delta',text:'',metrics:{streaming:true}});
  assert.equal(job.firstAt,0,'an empty chunk never starts the first-output clock');
  job.startedAt=Date.now()-1000;const capturedAt=job.startedAt+250;
  h.page.localUpdate(job.key,{kind:'delta',text:'answer',metrics:{streaming:true},outputAt:capturedAt});
  assert.equal(job.firstAt,capturedAt,'use callback time rather than the JS poll time');const first=job.firstAt;
  h.page.localUpdate(job.key,{kind:'done',text:'answer',finishReason:'stop',metrics:{streaming:true,prefillMs:25,completionTokens:1}});
  const view=h.page.toJobView(h.page.finishedJobs[0],Date.now());
  assert.equal(view.firstAt,first);assert.equal(view.metrics.prefillMs,25);assert.equal(view.running,false);
  assert.equal(h.page.usage.completedTasks,1);
  assert.equal(h.page.usage.completionTokens,1);
  assert.ok(h.page.usage.savedMicroYuan===4||h.page.usage.savedMicroYuan===8);
  console.log('PASS: observed first output skips empty chunks and final engine metrics survive the dashboard');
}

// 算力端↔算力端 roster 同步后的空 deviceInfo 轮询帧必须带 capabilities 字段：
// validDeviceInfo 在 v2 中要求必填，缺字段会让 encodeMessage 抛错，
// 触发 LinkEnhanceChannel drop('消息格式或长度超出限制')——真机上两台算力端握手成功后立即互踢。
(async () => {
  const hub = setup(true);
  hub.page.pageReady = true;
  hub.page.serviceReady = true;
  hub.channel.selfComputeNumber = () => 1;
  hub.channel.hasEpoch = epoch => epoch === 2;
  hub.channel.peerInfos = () => [
    { epoch: 1, peerId: 'chat', name: '聊天设备1', helloName: '聊天设备1', ready: true, role: 'chat', slot: 1 },
    { epoch: 2, peerId: 'worker', name: '算力设备2', helloName: '算力设备2', ready: true, role: 'compute', slot: 2 }
  ];
  hub.page.pollDeviceInfo();
  await flush();
  const poll = hub.sent.filter(message => message.type === 'deviceInfo' && String(message.requestId).indexOf('info-') === 0);
  assert.equal(poll.length, 1, 'exactly one info poll goes to the compute worker, none to the chat link');
  assert(Array.isArray(poll[0].capabilities), 'the info poll frame must declare capabilities');
  console.log('PASS: compute info poll frame carries capabilities (validDeviceInfo-safe)');
})().catch(error => { console.error(error); process.exitCode = 1; });

(async () => {
  const h=setup(true);h.page.pageReady=true;
  const chat=epoch=>({epoch,peerId:'chat-'+epoch,deviceUid:'uid-'+epoch,name:'聊天设备'+(epoch-6),helloName:'聊天设备'+(epoch-6),role:'chat',ready:true,slot:epoch-6});
  h.channel.peerInfos=()=>[chat(7),chat(8)];
  for(const epoch of [7,8]){
    h.page.receiveInference({type:'infer.request',requestId:'same',prompt:'图片问题',image:'YQ=='},epoch);
    h.page.receiveInference({type:'infer.status',requestId:'same',source:'queue-display',state:'queued',text:'2000'},epoch);
  }
  assert.equal(h.page.queuedJobs.size,2,'same wire id from different chats must remain distinct');
  const waiting=[...h.page.queuedJobs.values()];assert(waiting.every(job=>job.kind==='image'&&job.phase==='queued'&&job.source===''));
  assert(waiting.every(job=>Date.now()-job.phaseStartedAt>=2000),'wait clocks preserve accumulated client retry time');
  h.page.receiveInference({type:'infer.status',requestId:'same',source:'queue-display',state:'cleared'},7);
  assert.equal(h.page.queuedJobs.size,1);
  h.page.receiveInference({type:'infer.status',requestId:'forged',source:'queue-display',state:'queued'},7);
  assert.equal(h.page.queuedJobs.size,1,'a wait notice needs a previously received request');
  assert.equal(h.page.jobs.length,0,'display notices never schedule native work');
  console.log('PASS: real image retry waits, local duration reconstruction, session isolation, cancellation and no phantom requests');

  const hub=setup(true);hub.channel.peerInfos=()=>[{epoch:1,peerId:'w',deviceUid:'worker',name:'算力设备2',helloName:'算力设备2',role:'compute',slot:2,ready:true}];
  const call={id:'r',key:'7:r',kind:'image',phase:'sending',origin:'聊天设备1',source:'算力设备1',originId:'phone',executorId:'self',startedAt:Date.now()-5000,phaseStartedAt:Date.now()-3000,running:true,question:'PRIVATE PROMPT',image:'PRIVATE IMAGE',answer:'PRIVATE ANSWER'};
  hub.page.publishFlow([call]);await flush();
  const first=hub.sent.find(message=>message.source==='flow-display');assert(first);
  assert(!/PRIVATE/.test(first.text),'flow notices omit model input, image and answer payloads');
  const count=hub.sent.length;hub.page.publishFlow([call]);await flush();assert.equal(hub.sent.length,count,'stream refreshes must not flood the wire with display frames');
  const worker=setup(true);worker.channel.selfComputeNumber=()=>2;worker.channel.selfLabel=()=>'算力设备2';
  worker.channel.peerInfos=()=>[{epoch:1,peerId:'hub',name:'算力设备1',helloName:'算力设备1',role:'compute',slot:1,ready:true}];
  worker.page.receiveFlow(first,1);assert.equal(worker.page.flowMirrors.size,1);
  assert([...worker.page.flowMirrors.values()].every(job=>job.kind==='image'&&job.phase==='sending'));
  hub.page.publishFlow([]);await flush();const last=hub.sent.filter(message=>message.source==='flow-display').at(-1);
  worker.page.receiveFlow(last,1);assert.equal(worker.page.flowMirrors.size,0);
  worker.page.receiveFlow(first,1);assert.equal(worker.page.flowMirrors.size,0,'late start snapshots cannot revive a cleared request');
  worker.page.receiveFlow({...first,text:'{bad json'},1);worker.page.receiveFlow(first,99);assert.equal(worker.page.flowMirrors.size,0);
  console.log('PASS: worker flow mirrors, payload privacy, phase-only publication, terminal revisions and sender/schema checks');

  const local=setup(true);
  const pictured=local.page.createJob('img',[{role:'user',content:'这是什么'}],true,7,0,'/9j/4AAQ');
  assert.equal(pictured.question,'这是什么');
  assert.equal(pictured.image,'data:image/jpeg;base64,/9j/4AAQ');
  assert.equal(pictured.kind,'image');
  local.page.showInferTask('vis',7,'介绍一下深圳','普通聊天','/9j/4AAQ');
  const infer=local.page.jobs.find(job=>job.id==='vis');
  assert.equal(infer.question,'介绍一下深圳');
  assert.equal(infer.image,'data:image/jpeg;base64,/9j/4AAQ');
  console.log('PASS: collaboration cards keep the current question and request image');
})().catch(error=>{console.error(error);process.exitCode=1;});
