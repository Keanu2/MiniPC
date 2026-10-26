// node InferenceRelay.test.cjs [path/to/typescript/lib/typescript.js]
// Executes the real DevicePool, ComputeRouter and InferenceRelay sources with controlled senders.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(relative, requires = {}) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Map, Math, Number, String, Promise, JSON, Array,
    require: (name) => requires[name] || {} };
  vm.runInNewContext(transpile(path.join(__dirname, relative)), context);
  return mod.exports;
}
const pool = load('../cluster/DevicePool.ets');
const routerModule = load('../cluster/ComputeRouter.ets');
const reuseModule = load('./SessionReuse.ets');
const taskRules = load('../cluster/TaskRules.ets');
const { InferenceRelay, RelayEvents } = load('./InferenceRelay.ets', {
  './SessionReuse': reuseModule,
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
  '../cluster/ComputeRouter': routerModule,
  '../cluster/DevicePool': pool,
  '../cluster/TaskRules': taskRules
});
const json = (value) => JSON.parse(JSON.stringify(value));

function node(partial) { return Object.assign(new pool.PoolNode(), partial); }
function harness(initial, options = {}) {
  const nodes = initial;
  const sent = [], localHandled = [], events = [];
  const router = new routerModule.ComputeRouter();
  const handlers = new RelayEvents();
  handlers.begin = (id, chat, worker) => events.push(['begin', id, chat, worker]);
  handlers.delta = (id, chat, text) => events.push(['delta', id, chat, text]);
  handlers.metrics = (id, chat, metrics) => events.push(['metrics', id, chat, metrics]);
  handlers.end = (id, chat, text, failed) => events.push(['end', id, chat, text, failed]);
  if(options.forward)handlers.forward=options.forward;
  // Like Index.poolNodes(): a worker's in-flight count comes from the hub's own hand-off ledger.
  const snapshot = () => nodes.map((item) => item.isSelf ? item : Object.assign(item, { inflight: Math.max(item.sampled || 0, router.workerLoad(item.epoch, 0)) }));
  const relay = new InferenceRelay(router, snapshot, () => [5], { handle: (m, e) => localHandled.push([m.type, m.requestId, e]) },
    (message, epoch) => { sent.push([json(message), epoch]); return Promise.resolve(options.sendResult !== false); }, handlers);
  const to = (epoch, type) => sent.filter((entry) => entry[1] === epoch && (type === undefined || entry[0].type === type)).map((entry) => entry[0]);
  return { relay, router, nodes, sent, localHandled, events, to };
}
const request = (id) => ({ type: 'infer.request', version: 2, requestId: id, messages: [{ role: 'developer', content: 'sys' }, { role: 'user', content: 'q' }],
  maxOutputTokens: 512, deadlineBudgetMs: 170000, promptFormat: 'loop-react-split-v1' });
// 代码围栏 → 复杂档 2；生成类标记 → 常规 2；短净文本 → 简单档 1（预算不参与定档）
const heavyRequest = (id) => ({ type: 'infer.request', version: 2, requestId: id,
  messages: [{ role: 'user', content: '```python\nprint(1)\n```' }], maxOutputTokens: 512, deadlineBudgetMs: 170000 });
const midRequest = (id) => ({ type: 'infer.request', version: 2, requestId: id,
  messages: [{ role: 'user', content: '帮我写一首诗' }], maxOutputTokens: 512, deadlineBudgetMs: 170000 });
const lightRequest = (id) => ({ type: 'infer.request', version: 2, requestId: id,
  messages: [{ role: 'user', content: 'hi' }], maxOutputTokens: 128, deadlineBudgetMs: 170000 });
const self = (extra) => node({ epoch: 0, label: '算力设备1', isSelf: true, ready: true, inflight: 0, memAvail: 100, ...extra });
const worker = (extra) => node({ epoch: 7, label: '算力设备2', ready: true, inflight: 0, memAvail: 100, ...extra });
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const tick = () => new Promise((resolve) => setImmediate(resolve));

test('Agent split capacity counts text-capable devices only, including model switches and busy nodes', () => {
  const a = self({ capabilities: ['text'] });
  const b = worker({ capabilities: ['vision'] });
  const h = harness([a, b]);
  assert.deepEqual(json(h.relay.load()), { idle: 1, total: 1 });
  b.capabilities = ['text'];
  assert.deepEqual(json(h.relay.load()), { idle: 2, total: 2 });
  b.sampled = 1;
  assert.deepEqual(json(h.relay.load()), { idle: 1, total: 2 });
  a.capabilities = ['vision'];
  assert.deepEqual(json(h.relay.load()), { idle: 0, total: 1 });
});

