// node IndexFocus.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/typescript.js');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
function setup() {
  let connected = false, operation = 0, connections = 0, disconnects = 0, checks = 0;
  const events = [], sent = [];
  const behavior = { devices: [{ deviceId: 'stable', networkId: 'current', deviceName: '模型手机' }],
    check: async () => '', connect: async () => { connected = true; }, wait: async () => connected };
  const channel = {
    isConnected: () => connected, isConnecting: () => false, operation: () => operation,
    devices: async () => behavior.devices,
    connect: async (id, expected) => { assert.equal(id, 'current'); assert.equal(expected, operation); connections++; await behavior.connect(); },
    waitUntilConnected: () => behavior.wait(), checkService: () => { checks++; return behavior.check(); },
    disconnect: () => { disconnects++; operation++; connected = false; },
    getStatus: () => connected ? '近场已连接' : '未连接',
    send: async message => { sent.push(message); return true; }
  };
  const context = { exports: {}, Error, require(name) {
    if (name === '@kit.ArkWeb') return { webview: { WebviewController: class {
      async runJavaScript(script) { events.push(JSON.parse(script.slice('window.onNativeEvent('.length, -1))); }
    } } };
    if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'request-1' } };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {} } };
    if (name === '../nearby/NearbyChannel') return { nearbyChannel: channel };
    if (name === '../nearby/NearbyConfig') return { IS_SERVER: false };
    if (name === '../nearby/LocalChat') return { LocalChat: class {} };
    return {};
  } };
  let source = fs.readFileSync(__dirname + '/../pages/Index.ets', 'utf8');
  source = source.replace(/@Entry\s+@Component\s+struct Index/, 'export class Index');
  source = source.slice(0, source.indexOf('  build() {')) + '\n}';
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, context);
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
  const makeElement = () => ({ handlers: {}, value: '', style: {}, classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { this.handlers[type] = fn; }, setAttribute() {}, appendChild() {}, blur() {} });
  const elements = Object.fromEntries(['history', 'prompt', 'send', 'connect', 'composer', 'connection'].map(id => [id, makeElement()]));
  const document = { handlers: {}, getElementById: id => elements[id], createElement: makeElement,
    addEventListener(type, fn) { this.handlers[type] = fn; } };
  let preparations = 0;
  const window = { chatBridge: { prepare() { preparations++; }, connect() {}, send() { return '协同尚未准备完成'; } } };
  const html = fs.readFileSync(__dirname + '/../../resources/rawfile/peer-chat.html', 'utf8');
  vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], { document, window });
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
  console.log('PASS: HTML pointer/focus dedup, automatic focus no retry, explicit click/Tab retries, send availability and draft preservation');
}
