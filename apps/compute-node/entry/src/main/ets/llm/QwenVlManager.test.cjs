// Real manager + transport; only SDK/platform boundaries are stubbed.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function fixture(options = {}) {
  const starts = [], updates = [], events = [], timers = new Map();
  let sequence = 0, completes = 0, cancels = 0;
  const native = { available: true,
    start(...args) {
      starts.push(args);
      if (options.throwRetry && starts.length === 2) throw Error('restart failed');
      return !(options.refuseRetry && starts.length === 2);
    },
    takeEvents: () => events.splice(0), complete() { completes++; },
    cancel() { cancels++; }, release() {}
  };
  let managerExports;
  const imports = {
    'libqwenvl_engine.so': { default: native },
    '@kit.CoreFileKit': { fileIo: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    './ModelRegistry': { activeModelDirs: () => ['VL'], isVlLayout: () => true, readinessOf: () => '' },
    './OutputSettings': { outputSettings: () => ({ streaming: options.streaming !== false }) }
  };
  const load = file => {
    const box = { exports: {}, Date, setInterval(fn) { const id = ++sequence; timers.set(id, fn); return id; },
      clearInterval(id) { timers.delete(id); }, require: name => name === './QwenVlManager' ? managerExports : (imports[name] || {}) };
    vm.runInNewContext(transpile(__dirname + '/' + file + '.ets'), box);
    return box.exports;
  };
  managerExports = load('QwenVlManager');
  const manager = managerExports.QwenVlManager.getInstance();
  manager.init('/files');
  const transport = new (load('VlLlmTransport').VlLlmTransport)('/cache', '/files');
  return { manager, transport, starts, updates,
    start() { assert(manager.start('/image.jpg', '图片是什么', u => updates.push(u))); },
    response(text) { events.push(JSON.stringify({ event: 'response', payload: text })); },
    end(reason = 'stop') { events.push(JSON.stringify({ event: 'end', payload: reason })); },
    error(text) { events.push(JSON.stringify({ event: 'error', payload: text })); },
    poll() { for (const tick of Array.from(timers.values())) tick(); },
    get completes() { return completes; }, get cancels() { return cancels; },
    get timerCount() { return timers.size; }
  };
}
const deltas = h => h.updates.filter(u => u.delta !== undefined).map(u => u.delta).join('');
for (const bad of ['', '   ', '<|im_end|>', 'a', '���']) {
  const h = fixture(); h.start();
  h.response(bad); h.end(); h.poll();
  assert.equal(h.starts.length, 2, JSON.stringify(bad) + ' retries once');
  assert.deepEqual(h.starts[1], h.starts[0], 'retry retains model/image/prompt');
  assert.equal(deltas(h), '', 'no rejected-attempt output escapes');
  assert(h.manager.isBusy());
  h.response('一只猫'); h.end(); h.poll();
  assert.equal(deltas(h), '一只猫');
  assert.equal(h.updates.at(-1).done, '一只猫');
  assert.equal(h.updates.at(-1).error, undefined);
  assert.equal(h.manager.isBusy(), false); assert.equal(h.timerCount, 0);
}
for (const bad of ['', '���']) {
  const h = fixture(); h.start();
  for (let i = 0; i < 2; i++) { h.response(bad); h.end(); h.poll(); }
  assert.equal(h.starts.length, 2, 'retries are bounded');
  assert(h.updates.at(-1).error); assert.equal(deltas(h), '');
}
{
  const h = fixture(); h.start();
  h.response('a<'); h.poll(); h.response('|im_'); h.poll(); h.response('end|>'); h.end(); h.poll();
  assert.equal(h.starts.length, 2); assert.equal(deltas(h), '', 'split end token cannot bypass prefix guard');
  h.response('猫'); h.end(); h.poll();
  assert.equal(h.starts.length, 2, 'a second short but valid answer is accepted');
  assert.equal(deltas(h), '猫'); assert.equal(h.updates.at(-1).done, '猫');
}
{
  const h = fixture(); h.start();
  h.response('这'); h.poll(); assert.equal(deltas(h), '');
  h.response('是'); h.poll(); assert.equal(deltas(h), '这是', 'normal output starts streaming after the prefix');
  h.response('猫<'); h.poll(); h.response('|im_end'); h.poll(); h.response('|>'); h.end(); h.poll();
  assert.equal(deltas(h), '这是猫'); assert.equal(h.updates.at(-1).done, '这是猫');
  assert.equal(h.starts.length, 1);
}
{
  const h = fixture(); h.start();
  h.response('已有内容'); h.poll(); h.response('���'); h.end(); h.poll();
  assert.equal(h.starts.length, 1, 'a published stream must never be replayed');
  assert.equal(deltas(h), '已有内容', 'a stray replacement char is dropped, not fatal'); assert.equal(h.updates.at(-1).error, undefined);
  assert.equal(h.updates.at(-1).done, '已有内容');
}
for (const option of ['throwRetry', 'refuseRetry']) {
  const h = fixture({ [option]: true }); h.start(); h.end(); h.poll();
  assert(h.updates.at(-1).error); assert.equal(h.manager.isBusy(), false); assert.equal(h.timerCount, 0);
}
{
  const h = fixture(); h.start(); h.manager.cancel(); h.end('cancelled'); h.poll();
  assert.equal(h.starts.length, 1); assert.equal(h.cancels, 1);
  assert.equal(h.updates.at(-1).finishReason, 'cancelled');
}
{
  const h = fixture(); h.start(); h.error('SDK failed'); h.end('error'); h.poll();
  assert.equal(h.updates.filter(u => u.done !== undefined).length, 1, 'error plus end settles only once');
  assert.equal(h.starts.length, 1); assert.equal(h.completes, 1);
}
for (const streaming of [true, false]) {
  const h = fixture({ streaming }), updates = [];
  assert.equal(h.transport.start([{ role: 'user', content: '图片是什么' }], u => updates.push(u), 'image-request', '/image.jpg'), '');
  h.response('a'); h.end(); h.poll();
  assert.equal(updates.length, 0, 'neither output preference exposes a rejected attempt');
  h.response('一只猫'); h.end(); h.poll();
  assert.equal(updates.filter(u => u.kind === 'delta').map(u => u.text).join(''), '一只猫');
  assert.equal(updates.filter(u => u.kind === 'done').length, 1);
  assert(updates.at(-1).text.startsWith('一只猫')); assert.equal(updates.at(-1).error, undefined);
}
console.log('PASS: VL empty/short/invalid output retry, split special tokens, clean streaming, retry failures, cancellation and terminal isolation');
