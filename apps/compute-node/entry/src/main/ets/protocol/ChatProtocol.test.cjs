// node ChatProtocol.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
let now = 0;
const context = { exports: {}, Uint8Array, Date: { now: () => now }, require: name => {
  assert.equal(name, '@kit.ArkTS');
  return { util: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: { create: (encoding, options) => ({ decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }) },
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
    }
  } };
} };
vm.runInNewContext(transpile(__dirname + '/ChatProtocol.ets'), context);
const { encodeMessage, MessageAssembler, validMessage, MAX_IMAGE_BASE64 } = context.exports;
{
  const agent={exports:{},require:context.require};
  vm.runInNewContext(transpile(__dirname+'/../../../../../../agent-client/entry/src/main/ets/protocol/ChatProtocol.ets'),agent);
  const delta={protocol:'nearby-chat-v1',type:'delta',requestId:'metrics',text:'x'};
  assert(validMessage(delta),'legacy messages do not require telemetry');
  assert(validMessage({...delta,metrics:{streaming:true,modelLoadMs:0,prefillMs:1.5,completionTokens:2,outputChunks:2,firstOutputMs:1,lastOutputMs:9}}));
  assert(agent.exports.validMessage({...delta,metrics:{streaming:true,prefillMs:1.5}}));
  for(const metrics of [null,{}, {streaming:'yes'},{streaming:true,prefillMs:-1},
    {streaming:true,decodeMs:Infinity},{streaming:true,promptTokens:1.5},{streaming:true,outputChunks:-1},
    {streaming:true,firstOutputMs:NaN},{streaming:true,lastOutputMs:-1}]) {
    assert(!validMessage({...delta,metrics}),'reject malformed optional telemetry');
  }
}
const request = { type: 'request', requestId: 'r', needs: [], messages: [{ role: 'user', content: '中文😀'.repeat(400) }] };
const frames = encodeMessage(request, 'message_1');
assert(frames.length > 1);
assert(frames.every(frame => Buffer.byteLength(frame) < 1024));
const assembler = new MessageAssembler();
assert.equal(assembler.receive(frames.at(-1)), null);
assert.equal(assembler.receive(frames.at(-1)), null);
let result;
for (const frame of frames.slice(0, -1).reverse()) result = assembler.receive(frame);
assert.equal(JSON.stringify(result), JSON.stringify(request));
for (const frame of frames) assert.equal(assembler.receive(frame), null);
assembler.clear();
assert.equal(assembler.receive(frames[0]), null);
const altered = JSON.parse(frames[0]);
altered.data = Buffer.alloc(480, 65).toString('base64');
assert.throws(() => assembler.receive(JSON.stringify(altered)), /Conflicting duplicate/);
const changedCount = { ...JSON.parse(frames[0]), count: frames.length + 1 };
assert.throws(() => assembler.receive(JSON.stringify(changedCount)), /Conflicting fragment count/);
assert.throws(() => assembler.receive('x'.repeat(1024)));
assert.throws(() => assembler.receive('null'));
assert.throws(() => assembler.receive('{'));
for (const patch of [{ index: -1 }, { count: 138 }, { data: '!!!!' }, { data: 'AB==' }, { id: 'bad id' }, { index: 0.5 }]) {
  assert.throws(() => new MessageAssembler().receive(JSON.stringify({ ...JSON.parse(frames[0]), ...patch })));
}
assert.throws(() => encodeMessage({ type: 'request', requestId: 'r', messages: [{ role: 'system', content: 'bad' }] }, 'a'));
assert.throws(() => encodeMessage({ type: 'delta', requestId: 'r', text: '\u0000'.repeat(16000) }, 'a'), /64 KiB/);
assert.throws(() => encodeMessage({ type: 'hello' }, 'x'.repeat(65)));
assert(!validMessage(null));
assert(!validMessage({ ...request, messages: [{ role: 'user', content: 'x'.repeat(1801) }] }));
assert(!validMessage({ ...request, messages: Array(8).fill(request.messages[0]) }));
assert(validMessage({ ...request, sched: true, origin: '聊天设备2' }));
assert(!validMessage({ ...request, sched: true, origin: 'x'.repeat(129) }));
const bounded = new MessageAssembler();
for (let i = 0; i < 8; i++) bounded.receive(encodeMessage(request, 'id' + i)[0]);
assert.throws(() => bounded.receive(encodeMessage(request, 'id8')[0]), /Too many/);
now = 15000;
assert.throws(() => bounded.receive(frames[0]), /timed out/);
assert.equal(bounded.receive(frames[0]), null);
bounded.clear();
now += 100000;
const hello = encodeMessage({ type: 'hello' }, 'hello');
assert.equal(bounded.receive(hello[0]).type, 'hello');
const malformedUtf8 = JSON.stringify({ version: 1, id: 'utf8', count: 1, index: 0, data: '/w==' });
assert.throws(() => new MessageAssembler().receive(malformedUtf8));
const invalidMessage = JSON.stringify({ version: 1, id: 'schema', count: 1, index: 0, data: Buffer.from('{}').toString('base64') });
assert.throws(() => new MessageAssembler().receive(invalidMessage), /Invalid chat message/);
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'heartbeat' }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'heartbeat_ack' }));
const expiry = new MessageAssembler();
expiry.receive(frames[0]);
now += 15000;
assert.throws(() => expiry.checkExpiry(), /timed out/);
assert.doesNotThrow(() => expiry.checkExpiry(), 'expired pending messages are cleared');
assert.equal(expiry.receive(encodeMessage({ type: 'hello' }, 'idle')[0]).type, 'hello');
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'hello' }));
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'hello', peerRole: 'chat' }));
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'hello_ack', peerRole: 'compute' }));
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'hello_ack', peerRole: 'compute', slot: 2 }));
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'hello', peerRole: 'compute', deviceUid: 'install-1234' }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'hello', deviceUid: 'x'.repeat(65) }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'hello_ack', slot: 0 }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'hello_ack', slot: 2.5 }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'deviceInfoSync', requestId: 'fractional',
  devices: [{ id: 'worker', role: 'compute', capabilities: [], slot: 2.5 }] }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'deviceInfoSync', requestId: 'bad-ready',
  devices: [{ id: 'worker', role: 'compute', capabilities: [], slot: 2, ready: 'false' }] }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'hello', peerRole: 'other' }));