test('DevicePool: idle only, more memory first, hub wins ties, load counts ready nodes', () => {
  assert.equal(pool.pickIdle([]), null);
  assert.equal(pool.pickIdle([self({ inflight: 1 }), worker({ ready: false })]), null);
  assert.equal(pool.pickIdle([self({ memAvail: 10 }), worker({ memAvail: 20 })]).epoch, 7);
  assert.equal(pool.pickIdle([worker(), self()]).isSelf, true);
  const load = pool.clusterLoad([self({ inflight: 2 }), worker(), worker({ epoch: 8, ready: false })]);
  assert.deepEqual(json(load), { idle: 1, total: 2 });
});
test('DevicePool: pickIdleFor routes by tier closeness, busy strong nodes downgrade', () => {
  // 贴近：简单任务在 [hub t2, worker t1] 里选 worker
  assert.equal(pool.pickIdleFor([self({ modelTier: 2 }), worker({ modelTier: 1 })], ['text'], 1).epoch, 7);
  // 贴近决胜：[t1 闲, t2 忙, t2 闲] taskTier 2 → 空闲的 t2（忙的先出局）
  const tier2 = pool.pickIdleFor([worker({ modelTier: 1 }),
    worker({ epoch: 8, modelTier: 2, inflight: 1 }), worker({ epoch: 9, modelTier: 2 })], ['text'], 2);
  assert.equal(tier2.epoch, 9);
  // 降档：强节点忙，空闲弱档接客；全忙才 null（档位不改变 BUSY 语义）
  assert.equal(pool.pickIdleFor([self({ modelTier: 2, inflight: 1 }), worker({ modelTier: 1 })], ['text'], 2).epoch, 7);
  assert.equal(pool.pickIdleFor([self({ modelTier: 2, inflight: 1 }), worker({ modelTier: 1, inflight: 1 })], ['text'], 2), null);
  // 零回归：全默认档位 + 任意 taskTier 与不传第三参同赢家（内存平手 → 本机）
  assert.equal(pool.pickIdleFor([self(), worker()], ['text'], 2).isSelf, true);
  assert.equal(pool.pickIdleFor([self(), worker()], ['text']).isSelf, true);
  assert.equal(pool.pickIdleFor([self(), worker({ memAvail: 200 })], ['text'], 1).epoch, 7,
    'tier tie still falls back to memory');
});
test('a light infer request goes to the closer-tier node instead of the idle hub', () => {
  const h = harness([self({ modelTier: 2 }), worker({ epoch: 8, modelTier: 1 })]);
  h.relay.handleFromChat(lightRequest('r1'), 5);
  assert.equal(h.to(8, 'infer.request').length, 1, 'tier-1 task prefers the tier-1 worker');
  assert.equal(h.localHandled.length, 0);
});
test('a tier-2 infer request prefers the closer strong node', () => {
  const h = harness([worker({ modelTier: 1 }), worker({ epoch: 8, modelTier: 2 })]);
  h.relay.handleFromChat(midRequest('r1'), 5);
  assert.equal(h.to(8, 'infer.request').length, 1, 't2 is closer to a tier-2 task than t1');
});
test('a heavy infer request downgrades when every strong node is busy', () => {
  const h = harness([self({ inflight: 1, modelTier: 2 }), worker({ sampled: 1, modelTier: 2 }),
    worker({ epoch: 8, label: '算力设备3', modelTier: 1 })]);
  h.relay.handleFromChat(heavyRequest('r1'), 5);
  assert.equal(h.to(8, 'infer.request').length, 1, 'the idle tier-1 worker takes the downgraded complex task');
  assert.equal(h.to(7, 'infer.request').length, 0);
});
test('busy text nodes still accept concurrent work and use tier to break equal load', () => {
  const h = harness([self({ inflight: 1, modelTier: 2 }), worker({ sampled: 1, modelTier: 1 })]);
  h.relay.handleFromChat(heavyRequest('r1'), 5);
  assert.equal(h.to(5, 'infer.error').length, 0);
  assert.deepEqual(h.localHandled, [['infer.request', 'r1', 5]]);
});
test('a default-tier pool keeps the hub for a heavy request (zero regression)', () => {
  const h = harness([self(), worker()]);
  h.relay.handleFromChat(heavyRequest('r1'), 5);
  assert.deepEqual(h.localHandled, [['infer.request', 'r1', 5]]);
});
test('idle hub runs the request itself', () => {
  const h = harness([self(), worker({ memAvail: 50 })]);
  h.relay.handleFromChat(request('r1'), 5);
  assert.deepEqual(h.localHandled, [['infer.request', 'r1', 5]]);
  assert.equal(h.to(7).length, 0);
});
test('forwarded child keeps display identity and original chat source', () => {
  const h=harness([self({inflight:1}),worker()]);
  h.relay.handleFromChat({...request('child'),taskId:'parent',subtaskId:'s2',origin:'聊天设备3'},5);
  const forwarded=h.to(7,'infer.request')[0];
  assert.equal(forwarded.taskId,'parent');assert.equal(forwarded.subtaskId,'s2');assert.equal(forwarded.origin,'聊天设备3');
});

