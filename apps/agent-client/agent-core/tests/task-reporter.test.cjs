const assert=require('node:assert/strict'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
const box={exports:{},require:name=>name==='./InferenceWire'?{utf8Bytes:s=>Buffer.from(s)}:{},Date,Math,JSON};
vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/model/TaskReporter.ets')),box);
const {TaskReporter}=box.exports;
const sent=[],input='原始请求\n'+ '附件'.repeat(1000),started=Date.now()-100;
const reporter=new TaskReporter('root1',input,started,s=>sent.push(s));
assert.equal(sent[0].input,input);assert.equal(sent[0].subtasks.length,0);
reporter.record('ACTION','搜索','search','{"q":"资料"}');
reporter.record('OBSERVATION','实际工具返回结果','search');
assert.equal(sent[0].activity,undefined,'previously queued snapshots cannot change');
assert.equal(sent.at(-1).phase,'running','a tool result never completes the task');
reporter.finish('done','根据工具结果整理后的最终回答');
assert.equal(sent.at(-1).answer,'根据工具结果整理后的最终回答');
assert.equal(sent.at(-1).input,input);assert.match(sent.at(-1).activity,/实际工具返回结果/);
const count=sent.length;reporter.finish('failed');reporter.record('OBSERVATION','late');
reporter.update({id:'root1',subtasks:[],phase:'running'});assert.equal(sent.length,count,'terminal lifecycle is immutable');
const split=[];const parent=new TaskReporter('root2','原始复合请求',started,s=>split.push(s));
parent.update({id:'root2',revision:1,title:'different split title',startedAt:started+20,endedAt:0,phase:'running',answer:'',subtasks:[
 {id:'s1',title:'摘要A',input:'实际完整子任务A',phase:'running',device:'算力设备1',detail:''},
 {id:'s2',title:'摘要B',input:'实际完整子任务B',phase:'queued',device:'',detail:''}]});
assert.equal(split.at(-1).id,'root2');assert.equal(split.at(-1).startedAt,started);assert.equal(split.at(-1).title,'原始复合请求');
assert(split.at(-1).revision>split[0].revision);assert.equal(split.at(-1).subtasks[0].input,'实际完整子任务A');
parent.finish('cancelled');assert(split.at(-1).subtasks.every(c=>c.phase==='cancelled'));
assert.equal(split[1].subtasks[0].phase,'running','cancelling cannot mutate a prior snapshot');
const oversized=[],large=new TaskReporter('large','中'.repeat(32768),started,s=>oversized.push(s));
large.finish('done','\u0001'.repeat(4096));
for(const snap of oversized){assert(Buffer.byteLength(JSON.stringify(snap))<=56000);assert(snap.inputTruncated);}
console.log('PASS: original task identity/input, tool lifecycle, terminal fence, split inputs, immutable snapshots and bounded UTF-8 display transport');
