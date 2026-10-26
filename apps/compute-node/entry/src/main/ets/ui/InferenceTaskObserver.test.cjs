const assert=require('node:assert/strict');
const path=require('node:path');
const vm=require('node:vm');
const {transpile}=require('../../../../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},Date,Map,Set,Math,Number,Array,JSON};vm.runInNewContext(transpile(file),box);return box.exports;}
const presentation=load(path.join(__dirname,'InferencePresentation.ets'));
const {InferenceTaskObserver}=load(path.join(__dirname,'InferenceTaskObserver.ets'),{'./InferencePresentation':presentation});
const summary=presentation.inferenceSummary('System: PRIVATE_SYSTEM\nTools: PRIVATE_TOOLS\nUser task:\n比较两个模型\n\nControl: PRIVATE_CONTROL');
assert.equal(summary,'比较两个模型');
assert.equal(presentation.inferenceSummary('PRIVATE ENTIRE PROMPT'),'推理请求');
assert.equal(presentation.inferenceSummary('帮我解释什么是量子计算','普通聊天'),'帮我解释什么是量子计算');
assert.equal(presentation.inferenceSummary('用户：旧问题\n助手：旧回答\n用户：帮我解释什么是量子计算\n助手：','普通聊天'),'帮我解释什么是量子计算');
assert.equal(presentation.inferenceSummary('用户：旧问题\n助手：旧回答\n用户：请总结附件\n附件正文：\n内容\n助手：','普通聊天'),'请总结附件');
assert.equal(presentation.inferenceSummary('用户：旧问题\r\n助手：旧回答\r\n用户：当前问题\r\n助手：','普通聊天'),'当前问题');
assert.equal(presentation.inferenceSummary('解释 User task: 这个词','普通聊天'),'解释 User task: 这个词');
assert.equal(presentation.inferenceSummary('很长的问题'.repeat(30),'普通聊天'),'很长的问题'.repeat(30).substring(0,80)+'…');
assert.equal(presentation.inferenceSummary('  ','普通聊天'),'推理请求');
assert.equal(presentation.inferenceSummary('规则…\n用户请求：\n比较两个模型\n\n【子任务1：模型A｜已完成】\nPRIVATE_RESULT','合并结果'),'【合并结果】比较两个模型');
const observer=new InferenceTaskObserver();
let counter=0;
function job(input,source='算力设备1',epoch=7){const id='r'+(++counter);return {id,key:epoch+':'+id,epoch,peer:true,source,origin:'聊天设备2',question:'推理请求',input,answer:'',error:false,startedAt:Date.now()-1000,firstAt:0,endedAt:0,workerEpoch:source==='算力设备1'?0:8,image:'',routeMode:''};}
const plan=job('拆分规则，只输出 JSON\n用户请求：\n比较两个模型');
observer.begin(plan,'任务拆分','算力设备1');assert.equal(observer.views().length,0,'a planning call alone is not proof of a split');
plan.answer=JSON.stringify([{title:'模型A',task:'介绍模型A'},{title:'模型B',task:'介绍模型B'}]);plan.endedAt=Date.now();observer.end(plan);
assert.equal(observer.views().length,1);const group=observer.views()[0];assert.equal(group.title,'比较两个模型');assert.equal(group.executor,'算力设备1');
const unrelated=job('User task:\n其他问题');observer.begin(unrelated,'子任务 1/2','算力设备1');assert.equal(unrelated.taskId,undefined,'do not guess relationships from a caption alone');
const first=job('System: secret\nUser task:\n介绍模型A\nControl: phase');observer.begin(first,'子任务 1/2','算力设备1');
assert.equal(first.taskId,plan.taskId);assert.equal(first.subtaskId,'s1');assert.equal(group.subtasks[0].device,'算力设备1');
first.answer='Action: tool[]';first.endedAt=Date.now();observer.end(first);assert.equal(group.subtasks[0].phase,'running','one model completion is not subtask completion');
const second=job('User task:\n介绍模型B','算力设备2');observer.begin(second,'子任务 2/2','算力设备1');assert.equal(group.subtasks[1].device,'算力设备2');
const merge=job('合并规则\n用户请求：\n比较两个模型\n\n【子任务1：模型A｜已完成】\nA的实际结果\n\n【子任务2：模型B｜部分完成】\nB的部分结果');
observer.begin(merge,'合并结果','算力设备1');assert.equal(merge.subtaskId,'merge');assert.equal(group.phase,'merging');assert.equal(group.subtasks[0].result,'A的实际结果');assert.equal(group.subtasks[1].phase,'partial');
merge.answer='最终汇总';merge.endedAt=Date.now();observer.end(merge);assert.equal(group.phase,'partial');assert.equal(group.answer,'最终汇总');observer.clearFinished();assert.equal(observer.views().length,0);
for(const response of ['[]','garbage','[{"title":"single","task":"only one"}]']){const p=job('用户请求：\n这是普通问题');observer.begin(p,'任务拆分','算力设备1');p.answer=response;observer.end(p);assert.equal(observer.views().length,0);}
const other=job('用户请求：\n其他会话的问题','算力设备1',10);observer.begin(other,'任务拆分','算力设备1');other.answer=plan.answer;observer.end(other);observer.disconnect(10);assert.equal(observer.views()[0].phase,'cancelled');
const replacement=new InferenceTaskObserver();const late=job('用户请求：\n比较两个模型');replacement.begin(late,'任务拆分','算力设备1');late.answer=plan.answer;replacement.end(late);
const oldGroup=replacement.views()[0];replacement.suppress(oldGroup.key);assert.equal(replacement.views().length,0);
replacement.end(late);assert.equal(replacement.views().length,0,'authoritative snapshots permanently replace the compatibility group');
{
  const obs=new InferenceTaskObserver();const p=job('用户请求：\n天气和位置','算力设备1',20);obs.begin(p,'任务拆分','算力设备1');
  p.answer=JSON.stringify([{title:'天气',task:'查北京天气'},{title:'位置',task:'查研究所位置'}]);obs.end(p);const g=obs.views()[0];
  const evidence=job('[developer]\nrules\n[user]\nUser task:\n查北京天气\n\nCall t/s1/call-1 tool=weather_search status=success\nObservation: 阴','算力设备1',20);
  obs.begin(evidence,'子任务 1/2','算力设备1');assert.equal(evidence.subtaskId,'s1','tool evidence after the task text is not part of the task');evidence.answer='Action: weather_search[{}]';obs.end(evidence);
  const later=job('User task:\n查北京天气\nExecute only missing required calls now','算力设备1',20);obs.begin(later,'子任务 1/2','算力设备1');
  assert.equal(later.subtaskId,'s1','later rounds of a proven child stay in its row');later.answer='Final: 阴';obs.end(later);
  const stray=job('User task:\n别的','算力设备1',20);obs.begin(stray,'子任务 2/2','算力设备1');assert.equal(stray.taskId,undefined,'an unproven child still needs its task text');
  const m=job('合并规则\n用户请求：\n天气和位置\n\n结果格式变了','算力设备1',20);obs.begin(m,'合并结果','算力设备1');assert.equal(g.phase,'merging');
  m.answer='汇总';m.endedAt=Date.now();obs.end(m);assert.equal(g.subtasks[0].phase,'done');assert.equal(g.subtasks[1].phase,'failed');assert.equal(g.phase,'partial');assert.ok(g.endedAt>0);
  const s=new InferenceTaskObserver();const sp=job('用户请求：\n很久的任务','算力设备1',21);s.begin(sp,'任务拆分','算力设备1');sp.answer=p.answer;s.end(sp);
  const realNow=Date.now;Date.now=()=>realNow()+600001;try{assert.equal(s.views()[0].phase,'unknown');assert.ok(s.views()[0].endedAt>0);}finally{Date.now=realNow;}
}
{
  const obs=new InferenceTaskObserver();const p=job('# Role\nsplit\n\n## Examples\nRequest: x\nOutput: []\n\n## User request\n比较两个模型','算力设备1',30);obs.begin(p,'任务拆分','算力设备1');
  p.answer=JSON.stringify([{title:'模型A',task:'介绍模型A'},{title:'模型B',task:'介绍模型B'}]);obs.end(p);const g=obs.views()[0];assert.equal(g.title,'比较两个模型');
  const m=job('# Role\nmerge\n\n## User request\n比较两个模型\n\n## Subtask results\n\n### Subtask 1: 模型A [completed]\nA的结果\n\n### Subtask 2: 模型B [unfinished]\nThis part could not be completed: 超时','算力设备1',30);
  obs.begin(m,'合并结果','算力设备1');assert.equal(g.phase,'merging');assert.equal(g.subtasks[0].phase,'done');assert.equal(g.subtasks[0].result,'A的结果');assert.equal(g.subtasks[1].phase,'failed');
  assert.equal(presentation.inferenceSummary('# Role\nmerge\n\n## User request\n比较两个模型\n\n## Subtask results\n\n### Subtask 1: 模型A [completed]\nX','合并结果'),'【合并结果】比较两个模型');
}
console.log('PASS: short titles, raw prompts excluded, real legacy split plans, exact child matching, actual executor, returned result sections, no fabricated completion and disconnect');
