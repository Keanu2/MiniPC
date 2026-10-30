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
let lastTier = -1;
// 真实 TaskRules（第二个裸 vm）：LocalChat 的档位重算必须与 hub 侧同一份规则。
const taskRules = (() => {
  const box = { exports: {}, Error, Number, Math };
  vm.runInNewContext(transpile(__dirname + '/../cluster/TaskRules.ets'), box);
  return box.exports;
})();
// 真实 Utf8Repair（第三个裸 vm）：出口清洗必须是产品同款，不许 stub。
const utf8Repair = (() => {
  const box = { exports: {} };
  vm.runInNewContext(transpile(__dirname + '/Utf8Repair.ets'), box);
  return box.exports;
})();
// 驱动 consumeEvents：捕获 interval 回调 + 事件队列，测试可以手动推进原生事件。
let consumeTick = null;
let nativeEvents = [];
const cancelledIds = [];
const reuseExports = {};
vm.runInNewContext(transpile(__dirname + '/SessionReuse.ets'), { exports: reuseExports, Date });
const startArgs = [];
let reuseOn = false;
let outputPreference=true;
let clockOverride;
const context = { exports: {}, ArrayBuffer, Date: {now:()=>clockOverride ?? Date.now()},
  setInterval(fn) { consumeTick = fn; return 1; }, clearInterval() {}, require(name) {
  if (name === 'libgewu_probe.so') return { default: {
    start(modelPath, request, ...extra) {
      startArgs.push([modelPath,request,...extra]);
      starts++; lastModelPath = modelPath; lastRequest = request;
      return failStart ? 0 : ++nextId;
    },
    cancel(id) { cancelledIds.push(id); }, complete() {}, takeEvents() { return nativeEvents.splice(0); }
  } };
  if (name === './SessionReuse') return reuseExports;
  if (name === './OutputSettings') return {outputSettings:()=>({streaming:outputPreference})};
  if (name === '@kit.CoreFileKit') return { fileIo: {accessSync:()=>reuseOn} };
  if (name === './Utf8Repair') return utf8Repair;
  if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
  if (name === './ModelRegistry') return {
    readyModelDirs: () => registryDirs.slice(),
    selectModelDir: (filesDir, needs, taskTier) => {
      lastTier = taskTier;
      if (needs.indexOf('vision') >= 0) return visionReady ? VL_DIR : '';
      return registryDirs[0] || '';
    },
    modelRequestType: () => requestType,
    manifestTier: () => 2
  };
  if (name === '../cluster/TaskRules') return taskRules;
  return {};
} };
vm.runInNewContext(transpile(__dirname + '/LocalChat.ets'), context);
const { LocalChat } = context.exports;
const chat = new LocalChat('/files');
// 就绪检查：任意就绪目录即可，不再逐个点名文件
registryDirs = [];
assert.equal(chat.readinessError(), '没有可用的文字模型，请检查模型选择和部署文件。');
registryDirs = [TEXT_DIR];
assert.equal(chat.readinessError(), '');
assert.equal(starts, 0, 'readiness must never start GEWU');
// Text requests stream by default; budgets and model selection stay independent.
assert.equal(chat.start([{ role: 'user', content: 'hi' }], () => {}, 'a'), '');
assert.equal(starts, 1);
assert.equal(lastModelPath, '/files/models/' + TEXT_DIR);
assert.deepEqual(JSON.parse(lastRequest), {
  type: 'qwen2',
  messages: [{ role: 'user', content: 'hi' }],
  stream: true, max_tokens: 2048
});
assert.equal(chat.activeCount(), 1);
assert.equal(lastTier, 1, 'short plain text classifies light and drives tiered dir selection');
assert.equal(chat.readinessError(), '', 'one in-flight job must not block another device prepare');
assert.equal(chat.start([{ role: 'user', content: 'hi2' }], () => {}, 'b'), '');
assert.equal(starts, 2);
failStart = true;
assert.equal(chat.start([{ role: 'user', content: 'hi3' }], () => {}, 'c'), '模型繁忙，请稍后再发。');
assert.equal(starts, 3, 'native start is attempted even when jobs already run');
assert.equal(chat.activeCount(), 2, 'failed native start must not keep a job');
failStart = false;
// 档位感知选模：分类结果透传给 selectModelDir 的第三参（hub 与本机同一份规则）
assert.equal(chat.start([{ role: 'user', content: '```python\nprint(1)\n```' }], () => {}, 't1'), '');
assert.equal(lastTier, 2, 'code fence classifies complex');
assert.equal(chat.start([{ role: 'user', content: 'hi again' }], () => {}, 't2', { maxTokens: 128 }), '');
assert.equal(lastTier, 1, 'small output budget stays light');
assert.equal(chat.start([{ role: 'user', content: 'hi again' }], () => {}, 't3', { maxTokens: 2048 }), '');
assert.equal(lastTier, 1, 'wire budget no longer participates in tiering (agent sends a constant 2048)');
// 带图请求：选多模态目录，最后一条 user 消息编码为分片（图片在前）
visionReady = true;
requestType = 'qwen2vl';
assert.equal(chat.start([
  { role: 'user', content: '之前的问题' },
  { role: 'assistant', content: '之前的回答' },
  { role: 'user', content: '这张图里有什么' }
], () => {}, 'd', { image: 'QUJD' }), '');
assert.equal(starts, 7);
assert.equal(lastModelPath, '/files/models/' + VL_DIR, 'an image request picks the multimodal dir');
const multimodal = JSON.parse(lastRequest);
assert.equal(multimodal.type, 'qwen2vl', 'request type follows the model api_config');
assert.equal(multimodal.messages.length, 3);
assert.equal(multimodal.messages[0].content, '之前的问题', 'history stays plain text');
assert.deepEqual(multimodal.messages[2].content, [
  { type: 'image_url', image_url: 'data:image/jpeg;base64,QUJD' },
  { type: 'text', text: '这张图里有什么' }
], 'the last user message becomes image-then-text parts');
assert.equal(multimodal.stream, true, 'model selection does not force a single-shot response');
// 本地没有多模态模型时带图 fail closed
visionReady = false;
const beforeVision = starts;
assert.equal(chat.start([{ role: 'user', content: '看图' }], () => {}, 'e', { image: 'QUJD' }),
  '本地模型不支持图片理解。');
