// node RouterSettings.test.cjs [path/to/typescript/lib/typescript.js]
// 路由算法持久化测试（照 OutputSettings.test.cjs 的内存 fileIo + failRename 模式）：
// 缺文件/损坏 JSON/非法名字（含已退役的 auto/split/pin1）归一 'least_load'，
// 合法往返（含模块重启），save 拒绝未知名字，原子写失败保留旧值，与其它配置文件互不干扰。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../../tests/ets-harness.cjs');

function loadGraph(entryFile, externals = {}) {
  const cache = new Map();
  function req(fromDir, name) {
    if (!name.startsWith('.')) {
      if (externals[name] !== undefined) return externals[name];
      throw new Error('router modules must stay dependency-free: ' + name);
    }
    const file = path.resolve(fromDir, name + '.ets');
    if (cache.has(file)) return cache.get(file);
    const box = { exports: {}, require: (n) => req(path.dirname(file), n),
      Date, Map, Set, Math, Number, Array, JSON, Error };
    vm.runInNewContext(transpile(file), box);
    cache.set(file, box.exports);
    return box.exports;
  }
  return req(path.dirname(entryFile), './' + path.basename(entryFile, '.ets'));
}

const files = new Map();
let failRename = false;
const fileIo = {
  OpenMode: { CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
  readTextSync(p) { if (!files.has(p)) throw Error('missing'); return files.get(p); },
  openSync(p) { files.set(p, ''); return { fd: p }; },
  writeSync(fd, text) { files.set(fd, text); },
  closeSync() {},
  renameSync(from, to) { if (failRename) throw Error('disk error'); files.set(to, files.get(from)); files.delete(from); }
};
const store = () => loadGraph(path.join(__dirname, 'RouterSettings.ets'), { '@kit.CoreFileKit': { fileIo } });
const file = '/files/router-algorithm.json';

assert.equal(store().routerSettings('/files').algorithm, 'least_load', 'missing file defaults to least_load');
for (const invalid of ['broken', 'null', '{}', '{"algorithm":42}', '{"algorithm":"nope"}',
  '{"algorithm":"auto"}', '{"algorithm":"split"}', '{"algorithm":"pin1"}']) {
  files.set(file, invalid);
  assert.equal(store().routerSettings('/files').algorithm, 'least_load', 'normalizes ' + invalid);
}
files.set('/files/model-selection.json', '{"model":"Qwen3.5"}');
files.set('/files/inference-output.json', '{"streaming":false}');
assert.equal(store().saveRouterSettings('/files', { algorithm: 'least_load' }), '');
assert.equal(store().routerSettings('/files').algorithm, 'least_load', 'round-trips a valid name');
assert.equal(store().routerSettings('/files').algorithm, 'least_load', 'preference survives a module restart');
assert.ok(store().saveRouterSettings('/files', { algorithm: 'nope' }), 'save rejects an unknown name');
assert.ok(store().saveRouterSettings('/files', { algorithm: 'auto' }), 'save rejects a retired name');
failRename = true;
assert.ok(store().saveRouterSettings('/files', { algorithm: 'least_load' }), 'rename failure surfaces an error');
assert.equal(store().routerSettings('/files').algorithm, 'least_load', 'failed atomic save preserves the active preference');
failRename = false;
assert.equal(store().saveRouterSettings('/files', { algorithm: 'least_load' }), '');
assert.equal(store().routerSettings('/files').algorithm, 'least_load');
assert.equal(files.get('/files/model-selection.json'), '{"model":"Qwen3.5"}', 'model selection is independent');
assert.equal(files.get('/files/inference-output.json'), '{"streaming":false}', 'output settings are independent');
console.log('PASS: persistent router algorithm, defaults, malformed values and failed atomic save');