test('legacy display context is attached after the card observer and before forwarding',()=>{
  let observed=false;
  const h=harness([self({inflight:1}),worker()],{forward:(id,chat,worker,copy)=>{
    observed=h.events.some(event=>event[0]==='begin'&&event[1]===id);
    copy.taskId='display_session_parent';copy.subtaskId='s2';
  }});
  const original={...request('legacy'),label:'子任务 2/2'};
  h.relay.handleFromChat(original,5);
  const copy=h.to(7,'infer.request')[0];
  assert(observed);assert.equal(copy.taskId,'display_session_parent');assert.equal(copy.subtaskId,'s2');
  assert.deepEqual(copy.messages,original.messages);assert.equal(original.taskId,undefined);
});
test('busy hub forwards to the idle worker with a hub forwardId and reduced budget', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  assert.equal(h.localHandled.length, 0);
  const forwarded = h.to(7, 'infer.request')[0];
  assert.notEqual(forwarded.requestId, 'r1');
  assert.equal(forwarded.deadlineBudgetMs, 165000);
  assert.equal(forwarded.messages[1].content, 'q');
  assert.equal(forwarded.maxOutputTokens, 512);
  assert.equal(h.events[0][0], 'begin');
});
test('an image request keeps its image across the hub hand-off', () => {
  // 带图 ⇒ 只有声明了 vision 的节点才可选（见 pickIdleFor）
  const h = harness([self({ inflight: 1, capabilities: ['text'] }),
    worker({ capabilities: ['text', 'vision'] })]);
  const image = '/9j/4AAQSkZJRg==';
  h.relay.handleFromChat({ ...request('r1'), image: image }, 5);
  assert.equal(h.to(7, 'infer.request')[0].image, image);
  // 无图请求绝不能带 image 键：undefined 也算键，对端 hasOnly 会判为未知字段并拒收
  const plain = harness([self({ inflight: 1 }), worker()]);
  plain.relay.handleFromChat(request('r2'), 5);
  assert.equal('image' in plain.to(7, 'infer.request')[0], false);
});
test('a vision request is never handed to a text-only worker', () => {
  // hub 忙、worker 只有文本能力：带图请求必须 fail closed，不得转发、不得本地降级
  const h = harness([self({ inflight: 1, capabilities: ['text'] }), worker({ capabilities: ['text'] })]);
  h.relay.handleFromChat({ ...request('r1'), image: '/9j/4AAQSkZJRg==' }, 5);
  assert.equal(h.to(7, 'infer.request').length, 0, 'text-only worker is not chosen for an image');
  assert.equal(h.localHandled.length, 0, 'the text-only hub does not serve it locally either');
  const refusal = h.to(5, 'infer.error')[0];
  assert.equal(refusal.code, 'MODEL_UNAVAILABLE');
  assert.equal(refusal.retryable, false, 'retrying without a capable node is pointless');
});
test('a text request is not handed to a vision-only node', () => {
  const h = harness([self({ inflight: 1, capabilities: ['text'] }), worker({ capabilities: ['vision'] })]);
  h.relay.handleFromChat(request('r1'), 5);
  assert.equal(h.to(7, 'infer.request').length, 0, 'vision-only worker is not chosen for text');
});
test('independent chat origins share a heterogeneous pool and reuse their own completed request while other work stays active',()=>{
  // A vision-only hub leaves both text workers in the forwarding ledger.
  // Client request IDs deliberately collide across chat origins.
  const h=harness([self({capabilities:['vision']}),worker({epoch:7,capabilities:['text']}),worker({epoch:8,capabilities:['text']})]);
  h.relay.handleFromChat(request('same-id'),5);
  h.relay.handleFromChat(request('same-id'),6);
  const first=h.to(7,'infer.request')[0],second=h.to(8,'infer.request')[0];
  assert.ok(first);assert.ok(second);assert.notEqual(first.requestId,second.requestId);
  assert.equal(h.localHandled.length,0);assert.equal(h.router.workerLoad(7,0),1);assert.equal(h.router.workerLoad(8,0),1);
  assert.deepEqual(json(h.relay.load()),{idle:0,total:2});
  h.relay.handleFromWorker({type:'infer.accepted',requestId:first.requestId,state:'generating'},7);
  h.relay.handleFromWorker({type:'infer.accepted',requestId:second.requestId,state:'generating'},8);
  h.relay.handleFromWorker({type:'infer.delta',requestId:first.requestId,seq:1,text:'first answer'},7);
  h.relay.handleFromWorker({type:'infer.done',requestId:first.requestId,lastSeq:1},7);
  assert.equal(h.to(5,'infer.done').length,1);assert.equal(h.to(6,'infer.done').length,0);
  assert.equal(h.router.workerLoad(7,0),0);assert.equal(h.router.workerLoad(8,0),1);
  const image='/9j/4AAQSkZJRg==';
  h.relay.handleFromChat({...request('same-id'),image},5);
  assert.deepEqual(h.localHandled,[['infer.request','same-id',5]],'the vision hub receives the new image request');
  assert.equal(h.to(7,'infer.request').length,1);assert.equal(h.to(8,'infer.request').length,1,'image cannot enter either text worker');
  h.relay.handleFromWorker({type:'infer.delta',requestId:second.requestId,seq:1,text:'second answer'},8);
  h.relay.handleFromWorker({type:'infer.done',requestId:second.requestId,lastSeq:1},8);
  assert.deepEqual(h.to(5,'infer.delta').map(m=>m.text),['first answer']);
  assert.deepEqual(h.to(6,'infer.delta').map(m=>m.text),['second answer']);
  assert.equal(h.to(6,'infer.done').length,1);assert.equal(h.router.workerLoad(8,0),0);
});

