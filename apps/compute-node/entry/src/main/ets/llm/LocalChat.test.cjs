// node LocalChat.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const TEXT_DIR = 'Qwen2.5-7B-Instruct-Q4_N_0';
const VL_DIR = 'Qwen2.5-VL-7B-Q4_N_0';
// 模型发现由 llm/ModelRegistry 提供并有专项测试；这里按需控制其返回值。
let registryDirs = [TEXT_DIR];
let visionReady = false;
let requestType = 'qwen2';
let starts = 0, nextId = 0, failStart = false;
let lastModelPath = '', lastRequest = '';
const context = { exports: {}, ArrayBuffer, setInterval: () => 1, clearInterval() {}, require(name) {
  if (name === 'libgewu_probe.so') return { default: {
    start(modelPath, request) {
      starts++; lastModelPath = modelPath; lastRequest = request;
      return failStart ? 0 : ++nextId;
    },
    cancel() {}, complete() {}, takeEvents() { return []; }
  } };
  if (name === './ModelRegistry') return {
    readyModelDirs: () => registryDirs.slice(),
    selectModelDir: (filesDir, needs) => {
      if (needs.indexOf('vision') >= 0) return visionReady ? VL_DIR : '';
      return registryDirs[0] || '';
    },
    modelRequestType: () => requestType
  };
  return {};
} };
vm.runInNewContext(transpile(__dirname + '/LocalChat.ets'), context);
const { LocalChat } = context.exports;
const chat = new LocalChat('/files');
// 就绪检查：任意就绪目录即可，不再逐个点名文件
registryDirs = [];
assert.equal(chat.readinessError(), '模型文件缺失或无法读取。');
registryDirs = [TEXT_DIR];
assert.equal(chat.readinessError(), '');
assert.equal(starts, 0, 'readiness must never start GEWU');
// 纯文本请求：目录与请求体保持原样（stream 固定 true，max_tokens 走 options）
assert.equal(chat.start([{ role: 'user', content: 'hi' }], () => {}, 'a'), '');
assert.equal(starts, 1);
assert.equal(lastModelPath, '/files/models/' + TEXT_DIR);
assert.deepEqual(JSON.parse(lastRequest), {
  type: 'qwen2',
  messages: [{ role: 'user', content: 'hi' }],
  stream: true, max_tokens: 2048
});
assert.equal(chat.activeCount(), 1);
assert.equal(chat.readinessError(), '', 'one in-flight job must not block another device prepare');
assert.equal(chat.start([{ role: 'user', content: 'hi2' }], () => {}, 'b'), '');
assert.equal(starts, 2);
failStart = true;
assert.equal(chat.start([{ role: 'user', content: 'hi3' }], () => {}, 'c'), '模型繁忙，请稍后再发。');
assert.equal(starts, 3, 'native start is attempted even when jobs already run');
assert.equal(chat.activeCount(), 2, 'failed native start must not keep a job');
failStart = false;
// 带图请求：选多模态目录，最后一条 user 消息编码为分片（图片在前）
visionReady = true;
requestType = 'qwen2vl';
assert.equal(chat.start([
  { role: 'user', content: '之前的问题' },
  { role: 'assistant', content: '之前的回答' },
  { role: 'user', content: '这张图里有什么' }
], () => {}, 'd', { image: 'QUJD' }), '');
assert.equal(starts, 4);
assert.equal(lastModelPath, '/files/models/' + VL_DIR, 'an image request picks the multimodal dir');
const multimodal = JSON.parse(lastRequest);
assert.equal(multimodal.type, 'qwen2vl', 'request type follows the model api_config');
assert.equal(multimodal.messages.length, 3);
assert.equal(multimodal.messages[0].content, '之前的问题', 'history stays plain text');
assert.deepEqual(multimodal.messages[2].content, [
  { type: 'image_url', image_url: 'data:image/jpeg;base64,QUJD' },
  { type: 'text', text: '这张图里有什么' }
], 'the last user message becomes image-then-text parts');
assert.equal(multimodal.stream, true, 'the merged request keeps the streaming GEWU contract');
// 本地没有多模态模型时带图 fail closed
visionReady = false;
const beforeVision = starts;
assert.equal(chat.start([{ role: 'user', content: '看图' }], () => {}, 'e', { image: 'QUJD' }),
  '本地模型不支持图片理解。');
assert.equal(starts, beforeVision, 'a text-only deployment never receives the image');
chat.close();
assert.equal(chat.readinessError(), '模型服务已关闭。');
assert.equal(starts, beforeVision, 'closed readiness must not start another inference');
console.log('PASS: readiness via registry, plain request unchanged, multimodal parts and model selection, image fail-closed');
