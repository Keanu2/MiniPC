// Executes display transport and the local host using controlled senders; no SDK build.
const assert=require('node:assert/strict');
const path=require('node:path');
const vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},Date,Map,Set,Math,Number,Array,JSON,Promise,Error,setTimeout,clearTimeout};vm.runInNewContext(transpile(file),box);return box.exports;}
const util={TextEncoder:class{encodeInto(text){return Buffer.from(text,'utf8')}}};
const protocol=load(path.resolve(__dirname,'../../entry/src/main/ets/protocol/ChatProtocol.ets'),{'@kit.ArkTS':{util}});
const sent=[];let release;
const channel={readyEpoch:()=>8,send(message,epoch){sent.push([JSON.parse(JSON.stringify(message)),epoch]);return new Promise(resolve=>{release=resolve})}};
const {inferenceClient:client}=load(path.resolve(__dirname,'../../entry/src/main/ets/model/InferenceClient.ets'),{
  '../nearby/LinkEnhanceChannel':{nearbyChannel:channel},'../protocol/ChatProtocol':protocol,
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},'./InferenceWire':{utf8Bytes:text=>Buffer.from(text),sha256Hex:()=>''}
});
const task=(revision,extra={})=>({id:'task1',title:'两个子任务',phase:'running',revision,startedAt:1000,endedAt:0,answer:'',subtasks:[{id:'s1',title:'一',device:'',phase:'queued',detail:'等待'},{id:'s2',title:'二',device:'算力设备2',phase:'running',detail:'生成中'}],...extra});
const flush=async()=>{for(let i=0;i<10;i++)await Promise.resolve()};
(async()=>{
  client.profile={ready:true};client.profileEpoch=7;
  client.publishTask(task(1));client.publishTask(task(2));client.publishTask(task(3));
  assert.equal(sent.length,1);assert.equal(sent[0][1],7);assert.equal(sent[0][0].task.revision,1);
  release(true);await flush();assert.equal(sent.length,2);assert.equal(sent[1][0].task.revision,3,'superseded updates coalesce');
  release(false);await flush();assert.equal(sent.length,3,'one bounded display retry');
  release(false);await flush();assert.equal(client.deliveringTasks,false);
  client.reset();client.profile={ready:true};client.profileEpoch=8;
  client.publishTask(task(4));assert.equal(sent.length,3,'old task cannot move onto reconnected epoch');
  client.publishTask({...task(1),id:'task2'});assert.equal(sent.length,4);assert.equal(sent[3][1],8);release(true);await flush();
  client.publishTask({...task(1),id:'lost_delivery'});const abandoned=release;
  client.reset();client.profile={ready:true};client.profileEpoch=9;
  const before=sent.length;client.publishTask({...task(1),id:'new_session'});
  assert.equal(sent.length,before+1,'an unresolved old send cannot block the next session');
  assert.equal(sent.at(-1)[1],9);release(true);await flush();abandoned(true);await flush();
  assert.equal(client.deliveringTasks,false);
  client.profile={ready:true,promptFormat:'plain',maxPromptBytes:32768,maxOutputTokens:128};client.profileEpoch=8;
  client.deliver=(request,epoch)=>{sent.push([request,epoch]);return true};
  const pending=client.complete('q',{owner:'child',taskId:'task2',subtaskId:'s1',label:'子任务 1/2'},null);
  const request=sent.at(-1)[0];assert.equal(request.taskId,'task2');assert.equal(request.subtaskId,'s1');
  let route=client.routingCalls()[0];assert.equal(route.phase,'sending');assert.equal(route.device,'');
  client.onMessage({type:'infer.accepted',requestId:request.requestId,device:'算力设备2'},999);
  assert.equal(client.routingCalls()[0].device,'','stale acceptance cannot change the route');
  client.onMessage({type:'infer.accepted',requestId:request.requestId,device:'算力设备2'},8);
  route=client.routingCalls()[0];assert.equal(route.device,'算力设备2');assert.equal(route.phase,'running');
  client.onMessage({type:'infer.status',requestId:request.requestId,state:'queued'},999);
  assert.equal(client.routingCalls()[0].phase,'running','stale status cannot change the route');
  // Settle the model promise without starting a platform model.
  const call=client.calls.get(request.requestId);clearTimeout(call.timer);client.calls.delete(request.requestId);call.resolve('ok');assert.equal(await pending,'ok');assert.equal(client.routingCalls().length,0,'completed calls leave the live route');
  const first=client.complete('并发一',{owner:'parallel-one'}).catch(error=>error.message);
  const firstId=sent.at(-1)[0].requestId;
  const second=client.complete('并发二',{owner:'parallel-two'});
  const secondId=sent.at(-1)[0].requestId;
  assert.notEqual(firstId,secondId);assert.equal(client.calls.size,2,'actual client sends two requests before either completes');
  client.cancelOwner('parallel-one');assert.equal(client.calls.has(secondId),true,'owner cancellation leaves the other request active');
  client.onMessage({type:'infer.error',requestId:firstId},8);
  const secondCall=client.calls.get(secondId);clearTimeout(secondCall.timer);client.calls.delete(secondId);secondCall.resolve('第二条完成');
  assert.equal(await first,'已停止生成');assert.equal(await second,'第二条完成');
  const hostSent=[];let shown;
  const {InferenceHost,InferCardHooks}=load(path.resolve(__dirname,'../../../../apps/compute-node/entry/src/main/ets/llm/InferenceHost.ets'),{
    './QwenVlManager':{QwenVlManager:{getInstance:()=>({isBusy:()=>false,unloadIfIdle(){}})}},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){}}},'./InferenceWire':{utf8Bytes:text=>Buffer.from(text),sha256Hex:()=>''}
  });
  const model={readinessError:()=>'',isBusy:()=>false,start(){return ''},cancel(){}};const card=new InferCardHooks();card.begin=(...args)=>{shown=args};
  const host=new InferenceHost(model,(m,e)=>{hostSent.push([m,e]);return Promise.resolve(true)},card);host.setDeviceProvider(()=> '算力设备1');
  host.handle({type:'infer.request',requestId:'r',prompt:'问题'},7);
  assert.equal(hostSent.find(([m])=>m.type==='infer.accepted')[0].device,'算力设备1');assert(shown);
  console.log('PASS: snapshot coalescing, send failure isolation, reconnect epochs, real request metadata, and local accepted-device identity');
})().catch(error=>{console.error(error);process.exitCode=1});