assert.equal(starts, beforeVision, 'a text-only deployment never receives the image');
// GEWU 引擎把跨块多字节字符替换成 U+FFFD（真机实测首个汉字 1-3 个）：consumeEvents
// 出口清洗，answer、delta 与 done 回调拿到的都是净化文本。源文件保持 ASCII，
// U+FFFD 运行时构造（与 Utf8Repair.test.cjs 同款约束）。
const BAD = String.fromCharCode(0xFFFD);
const queueJob = (id, content) => {
  nativeEvents.push(JSON.stringify({ event: 'response', id: String(id),
    payload: JSON.stringify({ message: { role: 'assistant', content: content }, finish_reason: 'stop' }) }));
  nativeEvents.push(JSON.stringify({ event: 'end', id: String(id), payload: 'closed' }));
};
let sawRepair = [];
assert.equal(chat.start([{ role: 'user', content: '证明勾股定理' }],
  (update) => sawRepair.push(update), 'f'), '');
queueJob(nextId, '证明勾' + BAD + '定理的方法如下');
let sawStrip = [];
assert.equal(chat.start([{ role: 'user', content: '写Python冒泡排序代码' }],
  (update) => sawStrip.push(update), 'g'), '');
queueJob(nextId, BAD + BAD + '是Python冒泡排序代码示例');
consumeTick();
assert.deepEqual(sawRepair.map((u) => u.kind), ['delta', 'done']);
assert.equal(sawRepair[0].text, '证明勾股定理的方法如下', '锚点命中：丢失的字符按源文本修复');
assert.equal(sawRepair[1].text, '证明勾股定理的方法如下');
assert.equal(sawRepair[1].finishReason, 'stop');
assert.deepEqual(sawStrip.map((u) => u.kind), ['delta', 'done']);
assert.equal(sawStrip[0].text, '是Python冒泡排序代码示例', '锚点不命中：剔除残留 FFFD，宁缺字不出乱码');
assert.equal(sawStrip[1].text, '是Python冒泡排序代码示例');
for (const update of sawRepair.concat(sawStrip)) {
  assert.ok(update.text.indexOf(BAD) < 0, 'no U+FFFD may leave LocalChat');
}
const beforeClose = starts;
chat.close();
assert.equal(chat.readinessError(), '模型服务已关闭。');
assert.equal(starts, beforeClose, 'closed readiness must not start another inference');
console.log('PASS: readiness via registry, plain request unchanged, multimodal parts and model selection, image fail-closed');