test('an idle vision worker accepts an image while two text devices are occupied',()=>{
  const h=harness([self({capabilities:['text'],inflight:1}),worker({epoch:7,capabilities:['text'],sampled:1}),worker({epoch:8,capabilities:['vision']})]);
  const image='/9j/4AAQSkZJRg==';
  h.relay.handleFromChat({...request('image'),image},6);
  assert.equal(h.localHandled.length,0);assert.equal(h.to(7,'infer.request').length,0);
  assert.equal(h.to(8,'infer.request').length,1);assert.equal(h.to(8,'infer.request')[0].image,image);
  assert.equal(h.to(6,'infer.error').length,0);
});

test('the idle hub still serves a vision request itself when it is capable', () => {
  const h = harness([self({ inflight: 0, capabilities: ['text', 'vision'] }), worker()]);
  h.relay.handleFromChat({ ...request('r1'), image: '/9j/4AAQSkZJRg==' }, 5);
  assert.deepEqual(h.localHandled, [['infer.request', 'r1', 5]]);
});
test('one busy worker accepts multiple sessions and keeps separate dispatch identities', () => {
  const h = harness([self({ ready: false }), worker()]);
  h.relay.handleFromChat(request('a'), 5);
  h.relay.handleFromChat(request('b'), 5);
  const sent = h.to(7, 'infer.request');
  assert.equal(sent.length, 2);assert.notEqual(sent[0].requestId,sent[1].requestId);
  assert.equal(h.router.workerLoad(7,0),2);assert.equal(h.to(5,'infer.error').length,0);
  h.relay.handleFromWorker({type:'infer.done',requestId:sent[1].requestId,lastSeq:1},7);
  assert.equal(h.to(5,'infer.done')[0].requestId,'b');assert.equal(h.router.workerLoad(7,0),1);
  h.relay.handleFromChat({type:'infer.cancel',requestId:'a'},5);
  assert.equal(h.to(7,'infer.cancel')[0].requestId,sent[0].requestId);
});

test('parallel routing keeps idle preference, then balances busy nodes by in-flight count',()=>{
  assert.equal(pool.pickAvailable([self({inflight:4}),worker({sampled:0,inflight:2})]).epoch,7);
  assert.equal(pool.pickAvailable([self({inflight:1}),worker({inflight:2})],7).epoch,0);
  assert.equal(pool.pickAvailable([self({inflight:2}),worker({inflight:2})],7).epoch,7);
  assert.equal(pool.pickAvailable([self({inflight:4}),worker()]).epoch,7);
  assert.equal(pool.pickAvailable([self({ready:false}),worker({ready:false})]),null);
});

