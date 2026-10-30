// node ComputeRouter.test.cjs [path/to/typescript/lib/typescript.js]
// 派发账本测试。选点算法的断言已随算法迁至 cluster/router/Router.test.cjs
// （default 零回归 + pin/split 语义），此处只覆盖在途派发计数。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const context = { exports: {}, Error, Map, Math, Number };
vm.runInNewContext(transpile(__dirname + '/ComputeRouter.ets'), context);
const { ComputeRouter } = context.exports;
const router = new ComputeRouter();
assert.equal(router.selfLoad(1), 1);
router.beginSelf();
assert.equal(router.selfLoad(0), 1, 'inflight covers a job before GEWU reports it');
assert.equal(router.selfLoad(1), 1, 'sampled job is the same inflight, not two');
router.endSelf();
assert.equal(router.selfLoad(1), 1);
assert.equal(router.selfLoad(0), 0);
const entry = { originEpoch: 1, originRequestId: 'r1', workerEpoch: 7, workerName: '算力B' };
router.beginDispatch('r1', entry);
assert.equal(router.workerLoad(7, 0), 1);
assert.equal(router.workerLoad(7, 1), 1, 'peer sample plus inflight is one job');
assert.equal(router.getDispatch('r1').workerName, '算力B');
assert.equal(router.finishDispatch('r1').originEpoch, 1);
assert.equal(router.workerLoad(7, 1), 1);
router.beginDispatch('a', { originEpoch: 1, originRequestId: 'a', workerEpoch: 8, workerName: 'A' });
router.beginDispatch('b', { originEpoch: 2, originRequestId: 'b', workerEpoch: 8, workerName: 'A' });
assert.equal(router.dropWorker(8).length, 2);
assert.equal(router.getDispatch('a'), undefined);
console.log('PASS: dispatch accounting, inflight load cover, worker drop');
