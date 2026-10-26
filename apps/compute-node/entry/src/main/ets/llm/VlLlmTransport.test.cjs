// node VlLlmTransport.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');

// ---- 文件系统桩：记录写过什么，模拟可读可写沙箱 cache ----
const writes = [];
const fsStub = {
  OpenMode: { READ_ONLY: 0, READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
  openSync(path, mode) { writes.push({ path, mode }); return { fd: path }; },
  closeSync() {}, readSync() { return 0; }, writeSync(fd, buf) { },
  mkdirSync(dir, recursive) { }
};

// ---- VL 引擎桩：捕获 start 参数，可编程回调 ----
let called = null;
let engineStarts = 0;
let engineReady = '';
let engineOk = true;
let streaming = true;
const engineStub = {
  getInstance: () => ({
    readinessError: () => engineReady,
    start(imagePath, prompt, cb) {
      engineStarts++; called = { imagePath, prompt, cb }; return engineOk;
    },
    cancel() {}, isBusy() { return false; }
  })
};

const context = { exports: {}, ArrayBuffer, Uint8Array, Date: { now: () => 123 } ,
  require(name) {
    if (name === '@kit.CoreFileKit') return { fileIo: fsStub };
    if (name === '@kit.ArkTS') return {
      util: {
        Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } },
        TextEncoder: { create: () => ({ encodeInto(text) { return new Uint8Array(Buffer.from(text, 'utf8')); } }) },
        TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString('utf8') }) }
      }
    };
    if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, error() {}, warn() {} } };
    if (name === './LocalChat') return {};
    if (name === './OutputSettings') return {outputSettings:()=>({streaming})};
    if (name === './LlmTransport') return {};
    if (name === './QwenVlManager') return { QwenVlManager: engineStub };
    return {};
  } };
vm.runInNewContext(transpile(__dirname + '/VlLlmTransport.ets'), context);
const { VlLlmTransport, cleanVlPrompt } = context.exports;

// 裸 base64（新版管线格式）→ 解码落盘
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  assert.equal(t.start([{ role: 'user', content: '这是什么' }], () => {}, 'a', 'QUJD'), '');
  assert.equal(engineStarts, 1, 'VL engine is started');
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'bare base64 decodes to a cache jpg');
  assert.ok(called.imagePath.endsWith('.jpg'), 'image lands as a jpg file');
  assert.equal(called.prompt, '这是什么', 'the last user message is the prompt');
  assert.ok(writes.some(w => w.path.indexOf('/data/storage/el2/base/cache/qwenvl_') === 0),
    'image file is created');
}

// 回归：JPEG 裸 base64 以 "/9j/..." 开头（含 '/'），绝不能被误判为绝对路径透传。
// 这正是线上 "stbi_load failed: /9j/4AAQ..." 的根因。
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  const jpegB64 = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAkJCQoKCg0NDQ0NDQ0'+'NDQ0NDQ0NDQ0NDQ0NDQ0='.replace('=', '');
  const err = t.start([{ role: 'user', content: '图里有几只猫' }], () => {}, 'a1', jpegB64);
  assert.equal(err, '', 'jpeg-like bare base64 starts the engine: ' + err);
  assert.equal(engineStarts, 1, 'engine called for jpeg-prefixed base64');
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'starts with /9j/ yet still decodes to a cache file, not passed through: ' + called.imagePath);
  assert.ok(called.imagePath.endsWith('.jpg'), 'lands as jpg');
  assert.equal(called.prompt, '图里有几只猫');
}

// 绝对路径仍直通（路径含 '.'，不匹配裸 base64 判定）
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  const err = t.start([{ role: 'user', content: '看' }], () => {}, 'a2',
    '/data/storage/el2/base/cache/qwenvl_1.jpg');
  assert.equal(err, '', 'abs path accepted');
  assert.equal(called.imagePath, '/data/storage/el2/base/cache/qwenvl_1.jpg', 'abs path passes through');
}

// dataUrl（旧版/远端转发兼容）→ 同样解码落盘
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0;
  assert.equal(t.start([{ role: 'user', content: '图示' }], () => {}, 'b',
    'data:image/jpeg;base64,QUJD'), '');
  assert.equal(engineStarts, 1);
  assert.equal(called.imagePath.indexOf('/data/storage/el2/base/cache/qwenvl_'), 0,
    'dataUrl also lands in cache');
  assert.equal(called.prompt, '图示');
}

// 绝对路径直接透传（测试/内部调用），prompt 剥离"（附图）"伪前缀
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0;
  assert.equal(t.start([{ role: 'user', content: '（附图）请看' }], () => {}, 'c',
    '/data/storage/el2/base/cache/qwenvl_1.jpg'), '');
  assert.equal(engineStarts, 1);
  assert.equal(called.imagePath, '/data/storage/el2/base/cache/qwenvl_1.jpg', 'abs path passes through');
  assert.equal(called.prompt, '请看', '（附图） prefix is peeled');
}