test('unavailable devices still return retryable refusal',()=>{
  const h=harness([self({ready:false}),worker({ready:false})]);h.relay.handleFromChat(request('a'),5);
  assert.equal(h.to(5,'infer.error')[0].code,'BUSY');assert.equal(h.to(5,'infer.error')[0].retryable,true);
});
test('hub acknowledges admission while worker payload is still in flight, without claiming execution', () => {
  const h = harness([self({ ready: false }), worker()]);
  h.relay.handleFromChat(request('slow-transfer'), 5);
  const forwarded = h.to(7, 'infer.request')[0];
  assert.equal(h.to(5, 'infer.accepted')[0].state, 'queued');
  assert.equal(h.to(5, 'infer.accepted')[0].device, '算力设备2');
  assert.equal(h.router.getByForwardId(forwarded.requestId).accepted, false);
  assert.equal(h.router.workerLoad(7, 0), 1);
  h.relay.handleFromChat(request('second'), 6);
  assert.equal(h.router.workerLoad(7, 0), 2, 'in-flight uploads count before worker acceptance');
  h.relay.handleFromWorker({ type: 'infer.accepted', requestId: forwarded.requestId, state: 'preparing' }, 7);
  assert.equal(h.router.getByForwardId(forwarded.requestId).accepted, true);
  h.relay.handleFromChat({ type: 'infer.cancel', requestId: 'slow-transfer' }, 5);
  assert.equal(h.to(7, 'infer.cancel')[0].requestId, forwarded.requestId);
});

test('worker replies are rewritten to the origin id with payload, seq and hash untouched', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.handleFromWorker({ type: 'infer.accepted', requestId: fid, state: 'preparing' }, 7);
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: fid, seq: 1, text: '你好' }, 7);
  h.relay.handleFromWorker({ type: 'infer.done', requestId: fid, lastSeq: 1, outputUtf8Bytes: 6, outputSha256: 'abc', finishReason: 'stop', source: 'w' }, 7);
  const out = h.to(5).filter((m) => m.type !== 'infer.status');
  assert.deepEqual(out.map((m) => m.type), ['infer.accepted', 'infer.accepted', 'infer.delta', 'infer.done']);
  assert.ok(out.every((m) => m.requestId === 'r1'));
  assert.equal(out[0].device, '算力设备2');
  assert.equal(out[0].state, 'queued');
  assert.deepEqual([out[2].seq, out[2].text], [1, '你好']);
  assert.deepEqual([out[3].lastSeq, out[3].outputUtf8Bytes, out[3].outputSha256, out[3].finishReason], [1, 6, 'abc', 'stop']);
  assert.deepEqual(h.events.slice(-1)[0], ['end', 'r1', 5, '你好', false]);
  assert.equal(h.router.getByForwardId(fid), undefined, 'hand-off released');
});
test('replies for unknown ids or from another device are dropped', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  const before = h.sent.length;
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: 'zzz', seq: 1, text: 'x' }, 7);
  h.relay.handleFromWorker({ type: 'infer.delta', requestId: fid, seq: 1, text: 'x' }, 9);
  assert.equal(h.sent.length, before);
});
test('cancel is forwarded under the forwardId and the CANCELLED reply returns to the chat', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.handleFromChat({ type: 'infer.cancel', requestId: 'r1' }, 5);
  assert.equal(h.to(7, 'infer.cancel')[0].requestId, fid);
  h.relay.handleFromWorker({ type: 'infer.error', requestId: fid, code: 'CANCELLED', message: 'stopped', retryable: false }, 7);
  const error = h.to(5, 'infer.error')[0];
  assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'CANCELLED', false]);
});
test('cancel for a locally run request goes to the local host', () => {
  const h = harness([self(), worker()]);
  h.relay.handleFromChat({ type: 'infer.cancel', requestId: 'mine' }, 5);
  assert.deepEqual(h.localHandled, [['infer.cancel', 'mine', 5]]);
});
test('worker lost before accepted is retryable; after accepted it is not', () => {
  for (const accepted of [false, true]) {
    const h = harness([self({ ready: false }), worker()]);
    h.relay.handleFromChat(request('r1'), 5);
    const fid = h.to(7, 'infer.request')[0].requestId;
    if (accepted) h.relay.handleFromWorker({ type: 'infer.accepted', requestId: fid }, 7);
    h.relay.workerDropped(7);
    const error = h.to(5, 'infer.error')[0];
    assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'WORKER_LOST', !accepted]);
    assert.equal(h.router.getByForwardId(fid), undefined);
  }
});
test('chat drop cancels the remote work and releases the hand-off', () => {
  const h = harness([self({ inflight: 1 }), worker()]);
  h.relay.handleFromChat(request('r1'), 5);
  const fid = h.to(7, 'infer.request')[0].requestId;
  h.relay.chatDropped(5);
  assert.equal(h.to(7, 'infer.cancel')[0].requestId, fid);
  assert.equal(h.router.getByForwardId(fid), undefined);
});
test('failed forward send reports a retryable error and frees the device', async () => {
  const h = harness([self({ inflight: 1 }), worker()], { sendResult: false });
  h.relay.handleFromChat(request('r1'), 5);
  await tick();
  const error = h.to(5, 'infer.error')[0];
  assert.deepEqual([error.requestId, error.code, error.retryable], ['r1', 'WORKER_LOST', true]);
  assert.equal(h.router.workerLoad(7, 0), 0);
});
test('duplicate live request id is refused without a second hand-off', () => {
  const h = harness([self({ inflight: 1 }), worker(), worker({ epoch: 8, label: '算力设备3' })]);
  h.relay.handleFromChat(request('r1'), 5);
  h.relay.handleFromChat(request('r1'), 5);
  assert.equal(h.to(5, 'infer.error')[0].code, 'DUPLICATE_REQUEST');
  assert.equal(h.sent.filter((entry) => entry[0].type === 'infer.request').length, 1);
});
test('infer.status is pushed to chats only when the idle count changes', () => {
  const h = harness([self(), worker()]);
  h.relay.publishLoad();
  h.relay.publishLoad();
  assert.equal(h.to(5, 'infer.status').length, 1);
  assert.deepEqual(h.to(5, 'infer.status')[0].cluster, { idle: 2, total: 2 });
  h.nodes[1].sampled = 1;
  h.relay.publishLoad();
  assert.deepEqual(h.to(5, 'infer.status')[1].cluster, { idle: 1, total: 2 });
});
test('capabilities.get is answered by the local host', () => {
  const h = harness([self(), worker()]);
  h.relay.handleFromChat({ type: 'infer.capabilities.get', requestId: 'cap-1' }, 5);
  assert.deepEqual(h.localHandled, [['infer.capabilities.get', 'cap-1', 5]]);
});
const roundOf = (id, tail) => ({ type: 'infer.request', version: 2, requestId: id, promptFormat: 'loop-react-split-v1',
  messages: [{ role: 'developer', content: 'sys\nCurrent device local datetime: ' + id + '\nTools' },
    { role: 'user', content: 'User task:\nweather\n' + tail }] });
