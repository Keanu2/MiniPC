// Exercise real Host + LocalChat + Relay with controlled native callbacks; no device/build required.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const crypto = require('node:crypto');
const {transpile} = require('../../../../../../../tests/ets-harness.cjs');
function load(file, imports = {}) {
  const box = {exports: {}, Error, Map, Array, Promise, Date, ArrayBuffer, setInterval: () => 1,
    clearInterval() {}, require: name => imports[name] || {}};
  vm.runInNewContext(transpile(path.resolve(__dirname, file)), box);
  return box.exports;
}
const logger = {'@kit.PerformanceAnalysisKit': {hilog: {info() {}, warn() {}}}};
const wire = load('InferenceWire.ets', {'@kit.ArkTS': {util: {TextEncoder: class {
  encodeInto(text) {return Buffer.from(text);}
}}}});
const pool = load('../cluster/DevicePool.ets');
const routerModule = load('../cluster/ComputeRouter.ets');
const reuse = load('SessionReuse.ets');
const taskRules = load('../cluster/TaskRules.ets');
const repair = load('Utf8Repair.ets');
const registry = {readyModelDirs:()=>['Qwen2.5-7B-Instruct-Q4_N_0'],
 selectModelDir:()=> 'Qwen2.5-7B-Instruct-Q4_N_0', modelRequestType:()=> 'qwen2', manifestTier:()=>2};
const {InferenceRelay, RelayEvents} = load('InferenceRelay.ets', {...logger,
  '../cluster/ComputeRouter': routerModule, '../cluster/DevicePool': pool, '../cluster/TaskRules': taskRules, './SessionReuse': reuse});
const {InferenceHost, InferCardHooks} = load('InferenceHost.ets', {...logger,
  './InferenceWire': wire, './Utf8Repair': repair, './QwenVlManager': {QwenVlManager:{getInstance:()=>({isBusy:()=>false,unloadIfIdle(){}})}}});
const request = (id, prompt = '问题') => ({type: 'infer.request', version: 2, requestId: id,
  prompt, maxOutputTokens: 512, deadlineBudgetMs: 170000});
