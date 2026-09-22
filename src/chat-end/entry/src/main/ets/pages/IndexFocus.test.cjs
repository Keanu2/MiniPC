// node IndexFocus.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile, transpileSource } = require('../../../../../../tests/harness.cjs');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function loadEts(file) {
  const box = { exports: {}, Error, Map, Promise, JSON };
  vm.runInNewContext(transpile(file), box);
  return box.exports;
}
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function setup() {
  let connected = false, operation = 0, connections = 0, disconnects = 0, checks = 0;
  let timerSequence = 0;
  const timers = new Map();
  const events = [], sent = [];
  const behavior = { devices: [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }],
    check: async () => '', connect: async () => { connected = true; }, wait: async () => connected };
  const channel = {
    isConnected: () => connected, isConnecting: () => false, isForeground: () => true, operation: () => operation,
    devices: async () => behavior.devices,
    computeDevices: async () => behavior.devices,
    advertisedComputes: () => {
      if (behavior.devices.length) {
        return behavior.devices.map(device => ({ name: device.deviceName, mac: device.networkId,
          key: device.networkId, slot: device.slot === undefined ? 1 : device.slot }));
      }
      return behavior.hits ? [{ name: '算力设备1', mac: 'aa:bb', key: 'aa', slot: 1 }] : [];
    },
    connectComputes: () => channel.advertisedComputes().filter(ad => ad.slot === 1),
    hasComputeHits: () => !!behavior.hits,
    connectAdvertiser: async mac => { behavior.lastMac = mac; connections++; await behavior.connect(); },
    connectToAdvertisers: async () => { connections++; await behavior.connect(); },
    bindNearby: async device => device,
    connect: async (id, expected) => { assert.equal(id, 'current'); assert.equal(expected, operation); connections++; await behavior.connect(); },
    waitUntilConnected: () => behavior.wait(), checkService: () => { checks++; return behavior.check(); },
    disconnect: () => { disconnects++; operation++; connected = false; },
    getStatus: () => connected ? '近场已连接' : '未连接',
    selfLabel: () => behavior.selfLabel || '',
    send: async message => { sent.push(message); return true; }
  };
  const context = { exports: {}, Error, Map, Promise, JSON,
    setTimeout(fn, delay) { const id = ++timerSequence; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }, require(name) {
    if (name === '@kit.ArkWeb') return { webview: { WebviewController: class {
      async runJavaScript(script) { events.push(JSON.parse(script.slice('window.onNativeEvent('.length, -1))); }
    } } };
    if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'request-1' } };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {} } };
    if (name === '../nearby/LinkEnhanceChannel') {
      return { nearbyChannel: channel };
    }
    if (name === '../nearby/NearbyConfig') return { IS_SERVER: false };
    if (name === '../llm/LocalChat') return { LocalChat: class { hasModel() { return false; } isBusy() { return false; } } };
    if (name === '../llm/LlmTransport') return { LocalLlmTransport: class {
      constructor(chat) { this.chat = chat; }
      start(messages, cb) { return this.chat.start(messages, cb); }
      cancel() { this.chat.cancel(); }
      readinessError() { return this.chat.hasModel ? this.chat.hasModel() ? '' : this.chat.readinessError() : ''; }
    } };
    if (name === '../media/ImageAttach') return { pickJpegDataUrl: async () => '' };
    if (name === '../ui/ChatBridge') return loadEts(__dirname + '/../ui/ChatBridge.ets');
    if (name === '../cluster/DeviceInfo') return {
      formatComputeStatus(entry) {
        if (!entry) return '';
        const model = entry.model && entry.model.length > 0 ? entry.model : '无模型';
        const parts = [model];
        if (entry.memUsage !== undefined && entry.memUsage >= 0) parts.push('内存 ' + String(entry.memUsage) + '%');
        if (entry.modelRequests !== undefined && entry.modelRequests >= 0) parts.push('推理 ' + String(entry.modelRequests));
        return parts.join(' · ');
      },
      fromDeviceInfoMessage(message) {
        return {
          id: message.id || '', name: message.name || '', role: message.role || 'compute',
          memTotal: message.memTotal, memAvail: message.memAvail, memUsage: message.memUsage,
          model: message.model || '', modelRequests: message.modelRequests, ready: true
        };
      },
      peerDisplayName(entry) {
        if (entry.role === 'self' || entry.name === '本机') return '算力';
        return entry.name || '算力';
      },
      buildSelfEntry(hasModel, running) {
        return { name: '本机', id: 'self', role: 'chat', model: hasModel ? 'Qwen' : '',
          modelRequests: running, memUsage: 12, memAvail: 1000, memTotal: 2000 };
      },
      toDeviceInfoReply: (id, entry) => ({
        type: 'deviceInfo', requestId: id, name: entry.name, model: entry.model || '',
        memUsage: entry.memUsage, modelRequests: entry.modelRequests, peerRole: 'chat'
      })
    };
    return {};
  } };
  let source = fs.readFileSync(__dirname + '/Index.ets', 'utf8');
  source = source.replace(/@Entry\s+@Component\s+struct Index/, 'export class Index');
  source = source.slice(0, source.indexOf('  build() {')) + '\n}';
  vm.runInNewContext(transpileSource(source), context);
  const page = new context.exports.Index(); page.pageReady = true;
  return { page, channel, behavior, events, sent, counts: () => ({ connections, disconnects, checks }),
    setConnected: value => { connected = value; },
    timerDelays: () => Array.from(timers.values()).map(timer => timer.delay),
    fireNextTimer: () => {
      const next = timers.entries().next().value;
      if (!next) return false;
      timers.delete(next[0]);
      next[1].fn();
      return true;
    } };
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
  c.page.receive({ type: 'delta', requestId: 'request-1', text: '你好' }, 1);
  c.page.receive({ type: 'done', requestId: 'request-1', finishReason: 'stop', source: '由算力设备1推理' }, 1);
  assert(c.events.at(-1).text.includes('你好'));
  assert(c.events.at(-1).text.includes('由算力设备1推理'));
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
  const hub = setup();
  hub.behavior.devices = [
    { deviceId: 'worker', networkId: 'worker-mac', deviceName: '算力设备2', slot: 2 },
    { deviceId: 'leader', networkId: 'hub-mac', deviceName: '算力设备1', slot: 1 }
  ];
  await hub.page.ensureCollaborationReady();
  assert.equal(hub.behavior.lastMac, 'hub-mac', 'chat connects only to elected compute 1');
  const noHub = setup();
  noHub.behavior.devices = [{ deviceId: 'worker', networkId: 'worker-mac', deviceName: '算力设备2', slot: 2 }];
  await noHub.page.ensureCollaborationReady();
  assert.equal(noHub.counts().connections, 0, 'chat must not silently fall back to compute 2');
  const stale = setup(), pending = deferred(); stale.behavior.check = () => pending.promise;
  const old = stale.page.ensureCollaborationReady(); await flush();
  stale.channel.disconnect(); pending.resolve(''); await old;
  assert.equal(stale.page.serviceReady, false); assert(stale.events.every(event => !event.available));
  stale.behavior.check = async () => ''; await stale.page.ensureCollaborationReady(); assert(stale.page.serviceReady);
  const hidden = setup(), delayed = deferred(); hidden.behavior.check = () => delayed.promise;
  const hiddenWork = hidden.page.ensureCollaborationReady(); await flush(); hidden.page.pageReady = false;
  delayed.resolve(''); await hiddenWork; assert.equal(hidden.page.serviceReady, false);
  const retry = setup(); retry.behavior.devices = [];
  retry.page.connectionChanged(false, 1);
  assert.deepEqual(retry.timerDelays(), [1500]);
  retry.fireNextTimer(); await flush(); assert.deepEqual(retry.timerDelays(), [4000]);
  retry.fireNextTimer(); await flush(); assert.deepEqual(retry.timerDelays(), [9000]);
  retry.fireNextTimer(); await flush(); assert.deepEqual(retry.timerDelays(), [15000]);
  retry.fireNextTimer(); await flush(); assert.deepEqual(retry.timerDelays(), [20000]);
  retry.fireNextTimer(); await flush();
  assert.deepEqual(retry.timerDelays(), []);
  assert.equal(retry.page.autoConnect, false, 'automatic reconnect remains bounded after hub failover window');
  assert(retry.page.connectionError.includes('点击“连接”重试'));
  const interrupted = setup();
  interrupted.page.activeId = 'running-request';
  interrupted.page.connectionChanged(false, 1);
  assert.equal(interrupted.page.activeId, '', 'an interrupted request is closed');
  assert.deepEqual(interrupted.timerDelays(), [1500], 'reconnect starts after the interrupted request is closed');
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
    'pick', 'preview', 'previewImg', 'previewClear', 'title'].map(id => [id, makeElement()]));
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
  window.onNativeEvent({ kind: 'connection', available: true, selfLabel: '聊天设备2' });
  assert.equal(elements.send.disabled, false);
  assert.equal(elements.title.textContent, '聊天设备2');
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
  window.onNativeEvent({ kind: 'done', text: '收到' });
  elements.prompt.value = '这是什么';
  window.onNativeEvent({ kind: 'image', text: 'data:image/jpeg;base64,yy' });
  elements.composer.handlers.submit({ preventDefault() {} });
  assert.equal(sent, '（附图）这是什么');
  console.log('PASS: HTML pointer/focus dedup, automatic focus no retry, explicit click/Tab retries, send availability and draft preservation');
}