now += 1000000000;
assert.doesNotThrow(() => expiry.checkExpiry(), 'completed message never creates an inference timeout');
assert.equal(expiry.receive(encodeMessage({ type: 'done', requestId: 'r' }, 'after_idle')[0]).type, 'done');
const info = {
  protocol: 'nearby-chat-v1', type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen',
  memUsage: 40, memAvail: 1000, memTotal: 2000, thermalLevel: 2, batteryTemp: 42, cpuUsage: 18,
  modelRequests: 1, capabilities: ['text', 'vision'], peerRole: 'compute'
};
assert(validMessage(info));
assert(!validMessage({ ...info, peerRole: 'other' }));
assert(!validMessage({ ...info, thermalLevel: 'hot' }));
assert(validMessage({ ...info, capabilities: [] }));
assert(validMessage({ ...info, capabilities: undefined }), 'undeclared capabilities mean text-only');
assert(!validMessage({ ...info, capabilities: 'vision' }));
assert(!validMessage({ ...info, capabilities: ['fly'] }));
assert(!validMessage({ ...info, capabilities: Array(9).fill('text') }));
// The compute↔compute info poll frame carries only this shape; it must stay valid
// or encodeMessage throws in LinkEnhanceChannel.write and tears the link down.
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'deviceInfo', requestId: 'info-2', capabilities: [] }));
// 强度档位：可选整数 1-3；缺省（老对端）合法，畸形值拒收
assert(validMessage({ ...info, modelTier: 3 }), 'wire tolerates a legacy tier 3 (consumers normalize to 2)');
assert(validMessage({ ...info, modelTier: 1 }));
assert(validMessage(info), 'an undeclared tier stays valid (old peer)');
for (const modelTier of [0, 4, 2.5, 'strong']) {
  assert(!validMessage({ ...info, modelTier }), 'malformed modelTier rejected: ' + JSON.stringify(modelTier));
}
// 分片往返后档位字段保留
const tiered = new MessageAssembler();
assert.equal(tiered.receive(encodeMessage({ ...info, modelTier: 3 }, 'tier')[0]).modelTier, 3);
assert.equal(new MessageAssembler().receive(encodeMessage({
  type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen', memUsage: 40,
  thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, capabilities: ['text'], peerRole: 'compute'
}, 'info')[0]).batteryTemp, 42);
const sync = {
  protocol: 'nearby-chat-v1', type: 'deviceInfoSync', requestId: 'sync-1',
  devices: [{ id: 'self', name: '本机', role: 'self', model: 'Qwen', memUsage: 10, modelRequests: 0, capabilities: ['text'] }]
};
assert(validMessage(sync));
assert(validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'stable-install', role: 'compute', capabilities: [] }] }));
assert(!validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'x'.repeat(65), role: 'compute', capabilities: [] }] }));
// 未声明能力的老对端（v1）必须仍然合法：缺省 = 纯文本，路由侧 fail closed。
assert(validMessage({ ...sync, devices: [{ id: 'worker', role: 'compute' }] }), 'undeclared capabilities mean text-only');
// roster 条目同样可携带可选档位（紧凑 roster 设计性省略，缺省合法）
assert(validMessage({ ...sync, devices: [{ id: 'worker', role: 'compute', capabilities: [], modelTier: 2 }] }),
  'roster entries may carry modelTier');