const flush = async () => {for (let i = 0; i < 8; i++) await Promise.resolve();};
function fixture(options = {}) {
  const starts = [], cancels = [], events = [], cards = [], sent = [];
  let next = 0;
  const native = {start(_model, json) {
    const id = ++next; starts.push({id, request: JSON.parse(json)});
    if (options.throwAt === id) throw new Error('native start failed');
    return options.failAt === id ? 0 : id;
  }, cancel(id) {cancels.push(id);}, complete() {}, takeEvents() {return events.splice(0);}, closeSession() {}};
  const {LocalChat} = load('LocalChat.ets', {
    './OutputSettings': {outputSettings:()=>({streaming:options.streaming!==false})},
    ...logger, './ModelRegistry': registry, '../cluster/TaskRules': taskRules, './Utf8Repair': repair, './SessionReuse': reuse, 'libgewu_probe.so': {default: native},
    '@kit.CoreFileKit': {fileIo: {OpenMode: {READ_ONLY: 0}, accessSync: () => false,
      openSync: () => ({fd: 1}), readSync: () => 1, closeSync() {}}}
  });
  const model = new LocalChat('/files');
  const hooks = new InferCardHooks();
  hooks.begin = (...args) => cards.push(['begin', ...args]);
  hooks.delta = (...args) => cards.push(['delta', ...args]);
  hooks.end = (...args) => cards.push(['end', ...args]);
  const send = (message, epoch) => {
    sent.push([message, epoch]);
    return options.send ? options.send(message, epoch) : Promise.resolve(true);
  };
  const host = new InferenceHost(model, send, hooks);
  host.setDeviceProvider(() => '算力设备1');
  const router = new routerModule.ComputeRouter();
  const nodes = () => [Object.assign(new pool.PoolNode(), {epoch: 0, isSelf: true, ready: true,
    inflight: Math.max(model.activeCount(), host.activeCount()), label: '算力设备1'})];
  const relay = new InferenceRelay(router, nodes, () => [7, 8], host, send, new RelayEvents());
  const emit = (id, event, payload) => events.push(JSON.stringify({id: String(id), event, payload}));
  const response = (id, text) => emit(id, 'response', JSON.stringify({message: {content: text}, finish_reason: 'stop'}));
  const end = id => emit(id, 'end', 'closed');
  const poll = () => model.consumeEvents();
  const messages = (epoch, id, type) => sent.filter(([m, e]) => e === epoch && m.requestId === id && (!type || m.type === type)).map(([m]) => m);
  return {host, model, relay, starts, cancels, cards, sent, emit, response, end, poll, messages};
}
const tests = [];
const test = (name, body) => tests.push([name, body]);
test('two requests reach native before either completes; reverse completion preserves output and hashes', () => {
  const h = fixture();
  h.relay.handleFromChat(request('same', '甲的问题'), 7);
  h.relay.handleFromChat(request('same', '乙的问题'), 8);
  assert.equal(h.starts.length, 2);assert.equal(h.model.activeCount(), 2);assert.equal(h.host.activeCount(), 2);
  assert.equal(h.starts[0].request.messages[0].content, '甲的问题');
  assert.equal(h.starts[1].request.messages[0].content, '乙的问题');
  const first = h.starts[0].id, second = h.starts[1].id;
  const a = Array.from({length: 500}, (_, i) => String.fromCharCode(0x4e00 + i)).join(''), b = '乙的回答';
  h.response(second, b);h.end(second);h.poll();assert.equal(h.host.activeCount(), 1);
  h.response(first, a);h.end(first);h.poll();assert.equal(h.host.activeCount(), 0);
  for (const [epoch, expected] of [[7, a], [8, b]]) {
    const deltas = h.messages(epoch, 'same', 'infer.delta');
    assert.equal(deltas.map(m => m.text).join(''), expected);
    assert.deepEqual(deltas.map(m => m.seq), deltas.map((_, i) => i + 1));
    const done = h.messages(epoch, 'same', 'infer.done');assert.equal(done.length, 1);
    assert.equal(done[0].lastSeq, deltas.length);
    assert.equal(done[0].outputUtf8Bytes, Buffer.byteLength(expected));
    assert.equal(done[0].outputSha256, crypto.createHash('sha256').update(expected).digest('hex'));
    assert.equal(h.messages(epoch, 'same', 'infer.error').length, 0);
  }
  assert.equal(h.cards.filter(c => c[0] === 'end').length, 2);
});
test('two different requests from one connection execute concurrently too', () => {
  const h = fixture();h.relay.handleFromChat(request('a'), 7);h.relay.handleFromChat(request('b'), 7);
  assert.equal(h.starts.length, 2);assert.equal(h.host.activeCount(), 2);
  for (const item of h.starts) {h.response(item.id, String(item.id));h.end(item.id);}h.poll();
  assert.equal(h.messages(7, 'a', 'infer.done').length, 1);assert.equal(h.messages(7, 'b', 'infer.done').length, 1);
});
test('cancel is scoped to connection and request, suppresses late success, and leaves the other session running', () => {
  const h = fixture();h.host.handle(request('same'), 7);h.host.handle(request('same'), 8);
  h.host.handle({type: 'infer.cancel', requestId: 'same'}, 9);assert.equal(h.cancels.length, 0);
  h.host.handle({type: 'infer.cancel', requestId: 'same'}, 7);
  h.host.handle({type: 'infer.cancel', requestId: 'same'}, 7);
  assert.deepEqual(h.cancels, [h.starts[0].id]);
  h.response(h.starts[0].id, 'late cancelled answer');h.end(h.starts[0].id);
  h.response(h.starts[1].id, '正常回答');h.end(h.starts[1].id);h.poll();
  assert.equal(h.messages(7, 'same', 'infer.delta').length, 0);
  assert.equal(h.messages(7, 'same', 'infer.error')[0].code, 'CANCELLED');
  assert.equal(h.messages(8, 'same', 'infer.done').length, 1);assert.equal(h.host.isActive(), false);
});
test('disconnect cancels every request of that connection and no requests belonging to another', () => {
  const h = fixture();h.host.handle(request('a'), 7);h.host.handle(request('b'), 7);h.host.handle(request('c'), 8);
  h.host.peerDropped(7);assert.deepEqual(h.cancels, h.starts.slice(0, 2).map(x => x.id));
  const before = h.sent.filter(([, epoch]) => epoch === 7).length;
  for (const item of h.starts) {h.response(item.id, '回答');h.end(item.id);}h.poll();
  assert.equal(h.sent.filter(([, epoch]) => epoch === 7).length, before);
  assert.equal(h.messages(8, 'c', 'infer.done').length, 1);assert.equal(h.host.activeCount(), 0);
  assert.equal(h.cards.filter(c => c[0] === 'end' && c[4] === true).length, 2);
});
test('duplicate local requests are refused before a second native submission, without closing the first card', () => {
  const h = fixture();h.relay.handleFromChat(request('a'), 7);h.relay.handleFromChat(request('a'), 7);
  assert.equal(h.starts.length, 1);assert.equal(h.cards.filter(c => c[0] === 'end').length, 0);
  assert.equal(h.messages(7, 'a', 'infer.error')[0].code, 'DUPLICATE_REQUEST');assert.equal(h.host.activeCount(), 1);
});
test('a native start failure releases only its request state and card', () => {
  for (const option of [{failAt: 2}, {throwAt: 2}]) {
    const h = fixture(option);h.host.handle(request('a'), 7);h.host.handle(request('b'), 7);
    assert.equal(h.host.activeCount(), 1);assert.equal(h.model.activeCount(), 1);
    assert.equal(h.messages(7, 'b', 'infer.error')[0].code, 'MODEL_EXECUTION_FAILED');
    assert.deepEqual(h.cards.filter(c => c[0] === 'end').map(c => c.slice(1)), [['b', 7, '', true]]);
    h.response(h.starts[0].id, '成功');h.end(h.starts[0].id);h.poll();assert.equal(h.messages(7, 'a', 'infer.done').length, 1);
  }
});
test('late callbacks and delayed send failures cannot cancel a replacement using the same wire id', async () => {
  let finishSend;
  const deferred = new Promise(resolve => {finishSend = resolve;});
  let delayed = false;
  const h = fixture({send: m => {if (m.type === 'infer.delta' && !delayed) {delayed = true;return deferred;}return Promise.resolve(true);}});
  h.host.handle(request('a'), 7);const oldCallback = h.model.jobs[0].callback;
  h.response(h.starts[0].id, '旧回答');h.end(h.starts[0].id);h.poll();h.host.handle(request('a'), 7);
  const before = h.sent.length;oldCallback({kind: 'delta', text: 'stale'});oldCallback({kind: 'done', text: '', error: 'stale'});
  finishSend(false);await flush();assert.equal(h.sent.length, before);assert.deepEqual(h.cancels, []);
  h.response(h.starts[1].id, '新回答');h.end(h.starts[1].id);h.poll();assert.equal(h.messages(7, 'a', 'infer.done').length, 2);
});
test('failed acceptance cancels only its native request; late delta failure cannot undo a completed answer', async () => {
  for (const type of ['infer.accepted', 'infer.delta']) {
    const h = fixture({send: (m, epoch) => epoch === 7 && m.type === type ? Promise.reject(new Error('link lost')) : Promise.resolve(true)});
    h.host.handle(request('a'), 7);h.host.handle(request('b'), 8);
    if (type === 'infer.delta') {h.response(h.starts[0].id, '半截');h.poll();}
    await flush();assert.deepEqual(h.cancels, type === 'infer.accepted' ? [h.starts[0].id] : []);
    h.end(h.starts[0].id);h.response(h.starts[1].id, '成功');h.end(h.starts[1].id);h.poll();
    if (type === 'infer.accepted') assert.equal(h.messages(7, 'a', 'infer.error')[0].code, 'CANCELLED');
    else assert.equal(h.messages(7, 'a', 'infer.done').length, 1);
    assert.equal(h.messages(8, 'b', 'infer.done').length, 1);
  }
});
test('oversized input cannot reuse another request output or close its task card', () => {
  const h = fixture();h.host.handle(request('a'), 7);
  h.host.handle(request('large', '中'.repeat(12000)), 8);
  assert.equal(h.messages(8, 'large', 'infer.error')[0].code, 'PAYLOAD_TOO_LARGE');
  assert.equal(h.cards.filter(c => c[0] === 'end').length, 0);assert.equal(h.host.activeCount(), 1);
});
test('full answer returns immediately without native end; cleanup cannot duplicate or retract it',()=>{
  const h=fixture();h.host.handle(request('a'),7);h.response(h.starts[0].id,'完整答案');h.poll();
  assert.equal(h.messages(7,'a','infer.done').length,1);assert.equal(h.host.activeCount(),0);assert.equal(h.model.activeCount(),0);
  assert.equal(h.model.jobs.length,1,'retain native job until cleanup actually ends');
  h.host.handle(request('b'),8);assert.equal(h.starts.length,2);assert.equal(h.model.activeCount(),1);
  h.emit(h.starts[0].id,'destroy','401');h.end(h.starts[0].id);h.poll();
  assert.equal(h.messages(7,'a','infer.done').length,1);assert.equal(h.messages(7,'a','infer.error').length,0);
  h.response(h.starts[1].id,'第二个答案');h.poll();assert.equal(h.messages(8,'b','infer.done').length,1);
  h.end(h.starts[1].id);h.poll();assert.equal(h.model.jobs.length,0);
});
test('a streaming response without a finish marker must not be treated as a full answer',()=>{
  const h=fixture();h.host.handle(request('a'),7);
  h.emit(h.starts[0].id,'response',JSON.stringify({message:{content:'完整答案'}}));h.poll();
  assert.equal(h.messages(7,'a','infer.done').length,0);assert.equal(h.host.activeCount(),1);
  h.end(h.starts[0].id);h.poll();assert.equal(h.messages(7,'a','infer.done').length,0);
  assert.equal(h.messages(7,'a','infer.error').length,1);
});
test('task-card exceptions cannot prevent native start or final delivery',()=>{
  for(const phase of ['begin','delta','end']){
    const h=fixture();h.host.card[phase]=()=>{throw new Error('dashboard observer failed');};
    h.host.handle(request('a'),7);assert.equal(h.starts.length,1);
    h.response(h.starts[0].id,'完整答案');h.poll();
    assert.equal(h.messages(7,'a','infer.done').length,1);assert.equal(h.host.activeCount(),0);
    h.end(h.starts[0].id);h.poll();assert.equal(h.model.jobs.length,0);
  }
});
test('image inference uses the VL transport and its cancellation without starting text sessions',()=>{
  const h=fixture(),visionStarts=[],visionCancels=[];
  h.host.setVisionTransport({readinessError:()=>'',start(messages,cb,id,image){visionStarts.push({messages,cb,id,image});return '';},cancel(id){visionCancels.push(id);}});
  h.host.handle({...request('image'),image:'/9j/4AAQSkZJRg=='},7);
  assert.equal(h.starts.length,0);assert.equal(visionStarts.length,1);assert.equal(visionStarts[0].image,'/9j/4AAQSkZJRg==');
  assert.equal(h.cards.find(card=>card[0]==='begin')[5],'/9j/4AAQSkZJRg==');
  h.host.handle(request('text'),8);assert.equal(h.messages(8,'text','infer.error')[0].code,'BUSY');
  h.host.handle({type:'infer.cancel',requestId:'image'},7);assert.deepEqual(visionCancels,[visionStarts[0].id]);
  visionStarts[0].cb({kind:'done',text:'',finishReason:'cancelled'});assert.equal(h.host.activeCount(),0);
  assert.equal(h.messages(7,'image','infer.error')[0].code,'CANCELLED');
});

