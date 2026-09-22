// node ChatProtocol.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
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
const { encodeMessage, MessageAssembler, validMessage } = context.exports;
const request = { type: 'request', requestId: 'r', messages: [{ role: 'user', content: '中文😀'.repeat(400) }] };
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
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'hello', peerRole: 'other' }));
now += 1000000000;
assert.doesNotThrow(() => expiry.checkExpiry(), 'completed message never creates an inference timeout');
assert.equal(expiry.receive(encodeMessage({ type: 'done', requestId: 'r' }, 'after_idle')[0]).type, 'done');
const info = {
  protocol: 'nearby-chat-v1', type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen',
  memUsage: 40, memAvail: 1000, memTotal: 2000, modelRequests: 1, peerRole: 'compute'
};
assert(validMessage(info));
assert(!validMessage({ ...info, peerRole: 'other' }));
assert.equal(new MessageAssembler().receive(encodeMessage({
  type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen', memUsage: 40, peerRole: 'compute'
}, 'info')[0]).model, 'Qwen');
const sync = {
  protocol: 'nearby-chat-v1', type: 'deviceInfoSync', requestId: 'sync-1',
  devices: [{ id: 'self', name: '本机', role: 'self', model: 'Qwen', memUsage: 10, modelRequests: 0 }]
};
assert(validMessage(sync));
assert(validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'stable-install', role: 'compute' }] }));
assert(!validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'x'.repeat(65), role: 'compute' }] }));
assert(!validMessage({ ...sync, devices: null }));
assert(validMessage({
  protocol: 'nearby-chat-v1', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], sched: true
}));
assert(!validMessage({
  protocol: 'nearby-chat-v1', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], sched: 'yes'
}));
assert(validMessage({ protocol: 'nearby-chat-v1', type: 'done', requestId: 'r', source: '来自本机 Qwen' }));
assert(!validMessage({ protocol: 'nearby-chat-v1', type: 'done', requestId: 'r', source: 'x'.repeat(257) }));
console.log('PASS: UTF-8 roundtrip, <1KiB envelopes, out-of-order/replay, conflicting duplicates/counts, schema/base64/byte/count/pending limits, incomplete-only timeout, clear, malformed UTF-8, deviceInfo/sched/source');
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