{
  const local = setup();
  let started = 0;
  local.page.model = {
    hasModel: () => true,
    isBusy: () => started > 0,
    start() { started++; return ''; },
    cancel() {},
    readinessError: () => ''
  };
  assert.equal(local.page.send('本地问题'), '');
  assert.equal(local.sent.length, 0, 'local model must not send nearby request');
  assert.equal(started, 1);
  const connectedLocal = setup();
  connectedLocal.page.model = { hasModel: () => true, isBusy: () => false,
    start() { throw new Error('a connected chat must route through the hub'); } };
  connectedLocal.setConnected(true);
  connectedLocal.page.serviceReady = true;
  connectedLocal.page.preparedOperation = connectedLocal.channel.operation();
  assert.equal(connectedLocal.page.send('中心问题'), '');
  assert.equal(connectedLocal.sent.at(-1).type, 'request', 'connected chats always use compute 1');
  const info = setup();
  info.page.receive({ type: 'deviceInfo', requestId: 'info-1', name: '算力A', model: 'Qwen',
    memUsage: 33, modelRequests: 2 }, 1);
  assert(info.events.every(event => !String(event.text || '').includes('Qwen')));
  info.page.receive({ type: 'deviceInfoSync', requestId: 'sync-1', devices: [
    { name: '本机', model: 'Qwen', memUsage: 10, modelRequests: 1, role: 'self' }
  ] }, 1);
  assert(info.events.every(event => !String(event.text || '').includes('算力')));
  info.page.receive({ type: 'deviceInfo', requestId: 'q1' }, 1);
  assert.equal(info.sent.at(-1).type, 'deviceInfo');
  assert.equal(info.sent.at(-1).model, '');
  console.log('PASS: local-if-model send, deviceInfo status without active request');
}
