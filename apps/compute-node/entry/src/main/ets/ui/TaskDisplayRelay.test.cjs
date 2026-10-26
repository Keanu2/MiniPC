// node TaskDisplayRelay.test.cjs
// A worker's task card must reach its final state even when a send fails or never settles.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
function load(file, requires = {}, fast = true) {
  const box = { exports: {}, require: (n) => requires[n] || {}, Date, Map, Set, Math, Number, Array, JSON, Promise, String, Error, RegExp, Uint8Array,
    setTimeout: (fn, ms) => setTimeout(fn, fast ? Math.max(1, Math.floor(ms / 200)) : ms), clearTimeout };
  vm.runInNewContext(transpile(__dirname + '/' + file), box);
  return box.exports;
}
const util = { TextEncoder: class { encodeInto(s) { return Buffer.from(s); } } };
const proto = load('../protocol/ChatProtocol.ets', { '@kit.ArkTS': { util }, '@kit.PerformanceAnalysisKit': { hilog: {} } });
const { TaskBoard } = load('TaskBoard.ets', { '../protocol/ChatProtocol': proto });
const { TaskDisplayRelay } = load('TaskDisplayRelay.ets', { '../protocol/ChatProtocol': proto, './TaskBoard': {} });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const D1 = '算力设备1', D2 = '算力设备2';
const t0 = Date.now() - 100000;
const snap = (rev, phase, kids, end = 0, answer = '') => ({ id: 'tk1', title: '查北京天气', phase, revision: rev, startedAt: t0, endedAt: end, answer,
  subtasks: kids.map((k, i) => ({ id: 's' + (i + 1), title: 'T' + (i + 1), device: k[0], phase: k[1], detail: '', result: k[2], startedAt: t0, endedAt: k[3] })) });
const running = (rev) => snap(rev, 'running', [['', 'queued'], ['', 'queued']]);
const finished = (rev) => snap(rev, 'done', [[D2, 'done', 'a', t0 + 5], [D1, 'done', 'b', t0 + 9]], t0 + 20, '最终回答');

async function scenario(sender) {
  const hub = new TaskBoard(), worker = new TaskBoard(), seen = [];
  const relay = new TaskDisplayRelay(async (message, epoch) => {
    const result = await sender(message, seen.length);
    seen.push(message.task.revision + ':' + message.task.phase + ':' + result);
    if (result) worker.accept(JSON.parse(JSON.stringify(message.task)), 9, 'o', D1);
    return result;
  });
  const logs = [];
  relay.log = (text) => logs.push(text);
  const step = async (task, wait = 20) => {
    hub.accept(task, 4, '聊天设备1', D1);
    relay.publish(hub.views(), [9], ['4:tk1']);
    await sleep(wait);
  };
  await step(running(1));
  relay.bind('4:tk1', 's1', {}, 9);
  relay.publish(hub.views(), [9], ['4:tk1']);
  await step(snap(2, 'running', [[D2, 'running'], [D1, 'running']]));
  await step(finished(3), 5);
  return { worker, seen, logs, relay, hub };
}

(async () => {
  // A single Agent task also follows its model calls to the actual worker.
  const singleHub=new TaskBoard(),singleWorker=new TaskBoard();
  const singleRelay=new TaskDisplayRelay(async message=>{
    assert(proto.validTaskSnapshot(message.task));
    singleWorker.accept(JSON.parse(JSON.stringify(message.task)),9,'聊天设备1',D1);return true;
  });
  const request={};singleRelay.bind('4:one','main',request,9);
  const single={id:'one',title:'原始用户请求',input:'完整原始输入',revision:1,phase:'running',startedAt:t0,endedAt:0,answer:'',subtasks:[]};
  singleHub.accept(single,4,'聊天设备1',D1);singleRelay.publish(singleHub.views(),[9],['4:one']);await sleep(10);
  assert.equal(singleWorker.views()[0].phase,'running');assert.equal(singleWorker.views()[0].id,request.taskId);
  singleHub.accept({...single,revision:2,phase:'done',endedAt:t0+50,answer:'调用工具后的最终答案',activity:'工具输入与返回内容'},4,'聊天设备1',D1);
  singleRelay.publish(singleHub.views(),[9],['4:one']);await sleep(10);
  assert.equal(singleWorker.views()[0].answer,'调用工具后的最终答案');assert.equal(singleWorker.views()[0].input,single.input);
  assert.equal(singleWorker.views()[0].activity,'工具输入与返回内容');assert.equal(singleWorker.views()[0].phase,'done');
  // Healthy path.
  let r = await scenario(async () => true);
  assert.equal(r.worker.views()[0].phase, 'done');

  // The final snapshot's send fails once and no later dashboard event arrives: the retry timer delivers it.
  let finalFailures = 0;
  r = await scenario(async (message) => {
    if (message.task.phase === 'done' && finalFailures++ < 2) return false;
    return true;
  });
  await sleep(150);
  assert.equal(r.worker.views()[0].phase, 'done', 'a failed final send is retried without waiting for another event');
  assert(r.logs.length >= 1);

  // A send that never settles must not block later snapshots forever.
  let hung = false;
  r = await scenario((message) => {
    if (!hung) { hung = true; return new Promise(() => {}); }
    return Promise.resolve(true);
  });
  await sleep(150);
  assert.equal(r.worker.views()[0].phase, 'done', 'a hung send is abandoned after a timeout');

  // A group that stops receiving updates is marked unknown instead of running forever, and can be revived.
  const board = new TaskBoard();
  const start = Date.now();
  assert(board.accept(running(1), 4, 'o', D1));
  const realNow = Date.now;
  Date.now = () => start + 601000;
  try {
    const stale = board.views()[0];
    assert.equal(stale.phase, 'unknown');
    assert(stale.endedAt > 0);
  } finally { Date.now = realNow; }
  console.log('PASS task display survives failed and hung sends; quiet groups are not left running');
})().catch((error) => { console.error(error); process.exit(1); });