{
  registryDirs = [TEXT_DIR];
  const session = new LocalChat('/files');
  const pair = [{role:'developer',content:'SYS'},{role:'user',content:'User task:\nT\nControl: go'}];
  const before = startArgs.length;
  session.start(pair,()=>{},'default');assert.equal(startArgs[before].length,4,'reuse stays disabled by default');
  reuseOn = true;
  session.start(pair,()=>{},'first');const key = startArgs.at(-1)[4];assert.ok(key);
  nativeEvents.push(JSON.stringify({id:String(nextId),event:'response',payload:JSON.stringify({message:{content:'ok'},finish_reason:'stop'})}));
  nativeEvents.push(JSON.stringify({id:String(nextId),event:'end',payload:'closed'}));consumeTick();
  const extended=[pair[0],{role:'user',content:'User task:\nT\nAction: x\nObservation: y\nControl: go'}];
  session.start(extended,()=>{},'continued');assert.equal(startArgs.at(-1)[4],key);
  assert.equal(JSON.parse(startArgs.at(-1)[1]).messages.length,1,'same model continues with appended context');
  registryDirs = ['other-model'];
  session.start(extended,()=>{},'other');assert.notEqual(startArgs.at(-1)[4],key,'changing selected model cannot reuse its native session');
  assert.equal(JSON.parse(startArgs.at(-1)[1]).messages.length,2);
  session.close();reuseOn=false;
}
console.log('PASS: opt-in session reuse remains isolated by selected model');