test('VL waits for text native cleanup even after the answer has been returned',()=>{
  const h=fixture();let visionStarts=0;
  h.host.setVisionTransport({readinessError:()=>'',start(){visionStarts++;return '';},cancel(){}});
  h.host.handle(request('text'),7);h.response(h.starts[0].id,'已返回');h.poll();
  assert.equal(h.model.activeCount(),0);assert.equal(h.messages(7,'text','infer.done').length,1);
  h.host.handle({...request('image'),image:'/9j/4AAQSkZJRg=='},8);
  assert.equal(h.messages(8,'image','infer.error')[0].code,'BUSY');assert.equal(visionStarts,0);
  h.end(h.starts[0].id);h.poll();h.host.handle({...request('image2'),image:'/9j/4AAQSkZJRg=='},8);
  assert.equal(visionStarts,1);
});

test('each concurrent request reports its own loading and generating phases',()=>{
  const h=fixture();h.host.handle(request('a'),7);h.host.handle(request('b'),8);
  h.response(h.starts[1].id,'乙答案');h.poll();h.response(h.starts[0].id,'甲答案');h.poll();
  assert.deepEqual(h.messages(7,'a','infer.status').map(m=>m.state),['loading','generating']);
  assert.deepEqual(h.messages(8,'b','infer.status').map(m=>m.state),['loading','generating']);
});

