// node ComputeRouter.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript/lib/typescript.js');
const context = { exports: {}, Error, Map, Math, Number };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(__dirname + '/ComputeRouter.ets', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, context);
const { ScheduleNode, ComputeRouter, pickNode } = context.exports;
function node(partial) {
  const item = new ScheduleNode();
  Object.assign(item, partial);
  return item;
}
assert.equal(pickNode([]), null);
assert.equal(pickNode([node({ name: '空', model: '' })]), null, 'no model is not schedulable');
const idle = node({ name: '空闲', isSelf: true, model: 'Qwen', requests: 0, memAvail: 1000 });
const busy = node({ name: '忙', model: 'Qwen', requests: 2, memAvail: 9000 });
assert.equal(pickNode([busy, idle]).name, '空闲', 'idle preferred over busy even with less memory');
const self = node({ name: '本机', isSelf: true, model: 'Qwen', requests: 1, memAvail: 2000 });
const peer = node({ name: '对端', model: 'Qwen', requests: 1, memAvail: 8000 });
assert.equal(pickNode([self, peer]).name, '对端', 'same load prefers more memory');
assert.equal(pickNode([self, node({ name: '对端2', model: 'Qwen', requests: 1, memAvail: 2000 })]).isSelf, true,
  'equal load and memory prefers self');
assert.equal(pickNode([busy]).name, '忙', 'all busy still returns a modeled node');
const router = new ComputeRouter();
assert.equal(router.selfLoad(1), 1);
router.beginSelf();
assert.equal(router.selfLoad(1), 2);
router.endSelf();
assert.equal(router.selfLoad(1), 1);
const entry = { originEpoch: 1, originRequestId: 'r1', workerEpoch: 7, workerName: '算力B' };
router.beginDispatch('r1', entry);
assert.equal(router.workerLoad(7, 1), 2);
assert.equal(router.getDispatch('r1').workerName, '算力B');
assert.equal(router.finishDispatch('r1').originEpoch, 1);
assert.equal(router.workerLoad(7, 1), 1);
router.beginDispatch('a', { originEpoch: 1, originRequestId: 'a', workerEpoch: 8, workerName: 'A' });
router.beginDispatch('b', { originEpoch: 2, originRequestId: 'b', workerEpoch: 8, workerName: 'A' });
assert.equal(router.dropWorker(8).length, 2);
assert.equal(router.getDispatch('a'), undefined);
console.log('PASS: pickNode idle/memory/self, busy still scheduled, inflight dispatch accounting');
