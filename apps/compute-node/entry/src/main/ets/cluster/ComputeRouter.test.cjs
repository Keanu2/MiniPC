// node ComputeRouter.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const context = { exports: {}, Error, Map, Math, Number };
vm.runInNewContext(transpile(__dirname + '/ComputeRouter.ets'), context);
const { ScheduleNode, ComputeRouter, pickNode } = context.exports;
function node(partial) {
  const item = new ScheduleNode();
  Object.assign(item, partial);
  return item;
}
assert.equal(pickNode([]), null);
const imageOnly = node({ name: 'VL', model: 'VL', capabilities: ['vision'] });
assert.equal(pickNode([imageOnly]), null, 'legacy empty needs still means text; VL-only node must not accept it');
assert.equal(pickNode([imageOnly], ['vision']), imageOnly, 'VL-only node accepts image tasks');
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
const { pickRoute } = context.exports;
assert.equal(pickRoute([self, peer], 'auto', true).name, '对端', 'auto matches pickNode');
assert.equal(pickRoute([self, peer], 'pin1', false).isSelf, true, 'pin1 stays on the hub');
assert.equal(pickRoute([self, peer], 'pin2', true).name, '对端', 'pin2 stays on the other compute');
assert.equal(pickRoute([self, peer], 'split', true).isSelf, true, 'split can take the hub');
assert.equal(pickRoute([self, peer], 'split', false).name, '对端', 'split can take the peer');
assert.equal(pickRoute([peer], 'pin1', true), null, 'pin1 fails closed without the hub model');
assert.equal(pickRoute([self], 'pin2', false), null, 'pin2 fails closed without a peer');
// 能力过滤：needs 是硬门槛，排在空闲/负载/内存/本机之前
const textIdle = node({ name: '空闲文本', model: 'Qwen', requests: 0, memAvail: 9000 });
const visionBusy = node({ name: '忙碌多模态', model: 'VL', requests: 3, memAvail: 100, capabilities: ['text', 'vision'] });
assert.equal(pickNode([textIdle, visionBusy], ['vision']).name, '忙碌多模态',
  'capability gates before the idle preference');
assert.equal(pickNode([textIdle], ['vision']), null, 'no capable node fails closed');
assert.equal(pickNode([node({ name: '默认', model: 'Qwen', requests: 0 })], ['vision']), null,
  'a node without declared capabilities is text-only');
assert.equal(pickNode([textIdle, visionBusy], ['text']).name, '空闲文本',
  'declared needs still follow the load order');
assert.equal(pickNode([textIdle, visionBusy]).name, '空闲文本', 'no needs keeps the old behaviour');
const visionPeer = node({ name: '多模态对端', model: 'VL', requests: 1, memAvail: 8000, capabilities: ['text', 'vision'] });
assert.equal(pickRoute([self, visionPeer], 'pin1', true, ['vision']), null,
  'pin1 fails closed when the hub lacks the capability');
assert.equal(pickRoute([self, visionPeer], 'pin2', true, ['vision']).name, '多模态对端',
  'pin2 picks the capable peer');
assert.equal(pickRoute([self, visionPeer], 'split', true, ['vision']).name, '多模态对端',
  'split falls back to the capable side');
assert.equal(pickRoute([self, peer], 'split', true, ['text']).isSelf, true,
  'split without needs keeps the hub');
// 档位：负载平手时贴近决胜（贴近再平手 → 就高）；负载不平手时空闲决胜（自然降档）
const weakIdle = node({ name: '弱档闲', model: 'Lite', requests: 0, memAvail: 500, modelTier: 1 });
const midIdle = node({ name: '中档闲', model: 'Mid', requests: 0, memAvail: 500, modelTier: 2 });
const strongIdle = node({ name: '强档闲', model: 'Big', requests: 0, memAvail: 500, modelTier: 3 });
const strongBusy = node({ name: '强档忙', model: 'Big', requests: 1, memAvail: 9000, modelTier: 3 });
assert.equal(pickNode([weakIdle, midIdle], [], 3).name, '中档闲', 'load tie picks the closer tier');
assert.equal(pickNode([strongBusy, weakIdle], [], 3).name, '弱档闲',
  'heavy task downgrades to the idle weak node when the strong one is busy');
assert.equal(pickNode([strongIdle, weakIdle], [], 1).name, '弱档闲', 'light task prefers the weak node');
assert.equal(pickNode([weakIdle, strongIdle], [], 2).name, '强档闲',
  'closeness tie at tier 2 prefers the higher tier');
assert.equal(pickNode([strongBusy], [], 3).name, '强档忙', 'tier never blocks an otherwise usable node');
assert.equal(pickNode([node({ name: '强档纯文本', model: 'Big', modelTier: 3 })], ['vision']), null,
  'capability still fails closed regardless of tier');
// 零回归：全默认集群（无人声明）任何 taskTier 都与 0 / 不传参同赢家
const defaultA = node({ name: '默认甲', isSelf: true, model: 'Qwen', requests: 0, memAvail: 2000 });
const defaultB = node({ name: '默认乙', model: 'Qwen', requests: 0, memAvail: 8000 });
for (const taskTier of [0, 1, 2, 3]) {
  assert.equal(pickNode([defaultA, defaultB], [], taskTier).name, '默认乙',
    'default cluster ignores taskTier=' + taskTier);
}
assert.equal(pickNode([defaultA, defaultB]).name, '默认乙', 'omitted taskTier keeps the legacy winner');
assert.equal(pickNode([defaultA, defaultB], [], 3).name, pickNode([defaultA, defaultB], [], 0).name);
// routeMode：auto 感知档位，pin1/pin2 档位盲（实验纯净性）
const selfWeak = node({ name: '本机弱档', isSelf: true, model: 'Lite', requests: 0, memAvail: 500, modelTier: 1 });
assert.equal(pickRoute([selfWeak, strongIdle], 'auto', true, [], 3).name, '强档闲',
  'auto sends the heavy task to the strong peer');
assert.equal(pickRoute([selfWeak, strongIdle], 'pin1', true, [], 3).isSelf, true,
  'pin1 keeps the heavy task on the weak hub (tier-blind)');
assert.equal(pickRoute([defaultA, defaultB], 'pin2', true, [], 1).name, '默认乙', 'pin2 stays tier-blind');
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
console.log('PASS: pickNode idle/memory/self, busy still scheduled, inflight dispatch accounting');