function finishOn(h, epoch) {
  const forwarded = h.to(epoch, 'infer.request');
  const last = forwarded[forwarded.length - 1];
  h.relay.handleFromWorker({ type: 'infer.done', requestId: last.requestId, lastSeq: 1, finishReason: 'stop' }, epoch);
}
test('affinity keeps the next round of a run on the device that holds its session, only when idle', () => {
  const h = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  h.relay.setAffinity(() => true);
  h.relay.handleFromChat(roundOf('r1', 'Control: go'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1, 'first round goes to the larger-memory worker');
  finishOn(h, 7);
  h.nodes[0].memAvail = 900; // default choice would now be the hub
  h.relay.handleFromChat(roundOf('r2', 'Action: a\nObservation: b\nControl: go'), 5);
  assert.equal(h.to(7, 'infer.request').length, 2, 'same run stays on the worker that has its session');
  finishOn(h, 7);
  h.relay.handleFromChat(roundOf('r3', 'Action: a\nObservation: b\nControl: go'), 5);
  h.nodes[1].sampled = 1; // the preferred worker is busy now
  h.relay.handleFromChat({ ...roundOf('r4', 'Action: c\nObservation: d\nControl: go') }, 5);
  assert.equal(h.localHandled.filter((entry) => entry[1] === 'r4').length, 1, 'a busy preferred device is not waited for');
  const other = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  other.relay.setAffinity(() => true);
  other.relay.handleFromChat(roundOf('x1', 'Control: go'), 5);
  finishOn(other, 7);
  other.nodes[0].memAvail = 900;
  other.relay.handleFromChat({ ...roundOf('x2', 'Control: go'), messages: [{ role: 'developer', content: 'sys\nTools' },
    { role: 'user', content: 'User task:\nsomething else\nControl: go' }] }, 5);
  assert.equal(other.localHandled.filter((entry) => entry[1] === 'x2').length, 1, 'a different run is placed normally');
});
test('affinity is off by default and then placement is unchanged', () => {
  const h = harness([self({ memAvail: 100 }), worker({ memAvail: 200 })]);
  h.relay.handleFromChat(roundOf('r1', 'Control: go'), 5);
  finishOn(h, 7);
  h.nodes[0].memAvail = 900;
  h.relay.handleFromChat(roundOf('r2', 'Action: a\nObservation: b\nControl: go'), 5);
  assert.equal(h.localHandled.filter((entry) => entry[1] === 'r2').length, 1);
});
test('pickIdle prefers the given epoch only while it is idle', () => {
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], 7).epoch, 7);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1, inflight: 1 })], 7).epoch, 0);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], 99).epoch, 0);
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })]).epoch, 0);
});
const trio = (selfBusy = true) => harness([self({ memAvail: 1, inflight: selfBusy ? 1 : 0 }), worker({ memAvail: 200 }), worker({ epoch: 8, label: '算力设备3', memAvail: 100 })]);
const errorsToChat = (h) => h.sent.filter((entry) => entry[1] === 5 && entry[0].type === 'infer.error').map((entry) => entry[0]);
test('a worker lost mid-request: the request is re-issued to another idle device, the requester sees no error', () => {
  const h = trio();
  h.relay.handleFromChat(request('r1'), 5);
  const first = h.to(7, 'infer.request')[0];
  h.relay.handleFromWorker({ type: 'infer.accepted', requestId: first.requestId, state: 'running' }, 7);
  h.relay.workerDropped(7);
  assert.equal(errorsToChat(h).length, 0);
  const second = h.to(8, 'infer.request');
  assert.equal(second.length, 1);
  assert.notEqual(second[0].requestId, first.requestId, 'a new hand-off id');
  assert.deepEqual(json(h.events.filter((e) => e[0] === 'end')), [['end', 'r1', 5, '', true]], 'the lost attempt closes its card');
  h.relay.handleFromWorker({ type: 'infer.done', requestId: second[0].requestId, lastSeq: 1, finishReason: 'stop' }, 8);
  assert.equal(h.sent.filter((entry) => entry[0].type === 'infer.done' && entry[0].requestId === 'r1').length, 1, 'the requester gets the answer under its own id');
});
test('a worker that cancels by itself is retried elsewhere; a requested cancel is not', () => {
  const h = trio();
  h.relay.handleFromChat(request('r1'), 5);
  const first = h.to(7, 'infer.request')[0];
  h.relay.handleFromWorker({ type: 'infer.error', requestId: first.requestId, code: 'CANCELLED', message: 'x', retryable: false }, 7);
  assert.equal(errorsToChat(h).length, 0);
  assert.equal(h.to(8, 'infer.request').length, 1);
  const b = trio();
  b.relay.handleFromChat(request('r2'), 5);
  const sent = b.to(7, 'infer.request')[0];
  b.relay.handleFromChat({ type: 'infer.cancel', version: 2, requestId: 'r2' }, 5);
  b.relay.handleFromWorker({ type: 'infer.error', requestId: sent.requestId, code: 'CANCELLED', message: 'x', retryable: false }, 7);
  assert.equal(errorsToChat(b).length, 1, 'cancel asked by the requester is reported, not retried');
  assert.equal(b.to(8, 'infer.request').length, 0);
});
test('no re-issue after output was delivered, without a ready untried device, or beyond the attempt limit', () => {
  const partial = trio();
  partial.relay.handleFromChat(request('p1'), 5);
  const sent = partial.to(7, 'infer.request')[0];
  partial.relay.handleFromWorker({ type: 'infer.delta', requestId: sent.requestId, seq: 1, text: 'abc' }, 7);
  partial.relay.workerDropped(7);
  assert.equal(errorsToChat(partial).length, 1);
  assert.equal(partial.to(8, 'infer.request').length, 0);
  const none = harness([self({ ready: false }), worker()]);
  none.relay.handleFromChat(request('n1'), 5);
  none.relay.workerDropped(7);
  assert.equal(errorsToChat(none).length, 1, 'only device is gone: the failure is reported as before');
  const many = harness([self({ memAvail: 1, inflight: 1 }), worker({ memAvail: 300 }), worker({ epoch: 8, label: 'b', memAvail: 200 }),
    worker({ epoch: 9, label: 'c', memAvail: 100 }), worker({ epoch: 10, label: 'd', memAvail: 50 })]);
  many.relay.handleFromChat(request('m1'), 5);
  many.relay.workerDropped(7);
  many.relay.workerDropped(8);
  many.relay.workerDropped(9);
  assert.equal(many.to(9, 'infer.request').length, 1);
  assert.equal(many.to(10, 'infer.request').length, 0, 'at most two re-issues');
  assert.equal(errorsToChat(many).length, 1);
});
test('a lost worker with the hub idle is re-issued on the hub itself', () => {
  const h = harness([self({ memAvail: 1 }), worker({ memAvail: 200 })]);
  h.relay.handleFromChat(request('h1'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1);
  h.relay.workerDropped(7);
  assert.equal(errorsToChat(h).length, 0);
  assert.deepEqual(h.localHandled.map((e) => e[1]), ['h1']);
});
const speedModule = load('../cluster/DeviceSpeed.ets');
test('DeviceSpeed: smoothed ms per 1k chars; failed and tiny samples ignored', () => {
  const s = new speedModule.DeviceSpeed();
  assert.equal(s.cost(7), -1);
  s.record(7, 30000, 10000, false);
  assert.equal(s.cost(7), 3000);
  s.record(7, 100, 10, false);
  s.record(7, 90000, 10000, true);
  assert.equal(s.cost(7), 3000);
  s.record(7, 20000, 10000, false);
  assert.ok(s.cost(7) < 3000 && s.cost(7) > 2000, 'moves toward the new sample, not all the way');
});
test('pickIdle prefers the measured faster idle device, whichever it is', () => {
  const cost = (table) => (epoch) => table[epoch] === undefined ? -1 : table[epoch];
  assert.equal(pool.pickIdle([self({ memAvail: 900 }), worker({ memAvail: 1 })], -1, cost({ 0: 3000, 7: 1500 })).epoch, 7);
  assert.equal(pool.pickIdle([self({ memAvail: 1 }), worker({ memAvail: 900 })], -1, cost({ 0: 1500, 7: 3000 })).epoch, 0);
  assert.equal(pool.pickIdle([self(), worker({ inflight: 1 })], -1, cost({ 0: 3000, 7: 1500 })).epoch, 0, 'a slower device still works while the faster one is busy');
  assert.equal(pool.pickIdle([self(), worker()], -1, cost({ 0: 1500 })).epoch, 7, 'unmeasured devices are tried so they get measured');
  assert.equal(pool.pickIdle([self({ memAvail: 10 }), worker({ memAvail: 20 })], -1, cost({ 0: 1000, 7: 1100 })).epoch, 7, 'near-equal speed falls back to memory');
  assert.equal(pool.pickIdle([self(), worker()], -1, cost({ 0: 1000, 7: 1100 })).isSelf, true, 'then to the hub');
});
test('relay uses the supplied speed table for placement and for re-issue', () => {
  const h = harness([self({ memAvail: 900 }), worker({ memAvail: 1 })]);
  h.relay.setSpeed((epoch) => epoch === 7 ? 1000 : 2500);
  h.relay.handleFromChat(request('s1'), 5);
  assert.equal(h.to(7, 'infer.request').length, 1);
  assert.equal(h.localHandled.length, 0);
  const r = trio(false);
  r.relay.setSpeed((epoch) => ({ 0: 3000, 7: 1000, 8: 1500 })[epoch]);
  r.relay.handleFromChat(request('s2'), 5);
  r.relay.workerDropped(7);
  assert.equal(r.to(8, 'infer.request').length, 1, 're-issue goes to the faster remaining device, not the slower hub');
});
test('remote streaming mode and final engine telemetry survive forwarding and task observers',()=>{
  const h=harness([self({ready:false}),worker()]);h.relay.handleFromChat(lightRequest('timed'),5);
  const forward=h.to(7,'infer.request')[0];assert.ok(forward);
  const first={streaming:true},last={streaming:true,prefillMs:123.4,completionTokens:10};
  h.relay.handleFromWorker({type:'infer.delta',requestId:forward.requestId,seq:1,text:'output',metrics:first},7);
  h.relay.handleFromWorker({type:'infer.done',requestId:forward.requestId,lastSeq:1,metrics:last},7);
  assert.deepEqual(h.to(5,'infer.delta')[0].metrics,first);assert.deepEqual(h.to(5,'infer.done')[0].metrics,last);
  assert.equal(h.events.filter(e=>e[0]==='metrics').length,2);
  assert.deepEqual(json(h.events.filter(e=>e[0]==='metrics').at(-1)[3]),last);
});

(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' relay/pool tests passed');
})();