{
  const session = new LocalChat('/files'), updates=[];
  session.start([{role:'user',content:'test stream'}],u=>updates.push(u),'stream');
  const id=nextId;
  const emit=(content,finish_reason=null,usage)=>nativeEvents.push(JSON.stringify({event:'response',id:String(id),
    payload:JSON.stringify({message:{content},finish_reason,usage})}));
  emit('');consumeTick();assert.equal(updates.length,0,'empty chunks do not produce a first output');
  emit('hello');consumeTick();assert.equal(session.activeCount(),1);
  assert.deepEqual(updates.map(u=>u.kind),['delta'],'first text must not complete a stream');
  assert.equal(updates[0].metrics.streaming,true);
  emit(' world');consumeTick();assert.equal(session.activeCount(),1);
  emit('','stop',{model_load_latency:12.5,prefill_latency:0,decode_latency:40,prompt_tokens:8,completion_tokens:2});consumeTick();
  assert.deepEqual(updates.map(u=>u.kind),['delta','delta','done']);
  assert.equal(updates.at(-1).text,'hello world');assert.equal(updates.at(-1).metrics.prefillMs,0);
  assert.equal(updates.at(-1).metrics.modelLoadMs,12.5);assert.equal(updates.at(-1).metrics.completionTokens,2);
  assert.equal(session.activeCount(),0);assert.equal(session.hasPendingNativeJobs(),true);
  emit('late');consumeTick();assert.equal(updates.length,3,'late callback cannot overwrite completed output');
  nativeEvents.push(JSON.stringify({event:'end',id:String(id),payload:'closed'}));consumeTick();
  assert.equal(session.hasPendingNativeJobs(),false);session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'nonstream'}],u=>updates.push(u),'single',{stream:false});
  assert.equal(JSON.parse(lastRequest).stream,false);
  nativeEvents.push(JSON.stringify({event:'response',id:String(nextId),payload:JSON.stringify({message:{content:'complete'},
    usage:{model_load_latency:-1,prefill_latency:'bad',decode_latency:null,completion_tokens:1.5}})}));consumeTick();
  assert.deepEqual(updates.map(u=>u.kind),['delta','done']);assert.equal(updates[0].metrics.streaming,false);
  assert.equal(updates[1].metrics.modelLoadMs,undefined);assert.equal(updates[1].metrics.completionTokens,undefined);
  session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'interrupted'}],u=>updates.push(u),'interrupted');
  nativeEvents.push(JSON.stringify({event:'response',id:String(nextId),payload:JSON.stringify({message:{content:'partial'},finish_reason:null})}));
  nativeEvents.push(JSON.stringify({event:'end',id:String(nextId),payload:'closed'}));consumeTick();
  assert.equal(updates.at(-1).error,'模型会话已结束，但没有收到结束标记。');session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'limit'}],u=>updates.push(u),'limit');
  nativeEvents.push(JSON.stringify({event:'response',id:String(nextId),payload:JSON.stringify({message:{content:'深圳'},finish_reason:null})}));
  nativeEvents.push(JSON.stringify({event:'end',id:String(nextId),payload:'stalled_limit:600'}));consumeTick();
  assert.equal(updates.at(-1).error,'生成已达600秒上限仍未结束，已停止。');session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'idle'}],u=>updates.push(u),'idle');
  nativeEvents.push(JSON.stringify({event:'response',id:String(nextId),payload:JSON.stringify({message:{content:'深圳'},finish_reason:null})}));
  nativeEvents.push(JSON.stringify({event:'end',id:String(nextId),payload:'stalled_idle:300'}));consumeTick();
  assert.equal(updates.at(-1).error,'模型已超过300秒没有继续输出，已停止。');session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'empty-limit'}],u=>updates.push(u),'empty-limit');
  nativeEvents.push(JSON.stringify({event:'end',id:String(nextId),payload:'stalled'}));consumeTick();
  assert.equal(updates.at(-1).error,'超过时限仍未开始输出，已停止。');session.close();
}
console.log('PASS: streaming terminal detection, empty/late chunks, usage and explicit single-shot fallback');
{
  const session=new LocalChat('/files'),updates=[];clockOverride=50000;
  session.start([{role:'user',content:'batched callbacks'}],u=>updates.push(u),'batched');
  const id=nextId;clockOverride=50100;
  for(const [elapsedMs,content,finish_reason]of [[50,'first',null],[75,' last','stop']]){
    nativeEvents.push(JSON.stringify({event:'response',id:String(id),elapsedMs,
      payload:JSON.stringify({message:{content},finish_reason})}));
  }
  consumeTick();
  assert.equal(updates[0].outputAt,50050);assert.equal(updates[1].outputAt,50075);
  assert.equal(updates.at(-1).metrics.firstOutputMs,50);assert.equal(updates.at(-1).metrics.lastOutputMs,75);
  assert.equal(updates.at(-1).metrics.outputChunks,2,'one JS poll keeps the original output chunk count');
  assert.equal(updates.at(-1).text,'first last');session.close();clockOverride=undefined;
}
console.log('PASS: native callback time and chunk count survive a batched JS poll');
{
  const session=new LocalChat('/files'),updates=[];outputPreference=true;
  session.start([{role:'user',content:'first'}],u=>updates.push(u),'before-setting');const firstId=nextId;
  outputPreference=false;
  session.start([{role:'user',content:'second'}],()=>{},'after-setting');
  assert.equal(JSON.parse(lastRequest).stream,false,'next request reads the saved preference');
  nativeEvents.push(JSON.stringify({event:'response',id:String(firstId),payload:JSON.stringify({message:{content:'partial'},finish_reason:null})}));
  consumeTick();assert.equal(updates.length,1);assert.equal(updates[0].metrics.streaming,true);
  assert.equal(session.activeCount(),2,'saving non-streaming does not terminate an active stream');
  const reopened=new LocalChat('/files');reopened.start([{role:'user',content:'reopened'}],()=>{},'reopened');
  assert.equal(JSON.parse(lastRequest).stream,false,'a new engine instance uses the saved preference');
  reopened.start([{role:'user',content:'override'}],()=>{},'override',{stream:true});
  assert.equal(JSON.parse(lastRequest).stream,true,'an explicit internal request option takes precedence');
  session.close();reopened.close();outputPreference=true;
}
console.log('PASS: output preference applies to new requests without changing active streams');
{
  const { degenerateOutput } = context.exports;
  assert.equal(degenerateOutput('!'.repeat(24)), true, 'NaN-logit token 0 stream is garbage from the start');
  assert.equal(degenerateOutput('!'.repeat(23)), false);
  assert.equal(degenerateOutput('-'.repeat(40) + '\n'), false, 'markdown rules are not garbage');
  assert.equal(degenerateOutput('答案如下：' + '相机、'.repeat(60)), true, 'a short verbatim loop is cut');
  assert.equal(degenerateOutput('我是AI助手，很高兴为你服务。'.repeat(12)), true, 'a sentence loop is cut');
  assert.equal(degenerateOutput(Array.from({length:30},(_,i)=>String(100+i)).join(', ')), false, 'bench integers pass');
  assert.equal(degenerateOutput('| a | b |\n|---|---|\n| 1 | 2 |\n'), false);
  assert.equal(degenerateOutput('Action: {"tool":"x"}\n' + ' '.repeat(200)), false, 'whitespace padding is not a loop');

  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'1+1='}],u=>updates.push(u),'garbage');const id=nextId;
  for (let i = 0; i < 6; i++) nativeEvents.push(JSON.stringify({event:'response',id:String(id),
    payload:JSON.stringify({message:{content:'!!!!!'},finish_reason:null})}));
  consumeTick();
  assert.equal(cancelledIds.at(-1),id,'garbage cancels the native request');
  assert.ok(updates.filter(u=>u.kind==='delta').length < 6,'garbage stops streaming once detected');
  nativeEvents.push(JSON.stringify({event:'abort',id:String(id),payload:'0'}));
  nativeEvents.push(JSON.stringify({event:'end',id:String(id),payload:'closed'}));consumeTick();
  assert.equal(updates.at(-1).kind,'done');assert.ok(updates.at(-1).error.indexOf('模型输出异常')===0);
  assert.equal(updates.at(-1).finishReason,'error','our own cancel must not surface as a user stop');
  session.close();
}
{
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'abort'}],u=>updates.push(u),'engine-abort');
  nativeEvents.push(JSON.stringify({event:'response',id:String(nextId),payload:JSON.stringify({message:{content:'半截'},finish_reason:'abort'})}));
  consumeTick();
  assert.equal(updates.at(-1).kind,'done');assert.ok(updates.at(-1).error,'an engine abort is not a complete answer');
  assert.equal(updates.at(-1).finishReason,'error');session.close();
}
console.log('PASS: degenerate output and engine abort fail instead of streaming garbage or truncated answers');

{
  const { stripThink } = context.exports;
  assert.equal(stripThink('<think>plan</think>\n\nAnswer'), 'Answer');
  assert.equal(stripThink('<think>still thinking'), '');
  assert.equal(stripThink('Hi <thi'), 'Hi ');
  assert.equal(stripThink('a < b and <b>'), 'a < b and <b>');
  const session=new LocalChat('/files'),updates=[];
  session.start([{role:'user',content:'think'}],u=>updates.push(u),'think');const id=nextId;
  for (const [c,f] of [['<thi',null],['nk>hidden</thi',null],['nk>\n42','stop']]) nativeEvents.push(JSON.stringify({event:'response',id:String(id),
    payload:JSON.stringify({message:{content:c},finish_reason:f})}));
  consumeTick();
  assert.equal(updates.filter(u=>u.kind==='delta').map(u=>u.text).join(''),'42');
  assert.equal(updates.at(-1).text,'42');session.close();
}
console.log('PASS: think blocks are hidden from streamed and final output');