// node LocalChat.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
const root = '/files/models/Qwen2.5-7B-Instruct-Q4_N_0/';
const names = ['api_config.json', 'params', 'tokenizer.json'];
let missing = '', unreadable = '', empty = '', starts = 0, nextId = 0, failStart = false;
const opened = [], closed = [];
const context = { exports: {}, ArrayBuffer, setInterval: () => 1, clearInterval() {}, require(name) {
  if (name === 'libgewu_probe.so') return { default: {
    start() { starts++; return failStart ? 0 : ++nextId; }, cancel() {}, complete() {}, takeEvents() { return []; }
  } };
  assert.equal(name, '@kit.CoreFileKit');
  return { fileIo: { OpenMode: { READ_ONLY: 0 },
    openSync(path, mode) {
      assert.equal(mode, 0);
      assert(names.some(name => path === root + name));
      if (path === root + missing) throw new Error('missing');
      const file = { fd: path };
      opened.push(file);
      return file;
    },
    readSync(fd, buffer) {
      assert.equal(buffer.byteLength, 1, 'readiness reads only one byte, never model weights');
      if (fd === root + unreadable) throw new Error('unreadable');
      return fd === root + empty ? 0 : 1;
    },
    closeSync(file) { closed.push(file); }
  } };
} };
vm.runInNewContext(transpile(__dirname + '/LocalChat.ets'), context);
const { LocalChat } = context.exports;
const chat = new LocalChat('/files');
assert.equal(chat.readinessError(), '');
assert.equal(opened.length, 3);
assert.equal(starts, 0, 'readiness must never start GEWU');
for (const name of names) {
  missing = name;
  assert(chat.readinessError().includes(name));
}
missing = '';
unreadable = 'params';
assert(chat.readinessError().includes('params'));
unreadable = '';
empty = 'tokenizer.json';
assert(chat.readinessError().includes('tokenizer.json'));
empty = '';
assert.deepEqual(closed, opened, 'close all handles on success, failed reads, and empty files');
assert.equal(starts, 0);
assert.equal(chat.start([{ role: 'user', content: 'hi' }], () => {}, 'a'), '');
assert.equal(starts, 1);
assert.equal(chat.activeCount(), 1);
assert.equal(chat.readinessError(), '', 'one in-flight job must not block another device prepare');
assert.equal(chat.start([{ role: 'user', content: 'hi2' }], () => {}, 'b'), '');
assert.equal(starts, 2);
assert.equal(chat.start([{ role: 'user', content: 'hi3' }], () => {}, 'c'), '');
assert.equal(starts, 3);
assert.equal(chat.activeCount(), 3);
assert.equal(chat.readinessError(), '', 'many in-flight jobs must still allow prepare');
failStart = true;
assert.equal(chat.start([{ role: 'user', content: 'hi4' }], () => {}, 'd'), '模型繁忙，请稍后再发。');
assert.equal(starts, 4, 'native start is attempted even when jobs already run');
assert.equal(chat.activeCount(), 3, 'failed native start must not keep a job');
failStart = false;
const afterBusy = opened.length;
chat.close();
assert.equal(chat.readinessError(), '模型服务已关闭。');
assert.equal(opened.length, afterBusy, 'closed readiness must not reopen model files');
assert.equal(starts, 4, 'closed readiness must not start another inference');
console.log('PASS: readiness without GEWU startup; concurrent jobs unbounded in ArkTS; native failure busy; prepare never blocked by busy');