assert(!validMessage({ ...sync, devices: [{ id: 'worker', role: 'compute', capabilities: [], modelTier: 9 }] }));
assert(!validMessage({ ...sync, devices: null }));
assert(validMessage({
  protocol: 'nearby-chat-v1', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], needs: [], sched: true
}));
assert(!validMessage({
  protocol: 'nearby-chat-v1', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], sched: 'yes'
}));
// 老对端（v1）的 request 不带 needs 也必须合法；带图请求仍必须显式声明 vision（见下）。
assert(validMessage({
  protocol: 'nearby-chat-v1', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }]
}), 'a request without needs stays valid');
// 协议号仍是精确匹配：外来版本一律拒收（这正是不能贸然升到 v2 的原因）。
assert(!validMessage({
  protocol: 'nearby-chat-v9', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], needs: []
}), 'a foreign protocol version is rejected');
assert(validMessage({ ...request, needs: ['vision'] }));
assert(!validMessage({ ...request, needs: ['fly'] }));
assert(!validMessage({ ...request, needs: Array(5).fill('vision') }));
// 图片：裸 base64，带图必须需要 vision，且受 MAX_IMAGE_BASE64 约束
assert(validMessage({ ...request, needs: ['vision'], image: 'QUJD' }));
assert(!validMessage({ ...request, needs: [], image: 'QUJD' }), 'an image request must need vision');
assert(!validMessage({ ...request, needs: ['vision'], image: 'data:image/jpeg;base64,QUJD' }), 'no data-url prefix');
assert(!validMessage({ ...request, needs: ['vision'], image: 'QU JD!' }), 'base64 alphabet only');
assert(!validMessage({ ...request, needs: ['vision'], image: '' }), 'empty payload rejected');
assert(!validMessage({ ...request, needs: ['vision'], image: 'A'.repeat(MAX_IMAGE_BASE64 + 1) }), 'over budget rejected');
const withImage = { ...request, needs: ['vision'], image: 'A'.repeat(20000) };
assert(validMessage(withImage));
{
  // 大图走分片装配：20000 字符 base64 拆成四十多片后必须完整还原
  const parts = encodeMessage(withImage, 'big-image');
  assert(parts.length > 40, 'a 20k-char image spans dozens of fragments');
  const assembler = new MessageAssembler();
  let decoded = null;
  for (let i = parts.length - 1; i >= 0; i--) decoded = assembler.receive(parts[i]);
  assert.equal(decoded.image, withImage.image, 'image survives out-of-order fragment assembly');
  assert.equal(decoded.needs.join(','), 'vision');
}
// infer 通道的附图：与 request 同一条约束（裸 base64、无 data: 前缀、受 MAX_IMAGE_BASE64 限制）。
// 缺这道校验，畸形/超长图片会绕过协议层直达 VL 引擎。
const inferImage = {
  protocol: 'nearby-chat-v1', type: 'infer.request', version: 2, requestId: 'req-img',
  prompt: 'describe', maxOutputTokens: 512, deadlineBudgetMs: 180000, image: 'QUJD'
};
assert(validMessage(inferImage), 'an infer request may carry a bare base64 image');
assert(!validMessage({ ...inferImage, image: 'data:image/jpeg;base64,QUJD' }), 'infer image rejects a data-url prefix');
assert(!validMessage({ ...inferImage, image: 'QU JD!' }), 'infer image alphabet only');
assert(!validMessage({ ...inferImage, image: '' }), 'infer empty image rejected');
assert(!validMessage({ ...inferImage, image: 'A'.repeat(MAX_IMAGE_BASE64 + 1) }), 'infer image over budget rejected');
{
  // 24000 字符上限的图在 infer 通道同样靠分片传输，装配必须完整还原
  const bigInferImage = { ...inferImage, requestId: 'req-big', image: 'A'.repeat(20000) };
  const parts = encodeMessage(bigInferImage, 'big-infer-image');
  assert(parts.length > 40, 'a 20k-char infer image spans dozens of fragments');
  const assembler = new MessageAssembler();
  let decoded = null;
  for (let i = parts.length - 1; i >= 0; i--) decoded = assembler.receive(parts[i]);
  assert.equal(decoded.image, bigInferImage.image, 'infer image survives out-of-order fragment assembly');
}
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'done', requestId: 'r', source: '来自本机 Qwen' }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'done', requestId: 'r', source: 'x'.repeat(257) }));
console.log('PASS: UTF-8 roundtrip, <1KiB envelopes, out-of-order/replay, conflicting duplicates/counts, schema/base64/byte/count/pending limits, incomplete-only timeout, clear, malformed UTF-8, deviceInfo/sched/source, image payload');
for (const type of ['prepare', 'prepared']) {
  const message = { protocol: 'nearby-chat-v1', type, requestId: 'prepare-1' };
  assert(validMessage(message));
  for (const requestId of [undefined, '', 1, 'x'.repeat(129)]) {
    assert(!validMessage({ ...message, requestId }));
  }
  assert.equal(new MessageAssembler().receive(encodeMessage(message, type)[0]).type, type);
}
const prepared = { protocol: 'nearby-chat-v1', type: 'prepared', requestId: 'r' };
assert(validMessage({ ...prepared, error: 'x'.repeat(2048) }));
for (const error of [null, 1, {}, 'x'.repeat(2049)]) assert(!validMessage({ ...prepared, error }));
console.log('PASS: prepare/prepared schema and roundtrip, required bounded requestId, optional bounded error');

