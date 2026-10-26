const assert=require('node:assert/strict');
const path=require('node:path');
const vm=require('node:vm');
const {transpile}=require('../../../../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},Date,Map,Set,Math,Number,Array,JSON};vm.runInNewContext(transpile(file),box);return box.exports;}
const util={TextEncoder:class{encodeInto(text){return Buffer.from(text,'utf8')}},TextDecoder:{create:()=>({decodeToString:bytes=>Buffer.from(bytes).toString('utf8')})},Base64Helper:class{encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64')}decodeSync(text){return new Uint8Array(Buffer.from(text,'base64'))}}};
const protocol=load(path.join(__dirname,'../protocol/ChatProtocol.ets'),{'@kit.ArkTS':{util}});
const clientProtocol=load(path.resolve(__dirname,'../../../../../../../apps/agent-client/entry/src/main/ets/protocol/ChatProtocol.ets'),{'@kit.ArkTS':{util}});
const {TaskBoard}=load(path.join(__dirname,'TaskBoard.ets'),{'../protocol/ChatProtocol':protocol});
const clone=x=>JSON.parse(JSON.stringify(x));
const snapshot=(patch={})=>({id:'parent_1',title:'比较两种模型',phase:'running',revision:1,startedAt:1000,endedAt:0,answer:'',subtasks:[{id:'s1',title:'模型A特点',device:'',phase:'queued',detail:'排队中'},{id:'s2',title:'模型B特点',device:'算力设备2',phase:'running',detail:'生成中'}],...patch});
for(const api of [protocol,clientProtocol]){
  assert(api.validTaskSnapshot(snapshot()));
  for(const patch of [{id:''},{revision:0},{revision:1.5},{startedAt:NaN},{subtasks:[snapshot().subtasks[0]]},{subtasks:[snapshot().subtasks[0],snapshot().subtasks[0]]},{phase:'done',endedAt:2000},{endedAt:500},{title:'x'.repeat(1001)}])assert(!api.validTaskSnapshot(snapshot(patch)),JSON.stringify(patch));
  const bad=snapshot();bad.subtasks[1].device='手机真名';assert(!api.validTaskSnapshot(bad));
  const frame={protocol:'nearby-chat-v1',type:'infer.task',version:2,requestId:'parent_1',task:snapshot()};assert(api.validMessage(frame));
  assert(!api.validMessage({...frame,requestId:'wrong'}));assert(!api.validMessage({...frame,task:null}));
  const parts=api.encodeMessage(clone(frame),'group_msg');const assembler=new api.MessageAssembler();let result;for(const part of parts)result=assembler.receive(part)||result;assert.equal(result.task.subtasks[1].device,'算力设备2');
  const req={protocol:'nearby-chat-v1',type:'infer.request',requestId:'r',taskId:'parent_1',subtaskId:'s2',prompt:'q'};assert(api.validMessage(req));assert(!api.validMessage({...req,subtaskId:undefined}));
}
const board=new TaskBoard();assert(board.accept(snapshot(),1,'聊天设备1','算力设备1'));assert(board.accept(snapshot(),2,'聊天设备2','算力设备1'));assert.equal(board.views().length,2);
assert(!board.accept(snapshot(),1,'聊天设备1','算力设备1'),'duplicate revision');
assert(!board.accept(snapshot({revision:2,title:'换成另一个任务'}),1,'聊天设备1','算力设备1'),'cannot change parent');
const done=snapshot({revision:3,phase:'done',endedAt:2000,answer:'汇总结果'});for(const child of done.subtasks){child.phase='done';child.result='真实返回内容';child.device='算力设备2';}
assert(board.accept(done,1,'聊天设备1','算力设备1'));assert.equal(board.views().find(t=>t.originEpoch===1).executor,'算力设备1');
assert(!board.accept(snapshot({revision:99}),1,'聊天设备1','算力设备1'),'late update cannot reopen terminal group');
board.clearFinished();assert.equal(board.views().length,1);assert(!board.accept(done,1,'聊天设备1','算力设备1'),'cleared history stays cleared');
board.disconnect(2);assert.equal(board.views()[0].phase,'cancelled');assert(board.views()[0].subtasks.every(t=>t.phase==='cancelled'));
console.log('PASS: both wire endpoints, snapshot bounds and fragmentation, request correlation, session isolation, immutable terminal state, history clear and disconnect');

const lifecycle=new TaskBoard(),begin=snapshot({subtasks:[],input:'完整原始输入'});
assert(lifecycle.accept(begin,1,'聊天设备1','算力设备1'));
assert(lifecycle.accept(snapshot({revision:2,input:begin.input}),1,'聊天设备1','算力设备1'),'a declared user task can become split');
assert(!lifecycle.accept(snapshot({revision:3,subtasks:[]}),1,'聊天设备1','算力设备1'),'accepted split identities cannot disappear');
const single=new TaskBoard();assert(single.accept(begin,2,'聊天设备2','算力设备1'));
assert(single.accept({...begin,revision:2,phase:'done',endedAt:2000,answer:'工具调用之后的最终结果',activity:'工具记录'},2,'聊天设备2','算力设备1'));
assert.equal(single.views()[0].input,'完整原始输入');assert.equal(single.views()[0].activity,'工具记录');
console.log('PASS: ordinary task lifecycle, split upgrade and original inputs');