// 回归（P3 根因，真机实测）：infer 通路的 user 段是 **ReAct 分段**，
// 形如 "User task:\n（附图）<问题>\n\n\nControl: Current"。
// 脚手架不剥干净时，3B VL 模型会按该框架"续写"，输出 `Action: {乱码}<|im_end|>`、
// `2<|im_end|>` 这类垃圾，而引擎仍报 rc=0 —— 用户看到的就是"得不到准确结果"。
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; called = null;
  const react = 'User task:\n（附图）这是只什么动物\n\n\nControl: Current\n';
  assert.equal(t.start([{ role: 'user', content: react }], () => {}, 'g',
    '/data/storage/el2/base/cache/qwenvl_1.jpg'), '');
  assert.equal(engineStarts, 1);
  assert.equal(called.prompt, '这是只什么动物', 'ReAct scaffolding is stripped down to the question');
}
// 老通路（无脚手架）必须完全不受影响：清洗是 no-op
{
  const t = new VlLlmTransport('/cache', '/files');
  called = null;
  t.start([{ role: 'user', content: '这只猫是什么颜色的' }], () => {}, 'h',
    '/data/storage/el2/base/cache/qwenvl_1.jpg');
  assert.equal(called.prompt, '这只猫是什么颜色的', 'a plain question is untouched');
}
// 只有 Control 段的截图类任务也要剥干净
{
  const t = new VlLlmTransport('/cache', '/files');
  called = null;
  t.start([{ role: 'user', content: 'User task:\n图中的算式等于几\n\n\nControl: Current' }], () => {}, 'i',
    '/data/storage/el2/base/cache/qwenvl_1.jpg');
  assert.equal(called.prompt, '图中的算式等于几', 'Control group is dropped');
}
// 边界：任务为空时返回空串，由 QwenVlManager 的默认提示词兜底
assert.equal(cleanVlPrompt('User task:\n（附图）\n\n\nControl: Current'), '', 'empty task stays empty');
assert.equal(cleanVlPrompt('Control: Current'), '', 'a pure control group yields empty');
assert.equal(cleanVlPrompt('（附图）好看不'), '好看不', 'bare marker is peeled without scaffolding');
// 问题正文里出现 "Control:" 不能被误截断（只有行首独占的那一行才是 ReAct 控制组）
assert.equal(cleanVlPrompt('这个 Control: 是什么意思'), '这个 Control: 是什么意思',
  'a mid-sentence Control: is part of the question');
assert.equal(cleanVlPrompt('User task:\n这个 Control: 是啥\n\n\nControl: Current'), '这个 Control: 是啥',
  'only the line-anchored control group is dropped');

// 引擎未部署 → 门控失败，不触碰引擎
{
  const t = new VlLlmTransport('/cache', '/files');
  engineStarts = 0; engineReady = 'VL 模型未部署';
  const err = t.start([{ role: 'user', content: 'x' }], () => {}, 'd', 'QUJD');
  assert.ok(err.length > 0, 'readiness gate rejects: ' + err);
  assert.equal(engineStarts, 0);
  engineReady = '';
}

// 事件映射：delta 透传；done 追加溯源标签并带 finishReason
{
  const t = new VlLlmTransport('/cache', '/files');
  const updates = [];
  t.start([{ role: 'user', content: '图里有什么' }], u => { updates.push(u); }, 'e', 'QUJD');
  called.cb({ delta: '一只' });
  called.cb({ delta: '猫' });
  called.cb({ done: '一只猫', finishReason: 'stop' });
  assert.equal(updates[0].kind, 'delta'); assert.equal(updates[0].text, '一只');
  assert.equal(updates[1].kind, 'delta'); assert.equal(updates[1].text, '猫');
  assert.equal(updates[2].kind, 'done');
  assert.ok(updates[2].text.indexOf('一只猫') === 0, 'done carries the full answer');
  assert.ok(updates[2].text.indexOf('Qwen2.5-VL-3B-NPU') > 0, 'source tag appended');
  assert.equal(updates[2].finishReason, 'stop');
}

// loading 事件被忽略（web UI busy 态覆盖）
{
  const t = new VlLlmTransport('/cache', '/files');
  const updates = [];
  t.start([{ role: 'user', content: 'x' }], u => { updates.push(u); }, 'f', 'QUJD');
  called.cb({ loading: true });
  assert.equal(updates.length, 0, 'loading is swallowed');
  called.cb({ done: '答' });
  assert.equal(updates.length, 1, 'only the final done surfaces');
}

console.log('PASS: VlLlmTransport image forms, prompt peeling (incl. ReAct scaffolding), readiness gate, event mapping');
{
  streaming=false;const t=new VlLlmTransport('/cache','/files'),updates=[];
  t.start([{role:'user',content:'image'}],u=>updates.push(u),'nonstream','QUJD');
  streaming=true; // Settings change applies only to the next request.
  called.cb({delta:'first'});called.cb({delta:' second'});assert.equal(updates.length,0);
  called.cb({done:'first second',finishReason:'stop'});
  assert.deepEqual(updates.map(u=>u.kind),['delta','done']);assert.equal(updates[0].text,'first second');
  assert.equal(updates[0].metrics.streaming,false);assert.equal(updates[1].metrics.streaming,false);
  const next=[];t.start([{role:'user',content:'next'}],u=>next.push(u),'stream','QUJD');
  called.cb({delta:'live'});assert.equal(next[0].text,'live');assert.equal(next[0].metrics.streaming,true);
  streaming=false;const failed=[];t.start([{role:'user',content:'bad'}],u=>failed.push(u),'bad','QUJD');
  called.cb({done:'failure',error:'failure'});assert.deepEqual(failed.map(u=>u.kind),['done']);
  streaming=true;
}
console.log('PASS: VL output preference buffers complete responses without changing an active request');
