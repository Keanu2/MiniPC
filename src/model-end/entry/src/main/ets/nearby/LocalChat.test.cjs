// node LocalChat.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/typescript.js');
const root = '/files/models/Qwen2.5-7B-Instruct-Q4_N_0/';
const names = ['api_config.json', 'params', 'tokenizer.json'];
let missing = '', unreadable = '', empty = '', starts = 0;
const opened = [], closed = [];
const context = { exports: {}, ArrayBuffer, setInterval: () => 1, clearInterval() {}, require(name) {
  if (name === 'libgewu_probe.so') return { default: {
    start() { starts++; return true; }, cancel() {}, takeEvents() { return []; }
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
vm.runInNewContext(ts.transpileModule(fs.readFileSync(__dirname + '/LocalChat.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, context);
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
assert.equal(chat.start([{ role: 'user', content: 'hi' }], () => {}), '');
assert.equal(starts, 1);
const count = opened.length;
assert.equal(chat.readinessError(), '上一条回复还未结束。');
assert.equal(opened.length, count);
chat.close();
assert.equal(chat.readinessError(), '模型服务已关闭。');
assert.equal(opened.length, count);
assert.equal(starts, 1, 'busy/closed readiness must not start another inference');
console.log('PASS: readiness checks all required files without GEWU startup, rejects busy/closed/missing/unreadable/empty, closes file handles');
