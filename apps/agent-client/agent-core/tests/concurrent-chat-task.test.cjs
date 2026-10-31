const assert=require('node:assert/strict'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},Promise,Date,Math,Map,Set,Number,Array,JSON,Error};vm.runInNewContext(transpile(path.resolve(__dirname,file)),box);return box.exports;}
const core=load('../src/main/ets/agent/ConversationContext.ets');
const calls=[],cancels=[],tasks=[],registries=[],runners=[],parallelRuns=[];let toolGate=null,skillGate=null,handled=false;
function deferred(){let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};}
const client={promptBudgetBytes:()=>32768,clusterLoad:()=>({idle:3,total:3}),publishTask:s=>tasks.push(s),
 complete(prompt,hooks,split,image){const d=deferred(),call={prompt,hooks,image,d,settled:false};calls.push(call);hooks.onStart?.();return d.promise;},
 cancelOwner(owner){cancels.push(owner);for(const call of calls)if(!call.settled&&call.hooks.owner===owner){call.settled=true;call.d.reject(new Error('已停止生成'));}}
};
const wire={utf8Bytes:s=>Buffer.from(s,'utf8')};
const reporter=load('../../entry/src/main/ets/model/TaskReporter.ets',{'./InferenceWire':wire});
const plain=load('../../entry/src/main/ets/model/PlainChat.ets',{'./InferenceWire':wire});
const kinds={ACTION:'action',OBSERVATION:'observation',FINAL:'final',ERROR:'error',THOUGHT:'thought',SKILL:'skill'};
class Runner{constructor(model,tools){this.model=model;this.tools=tools;runners.push(this);}requestStop(){this.model.cancel();}async run(task,listener,history,context){this.context=context;listener({kind:kinds.ACTION,text:'调用',toolName:'weather'});const answer=await this.model.complete(task);listener({kind:kinds.FINAL,text:answer,status:this.partial?'partial':undefined});}}
class Parallel{constructor(deps){this.deps=deps;}requestStop(){}async tryRun(task,history,observer,listener){parallelRuns.push(task);if(!handled)return false;listener({kind:kinds.FINAL,text:'合并 '+task});return true;}}
const agent={...core,AgentEventKind:kinds,PARTIAL_FINAL_STATUS:'partial',ReActAgentRunner:Runner,ParallelTaskRunner:Parallel,splitReActPrompt:()=>null,
 createSkillSnapshot:()=>skillGate?skillGate.promise:Promise.resolve({}),
 createConfiguredLoopToolRegistry:()=>{if(toolGate)return toolGate.promise;const tools={closed:0,async close(){this.closed++;}};registries.push(tools);return Promise.resolve(tools);}};
const remote=load('../../entry/src/main/ets/model/RemoteComputeModel.ets',{'@loop/agent-core':agent,'./InferenceClient':{inferenceClient:client}});
const {ConcurrentChatTask}=load('../../entry/src/main/ets/model/ConcurrentChatTask.ets',{'@loop/agent-core':agent,'./InferenceClient':{inferenceClient:client,INFERENCE_STOPPED:'已停止生成'},'./RemoteComputeModel':remote,'./TaskReporter':reporter,'./PlainChat':plain});
function create(id,mode='chat',ready=async()=>true,imagePayload=''){const updates=[];const run=new ConcurrentChatTask({id,task:id,display:id,imagePayload,mode,context:{},conversation:new core.ConversationContext()},ready,state=>updates.push(state));return {run,updates};}
async function tick(){for(let i=0;i<25;i++)await Promise.resolve();}
function resolve(call,answer){call.settled=true;call.d.resolve(answer);}
(async()=>{
 const a=create('a'),b=create('b'),start=calls.length;const pa=a.run.run(),pb=b.run.run();await tick();assert.equal(calls.length-start,2,'second model call starts before first answer');
 assert.notEqual(calls[start].hooks.owner,calls[start+1].hooks.owner);calls[start].hooks.onAccepted('算力设备1');calls[start+1].hooks.onAccepted('算力设备2');
 calls[start].hooks.onDelta('A片段');calls[start+1].hooks.onDelta('B片段');assert.equal(a.updates.at(-1).answer,'A片段');assert.equal(b.updates.at(-1).answer,'B片段');
 resolve(calls[start+1],'B完成');await pb;assert.equal(b.updates.at(-1).phase,'done');assert.equal(a.updates.at(-1).device,'算力设备1');
 a.run.cancel();await pa;assert.equal(a.updates.at(-1).phase,'cancelled');assert.ok(cancels.includes('a:main'));assert.ok(!cancels.includes('b:main'));
 const count=a.updates.length;calls[start].hooks.onDelta('过期');assert.equal(a.updates.length,count);
 const ready=deferred(),c=create('c','chat',()=>ready.promise);const pc=c.run.run();c.run.cancel();await pc;const before=calls.length;ready.resolve(true);await tick();assert.equal(calls.length,before);
 const fail=create('fail','chat',async()=>false);await fail.run.run();assert.equal(fail.updates.at(-1).phase,'failed');
 const img=create('image','chat',async()=>true,'base64');const pi=img.run.run();await tick();assert.equal(calls.at(-1).image,'base64');resolve(calls.at(-1),'图片答案');await pi;
 const d=create('d','agent'),e=create('e','agent');const pd=d.run.run(),pe=e.run.run();await tick();const dc=calls.at(-2),ec=calls.at(-1);assert.notEqual(runners.at(-2).tools,runners.at(-1).tools);
 d.run.cancel();await pd;assert.equal(runners.at(-2).tools.closed,1);assert.equal(runners.at(-1).tools.closed,0,'other task keeps its tool registry');resolve(ec,'E完成');await pe;
 assert.equal(e.updates.at(-1).phase,'done');assert.equal(runners.at(-1).tools.closed,1);assert.notEqual(runners.at(-2).context.namespace,runners.at(-1).context.namespace);
 handled=true;const split=create('split','agent_split');await split.run.run();assert.equal(split.updates.at(-1).answer,'合并 split');assert.ok(parallelRuns.includes('split'));handled=false;
 const partial=create('partial','agent');const pp=partial.run.run();await tick();runners.at(-1).partial=true;resolve(calls.at(-1),'部分答案');await pp;assert.equal(partial.updates.at(-1).phase,'partial');
 toolGate=deferred();const late=create('late-tools','agent'),pl=late.run.run();await tick();late.run.cancel();await pl;let closed=0;toolGate.resolve({async close(){closed++;}});toolGate=null;await tick();assert.equal(closed,1,'late registry closes after cancellation');
 skillGate=deferred();const skills=create('late-skills','agent'),ps=skills.run.run();await tick();skills.run.cancel();await ps;const oldSkillGate=skillGate;skillGate=null;const registryCount=registries.length;oldSkillGate.resolve({});await tick();assert.equal(registries.length,registryCount);
 const empty=create('empty'),px=empty.run.run();await tick();resolve(calls.at(-1),'  ');await px;assert.equal(empty.updates.at(-1).phase,'failed');
 assert.equal(tasks.filter(s=>s.id==='a'&&s.phase==='cancelled').length,1,'exactly one terminal display snapshot');
 console.log('PASS actual per-task runtime: concurrent inference, independent stream/device/owners/tools, cancel fencing, late setup cleanup, plain/image/Agent/split/partial/failure');
})().catch(e=>{console.error(e);process.exitCode=1;});