// Slow-but-progressing uploads must survive both endpoints' receive watchdogs.
for (const relative of ['./ChatProtocol.ets', '../../../../../../agent-client/entry/src/main/ets/protocol/ChatProtocol.ets']) {
  const env = { ...context, exports: {} };
  vm.runInNewContext(transpile(__dirname + '/' + relative), env);
  const p = env.exports;
  const payload = { type: 'infer.request', version: 2, requestId: 'slow', prompt: 'x'.repeat(10800) };
  const chunks = p.encodeMessage(payload, 'slow');
  now = 0;
  const slow = new p.MessageAssembler(), receipt = [];
  slow.setFragmentObserver(part => receipt.push(part));
  let decoded;
  for (let i = 0; i < chunks.length; i++) { now = i * 900; decoded = slow.receive(chunks[i]); slow.checkExpiry(); }
  assert.equal(decoded.prompt, payload.prompt, 'continuous ~20s upload succeeds');
  assert.equal(receipt.length, chunks.length);
  assert.equal(receipt.at(-1).received, chunks.length);
  assert.equal(receipt.at(-1).gapMs, 900);
  assert.equal(receipt.at(-1).elapsedMs, (chunks.length - 1) * 900);
  assert(!JSON.stringify(receipt).includes(payload.prompt), 'diagnostics contain metadata only');
  now += 200000;
  assert.doesNotThrow(() => slow.checkExpiry(), 'completed transfers have no inference timeout');

  now = 0;
  const duplicate = new p.MessageAssembler(); duplicate.receive(chunks[0]);
  now = 14000; duplicate.receive(chunks[0]);
  duplicate.receive(p.encodeMessage({ type: 'hello' }, 'other')[0]);
  now = 15000;
  assert.throws(() => duplicate.checkExpiry(), /received=1\/23.*idleMs=15000/,
    'duplicate frames and unrelated messages never renew progress');

  now = 0;
  const drip = new p.MessageAssembler();
  const long = p.encodeMessage({ ...payload, prompt: 'x'.repeat(32000) }, 'drip');
  for (let i = 0; i < 60; i++) { now = i * 2000; drip.receive(long[i]); }
  now = 120000;
  assert.throws(() => drip.receive(long[60]), /ageMs=120000/, 'total upload duration remains bounded');

  now = 0;
  const isolated = new p.MessageAssembler(); isolated.receive(chunks[0]);
  const other = p.encodeMessage(payload, 'second');
  now = 10000; isolated.receive(other[0]);
  now = 15000; assert.throws(() => isolated.checkExpiry(), /id=slow/, 'progress is per message');
  const noisy = new p.MessageAssembler(); noisy.setFragmentObserver(() => { throw new Error('diagnostic sink'); });
  for (const chunk of chunks) decoded = noisy.receive(chunk);
  assert.equal(decoded.prompt, payload.prompt, 'logging failures cannot interrupt delivery');
}
console.log('PASS slow transfers, progress-only renewal, duplicate/other-message isolation, absolute bounds, metadata diagnostics on both endpoints');