test('cancelling a reused local handle skips the old request awaiting cleanup',()=>{
  const h=fixture(),updates=[];
  h.model.start([{role:'user',content:'旧问题'}],u=>updates.push(u),'reused');
  h.response(h.starts[0].id,'旧答案');h.poll();assert.equal(h.model.activeCount(),0);
  h.model.start([{role:'user',content:'新问题'}],u=>updates.push(u),'reused');
  h.model.cancel('reused');assert.deepEqual(h.cancels,[h.starts[1].id]);
  h.end(h.starts[0].id);h.end(h.starts[1].id);h.poll();
  assert.equal(updates.filter(u=>u.kind==='done').length,2);assert.equal(updates.at(-1).finishReason,'cancelled');
});
test('stream stays active until an empty terminal frame; telemetry follows the completed request',()=>{
  const h=fixture();h.host.handle(request('streamed'),7);const id=h.starts[0].id;
  h.emit(id,'response',JSON.stringify({message:{content:'hello'},finish_reason:null}));
  h.emit(id,'response',JSON.stringify({message:{content:' world'},finish_reason:null}));h.poll();
  assert.equal(h.host.activeCount(),1);assert.equal(h.messages(7,'streamed','infer.done').length,0);
  assert.equal(h.messages(7,'streamed','infer.delta')[0].metrics.streaming,true);
  h.emit(id,'response',JSON.stringify({message:{content:''},finish_reason:'stop',usage:{prefill_latency:35,completion_tokens:2}}));h.poll();
  const done=h.messages(7,'streamed','infer.done')[0];assert.equal(done.metrics.prefillMs,35);
  assert.equal(done.metrics.completionTokens,2);assert.equal(h.host.activeCount(),0);
  assert.equal(done.metrics.outputChunks,2);
  assert.equal(h.messages(7,'streamed','infer.delta').map(m=>m.text).join(''),'hello world');
});

(async () => {
  let passed = 0;
  for (const [name, body] of tests) {
    try {await body();passed++;console.log('PASS ' + name);}
    catch (error) {console.error('FAIL ' + name, error);process.exitCode = 1;}
  }
  console.log(passed + '/' + tests.length + ' actual Host/LocalChat/Relay concurrency tests passed.');
})();
