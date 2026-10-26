const assert=require('node:assert/strict'),dashboard=require('./DashboardHarness.cjs');
const now=Date.now(),D1='算力设备1',D2='算力设备2';
const call=(id,extra={})=>({id,key:'chat-a:'+id,groupKey:'chat-a:root',subtaskId:'main',question:'不同的内部模型输入 '+id,input:'PRIVATE_INPUT_'+id,
 answer:'Action: 原始模型输出 '+id,source:D1,origin:'聊天设备1',chars:20,startedAt:now-10000,firstAt:now-8000,endedAt:now-5000,running:false,error:false,elapsedMs:5000,...extra});
const root=(extra={})=>({id:'root',key:'chat-a:root',title:'原始用户任务',input:'完整原始用户任务\n附件内容',origin:'聊天设备1',executor:D1,
 phase:'running',revision:1,startedAt:now-12000,endedAt:0,answer:'',subtasks:[],...extra});
const click=(h,attrs)=>h.elements.detail.handlers.click({target:h.target(attrs)});
const select=(h,key)=>{const target=h.target({'data-call':'true'});target.value=key;h.elements.detail.handlers.change({target});};
const tests=[],test=(name,body)=>tests.push([name,body]);
test('one end-to-end task survives changing model inputs and tool calls; details default to its final result',()=>{
 const h=dashboard(),group=root(),records=[call('one'),call('two',{startedAt:now-4000,elapsedMs:3000})];
 const event={kind:'dashboard',selfLabel:D1,jobs:records,groups:[group],devices:[]};h.window.onNativeEvent(event);
 assert.equal(h.elements.taskCount.textContent,'共 1 个任务');assert.match(h.elements.history.innerHTML,/原始用户任务/);
 assert.doesNotMatch(h.elements.history.innerHTML,/Action:|PRIVATE_INPUT|轮推理|第 \d+ 次/);
 assert.match(h.elements.history.innerHTML,/执行中/,'returned model calls do not finish a task still using tools');
 h.elements.history.handlers.click({target:h.target({'data-summary':group.key})});
 assert.match(h.elements.detailContent.textContent,/最终结果尚未返回/);
 click(h,{'data-tab':'input'});assert.equal(h.elements.detailContent.textContent,group.input);
 select(h,'chat-a:one');assert.equal(h.elements.detailContent.textContent,'PRIVATE_INPUT_one');
 click(h,{'data-tab':'output'});assert.equal(h.elements.detailContent.textContent,records[0].answer);
 assert.match(h.elements.detailMetrics.innerHTML,/5\.000s/);assert.match(h.elements.roundList.innerHTML,/<select/);
 assert.doesNotMatch(h.elements.roundList.innerHTML,/PRIVATE_INPUT|round-option/,'no expanded round card list');
 h.elements.detailContent.scrollTop=90;h.elements.detailContent.scrollHeight=400;h.elements.detailContent.clientHeight=100;h.elements.detailContent.handlers.scroll();
 records.push(call('three',{startedAt:now-500,endedAt:0,running:true,elapsedMs:500}));h.window.onNativeEvent(event);
 assert.equal(h.elements.detailContent.textContent,records[0].answer);assert.equal(h.elements.detailContent.scrollTop,90);
 select(h,'forged-other-task');assert.equal(h.elements.detailContent.textContent,records[0].answer);
 select(h,'');assert.match(h.elements.detailContent.textContent,/最终结果尚未返回/);
 group.phase='done';group.endedAt=now;group.answer='结合工具返回值生成的最终结果';group.activity='[ACTION] search\n查询参数\n[OBSERVATION] 工具返回内容';
 h.window.onNativeEvent(event);assert.equal(h.elements.detailContent.textContent,group.answer);
 assert.match(h.elements.history.innerHTML,/结合工具返回值生成的最终结果/);assert.equal(h.elements.taskCount.textContent,'共 1 个任务');
 click(h,{'data-tab':'runtime'});assert.match(h.elements.detailContent.textContent,/工具返回内容/);assert.match(h.elements.detailContent.textContent,/任务耗时：12\.0s/);
});
test('each split child is one end-to-end row with its own input and final answer',()=>{
 const h=dashboard(),group=root({phase:'merging',subtasks:[
  {id:'s1',title:'资料甲',input:'完整、可独立执行的甲任务',device:D1,phase:'done',result:'甲任务经过工具处理的最终结果',startedAt:now-9000,endedAt:now-2000,activity:'甲的工具记录'},
  {id:'s2',title:'资料乙',input:'完整、可独立执行的乙任务',device:D2,phase:'done',result:'乙任务最终结果'}]});
 const local=call('local',{subtaskId:'s1'}),remote=call('remote',{subtaskId:'s2',source:D2,elapsedMs:9000}),other=call('other',{groupKey:'chat-b:root',source:D2});
 const event={kind:'dashboard',selfLabel:D1,running:0,jobs:[local],remoteCalls:[remote,other],groups:[group]};h.window.onNativeEvent(event);
 assert.match(h.elements.history.innerHTML,/完整、可独立执行的甲任务/);assert.match(h.elements.history.innerHTML,/甲任务经过工具处理的最终结果/);
 assert.equal((h.elements.history.innerHTML.match(/data-result="s1"/g)||[]).length,1);assert.doesNotMatch(h.elements.history.innerHTML,/Action:|轮推理/);
 h.elements.history.handlers.click({target:h.target({'data-group':group.key,'data-result':'s1'})});
 assert.equal(h.elements.detailContent.textContent,group.subtasks[0].result);assert.match(h.elements.detailMetrics.innerHTML,/7\.0s/);
 click(h,{'data-tab':'input'});assert.equal(h.elements.detailContent.textContent,group.subtasks[0].input);
 select(h,remote.key);assert.equal(h.elements.detailContent.textContent,group.subtasks[0].input,'cannot jump to another child');
 select(h,local.key);assert.equal(h.elements.detailContent.textContent,local.input);
 h.document.handlers.keydown({key:'Escape'});h.elements.history.handlers.click({target:h.target({'data-summary':group.key})});
 select(h,remote.key);click(h,{'data-tab':'runtime'});assert.match(h.elements.detailContent.textContent,/执行：算力设备2/);
 select(h,other.key);assert.match(h.elements.detailContent.textContent,/请求ID：remote/);
 assert.match(h.elements.stats.innerHTML,/本机推理中<\/span><b>0/);
});
test('a participating worker keeps a single user task and receives its authoritative final answer',()=>{
 const h=dashboard(),group=root(),job=call('worker',{source:D2});
 const event={kind:'dashboard',selfLabel:D2,jobs:[job],groups:[group]};h.window.onNativeEvent(event);
 assert.equal(h.elements.taskCount.textContent,'共 1 个任务');assert.match(h.elements.history.innerHTML,/原始用户任务/);
 h.elements.history.handlers.click({target:h.target({'data-summary':group.key})});assert.match(h.elements.detailContent.textContent,/最终结果尚未返回/);
 group.phase='done';group.endedAt=now;group.answer='工具之后的最终回答';h.window.onNativeEvent(event);
 assert.equal(h.elements.detailContent.textContent,group.answer);assert.match(h.elements.history.innerHTML,/已完成/);
});
test('identical independent requests never merge, including requests from the same chat device',()=>{
 const h=dashboard(),a=root({phase:'done',endedAt:now,answer:'第一个结果'}),b=root({id:'root2',key:'chat-a:root2'});
 h.window.onNativeEvent({kind:'dashboard',selfLabel:D1,groups:[a,b],jobs:[call('one'),call('two',{groupKey:b.key})]});
 assert.equal(h.elements.taskCount.textContent,'共 2 个任务');assert.equal((h.elements.history.innerHTML.match(/data-summary=/g)||[]).length,2);
 h.window.onNativeEvent({kind:'dashboard',selfLabel:D1,groups:[],jobs:[call('legacy1',{groupKey:undefined}),call('legacy2',{groupKey:undefined})]});
 assert.equal(h.elements.taskCount.textContent,'共 2 个任务','legacy calls are not guessed from text and time');
});
test('partial results disclose display truncation and never invent a model timing',()=>{
 const h=dashboard(),group=root({phase:'partial',endedAt:now,subtasks:[{id:'s1',title:'远端子任务',device:D2,phase:'partial',result:'实际部分结果',resultTruncated:true}]});
 h.window.onNativeEvent({kind:'dashboard',selfLabel:D1,groups:[group],jobs:[]});
 h.elements.history.handlers.click({target:h.target({'data-group':group.key,'data-result':'s1'})});
 assert.match(h.elements.detailContent.textContent,/实际部分结果/);assert.match(h.elements.detailContent.textContent,/结果摘要/);
 assert.match(h.elements.detailMetrics.innerHTML,/未记录/);assert.doesNotMatch(h.elements.detailMetrics.innerHTML,/首字|本轮请求/);
});
test('timing distinguishes streaming first output from single-shot or unknown responses',()=>{
 const h=dashboard(),job=call('timed',{groupKey:undefined,metrics:{streaming:true,modelLoadMs:12.5,prefillMs:0,decodeMs:42,completionTokens:8}});
 const event={kind:'dashboard',selfLabel:D1,jobs:[job],groups:[]};h.window.onNativeEvent(event);
 h.elements.history.handlers.click({target:h.target({'data-detail':job.key})});
 assert.match(h.elements.detailMetrics.innerHTML,/首字<b>2\.000s/);assert.match(h.elements.detailMetrics.innerHTML,/5\.000s/);
 click(h,{'data-tab':'runtime'});assert.match(h.elements.detailContent.textContent,/模型加载：12\.5 ms/);
 assert.match(h.elements.detailContent.textContent,/Prefill：0\.0 ms/);assert.match(h.elements.detailContent.textContent,/输出 token：8/);
 job.metrics={streaming:false};h.window.onNativeEvent(event);
 assert.match(h.elements.detailMetrics.innerHTML,/首次返回/);assert.doesNotMatch(h.elements.detailMetrics.innerHTML,/首字/);
 assert.match(h.elements.detailContent.textContent,/首字等待：未采集/);assert.match(h.elements.detailContent.textContent,/引擎与回调统计：未采集/);
 delete job.metrics;h.window.onNativeEvent(event);assert.match(h.elements.detailContent.textContent,/输出方式：未记录/);
 assert.doesNotMatch(h.elements.detailMetrics.innerHTML,/首字/,'legacy metadata is not guessed');
});
test('millisecond differences stay visible and a single output is disclosed rather than faked',()=>{
 const h=dashboard(),job=call('precise',{groupKey:undefined,startedAt:now-4000,firstAt:now-397,endedAt:now-352,
   elapsedMs:3648,metrics:{streaming:true,outputChunks:2,firstOutputMs:3603,lastOutputMs:3620}});
 const event={kind:'dashboard',selfLabel:D1,jobs:[job],groups:[]};h.window.onNativeEvent(event);
 assert.match(h.elements.history.innerHTML,/3\.603s/);assert.match(h.elements.history.innerHTML,/3\.648s/);
 h.elements.history.handlers.click({target:h.target({'data-detail':job.key})});
 assert.match(h.elements.detailMetrics.innerHTML,/首字<b>3\.603s/);assert.match(h.elements.detailMetrics.innerHTML,/3\.648s/);
 h.window.onNativeEvent({kind:'text',requestId:job.id,text:job.answer});
 assert.match(h.elements.detailMetrics.innerHTML,/3\.648s/,'a final text refresh does not extend a completed request');
 job.metrics.outputChunks=1;job.metrics.lastOutputMs=3603;h.window.onNativeEvent(event);
 assert.match(h.elements.detailMetrics.innerHTML,/首段<b>3\.603s/);assert.doesNotMatch(h.elements.detailMetrics.innerHTML,/首字/);
 click(h,{'data-tab':'runtime'});assert.match(h.elements.detailContent.textContent,/非空输出分片：1/);
 assert.match(h.elements.detailContent.textContent,/逐 token 首字时间未采集/);
 assert.match(h.elements.detailContent.textContent,/原生首段等待：3603 ms/);
 job.error=true;h.window.onNativeEvent(event);
 assert.match(h.elements.detailMetrics.innerHTML,/首字/);
 assert.doesNotMatch(h.elements.detailContent.textContent,/首段与末段同批返回/,'an interrupted stream is not called a completed single output');
});
test('engine throughput uses token counts and stage milliseconds for each model call',()=>{
 const h=dashboard(),job=call('rate',{groupKey:undefined,metrics:{streaming:true,promptTokens:32,completionTokens:8,prefillMs:957.403,decodeMs:3991.724}});
 const event={kind:'dashboard',selfLabel:D1,jobs:[job],groups:[]};h.window.onNativeEvent(event);
 h.elements.history.handlers.click({target:h.target({'data-detail':job.key})});click(h,{'data-tab':'runtime'});
 assert.match(h.elements.detailContent.textContent,/Prefill 速度：33\.42 token\/s/);
 assert.match(h.elements.detailContent.textContent,/Decode 速度：2\.00 token\/s/);
 job.metrics.streaming=false;job.elapsedMs=80000;job.firstAt=now-1000;h.window.onNativeEvent(event);
 assert.match(h.elements.detailContent.textContent,/Prefill 速度：33\.42 token\/s/,'mode and end-to-end time do not change stage throughput');
 assert.match(h.elements.detailContent.textContent,/Decode 速度：2\.00 token\/s/);
 for(const invalid of [undefined,null,0,-1,NaN,Infinity,'1000']){
  job.metrics={streaming:true,promptTokens:32,prefillMs:invalid,completionTokens:8,decodeMs:2000};h.window.onNativeEvent(event);
  assert.match(h.elements.detailContent.textContent,/Prefill 速度：未采集/);
  assert.match(h.elements.detailContent.textContent,/Decode 速度：4\.00 token\/s/);
 }
 for(const invalid of [undefined,null,-1,0.5,NaN,Infinity,Number.MAX_SAFE_INTEGER+1,'8']){
  job.metrics={streaming:true,promptTokens:32,prefillMs:1000,completionTokens:invalid,decodeMs:2000};h.window.onNativeEvent(event);
  assert.match(h.elements.detailContent.textContent,/Decode 速度：未采集/);
 }
 job.metrics={streaming:true,promptTokens:0,prefillMs:1000,completionTokens:1,decodeMs:200000};h.window.onNativeEvent(event);
 assert.match(h.elements.detailContent.textContent,/Prefill 速度：0\.00 token\/s/);
 assert.match(h.elements.detailContent.textContent,/Decode 速度：<0\.01 token\/s/);
 job.metrics.decodeMs=Number.MIN_VALUE;h.window.onNativeEvent(event);
 assert.match(h.elements.detailContent.textContent,/Decode 速度：未采集/,'overflow never renders Infinity');
});
test('remote model calls keep separate throughput without inventing a task-wide average',()=>{
 const h=dashboard(),group=root(),a=call('rate-a',{metrics:{streaming:true,promptTokens:100,prefillMs:1000,completionTokens:10,decodeMs:2000}}),
  b=call('rate-b',{source:D2,metrics:{streaming:false,promptTokens:200,prefillMs:1000,completionTokens:30,decodeMs:2000}});
 h.window.onNativeEvent({kind:'dashboard',selfLabel:D1,groups:[group],jobs:[a],remoteCalls:[b]});
 h.elements.history.handlers.click({target:h.target({'data-summary':group.key})});click(h,{'data-tab':'runtime'});
 assert.doesNotMatch(h.elements.detailContent.textContent,/token\/s/);
 select(h,a.key);assert.match(h.elements.detailContent.textContent,/Prefill 速度：100\.00 token\/s/);
 assert.match(h.elements.detailContent.textContent,/Decode 速度：5\.00 token\/s/);
 select(h,b.key);assert.match(h.elements.detailContent.textContent,/Prefill 速度：200\.00 token\/s/);
 assert.match(h.elements.detailContent.textContent,/Decode 速度：15\.00 token\/s/);
});
let passed=0;for(const [name,body]of tests){try{body();passed++;console.log('PASS '+name);}catch(e){console.error('FAIL '+name,e);process.exitCode=1;}}
console.log(passed+'/'+tests.length+' end-to-end task detail scenarios passed');
