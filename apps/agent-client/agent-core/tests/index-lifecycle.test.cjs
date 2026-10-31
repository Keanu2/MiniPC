// Executes actual Index methods, excluding ArkUI-only rendering DSL. No device/network I/O.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let ts;
for (const p of [process.env.TYPESCRIPT_PATH, 'typescript', 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { ts = require(p); break; } catch {}
}
if (!ts) throw new Error('Set TYPESCRIPT_PATH to the local compiler module');
const {transpile}=require('../../../../tests/ets-harness.cjs');
const reporterBox={exports:{},require:name=>name==='./InferenceWire'?{utf8Bytes:s=>Buffer.from(s)}:{},Date,Math,JSON};
vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/model/TaskReporter.ets')),reporterBox);
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8').replace(/\r\n?/g, '\n');
const names = ['aboutToAppear','aboutToDisappear','ensureRemoteReady','isCurrentRemoteRun','runRemoteAgent','stopGeneration','changeChatMode','changeAgentMode','beginTaskProgress','updateTaskProgress'];
function method(name) {
  const startPattern = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm');
  // Build the literal opening parenthesis without depending on a regex escape in the transport.
  const lines = source.split(String.fromCharCode(10));
  const start = lines.findIndex(line => ['  '+name+'(', '  private '+name+'(', '  private async '+name+'('].some(p => line.startsWith(p)));
  assert.ok(start >= 0, 'Missing actual method ' + name);
  let end = start + 1;
  while (end < lines.length && lines[end] !== '  }') end++;
  assert.ok(end < lines.length, 'Missing method end ' + name);
  return lines.slice(start, end + 1).join(String.fromCharCode(10));
}
const classSource = 'class Page { ' + names.map(method).join(String.fromCharCode(10)) + ' } exports.Page = Page;';
const compiled = ts.transpileModule(classSource, {fileName:'IndexMethods.ts', compilerOptions:{target:ts.ScriptTarget.ES2020, module:ts.ModuleKind.CommonJS}, reportDiagnostics:true});
assert.deepEqual((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).map(d=>ts.flattenDiagnosticMessageText(d.messageText,' ')), []);
function deferred() { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a; reject=b;}); return {promise,resolve,reject}; }
async function drain() { for(let i=0;i<12;i++) await Promise.resolve(); }
function harness(options={}) {
  const records={construct:0,runs:0,stops:0,commits:[],saved:0,lines:[],events:[],setup:[],reset:0,hooks:[],phases:[],plain:[],settings:[],skills:0,registries:0};
  const client={publishTask(snapshot){(records.tasks??=[]).push(snapshot)},ensureReady:()=>options.negotiate?.promise??Promise.resolve(''),promptBudgetBytes:()=>32768,cancelActive(){records.setup.push('cancel');},reset(){records.reset++;},bind(){},setLinkListener(fn){this.link=fn;}};
  client.complete=async(prompt,hooks,split,image)=>{records.plain.push(prompt);records.plainImage=image;records.hooks.push(hooks);hooks.onStart?.();if(options.plain) return options.plain.promise;hooks.onDelta?.('普通');return '普通回答';};
  const channel={initialize(){},resume(){},isConnected:()=>true,inferenceReady:()=>true,disconnect(){records.setup.push('disconnect');},prepare:()=>Promise.resolve(),computeDevices:()=>Promise.resolve()};
  class Runner {constructor(){records.construct++;} requestStop(){records.stops++;} async run(task,listener){records.runs++; records.listener=listener; if(options.runner) await options.runner.promise; listener({kind:'FINAL',text:task+' answer',status:options.finalStatus}); if(options.duplicateFinal) listener({kind:'FINAL',text:'duplicate'});}}
  const sandbox={exports:{},setInterval:()=>0,clearInterval(){},Edge:{Bottom:1},TaskReporter:reporterBox.exports.TaskReporter,taskProgressActive:phase=>phase==='preparing'||phase==='running',MAX_STEPS:10,INFERENCE_STOPPED:'已停止生成',BubbleKind:{ERROR:1,LOOP:2,TASK:3},AgentEventKind:{ACTION:'ACTION',OBSERVATION:'OBSERVATION',SKILL:'SKILL',THOUGHT:'THOUGHT',FINAL:'FINAL',ERROR:'ERROR'},PARTIAL_FINAL_STATUS:'partial',PARTIAL_HISTORY_NOTE:'（上一轮未得到完整回答）',LIVE_PLACEHOLDER:'正在生成…',LIVE_TOOL_PREFIX:'正在调用工具：',LIVE_COMPOSING:'正在整理工具结果…',inferenceClient:client,nearbyChannel:channel,ReActAgentRunner:Runner,RemoteComputeModel:class {constructor(hooks){records.hooks.push(hooks);}setImage(image){records.images=(records.images||0)+1;if(options.image)assert.equal(image,options.image);}},saveConversation(){records.saved++;},createSkillSnapshot:()=>options.skill?.promise??Promise.resolve({}),createConfiguredLoopToolRegistry:()=>Promise.resolve({close:async()=>{}}),ensureBundledWorkspaceFiles:()=>Promise.resolve()};
  Object.assign(sandbox,{
    loadAgentEnabled:()=>options.storedAgent??false,
    saveAgentEnabled:async(_context,value)=>{records.settings.push(value);},
    loadChatMode:()=>options.storedMode??(options.storedAgent?'agent_split':'chat'),
    saveChatMode:async(_context,mode)=>{records.settings.push(mode!=='chat');records.modes=(records.modes||[]).concat(mode);},
    buildPlainChatPrompt:(task,budget)=>{records.plainBudget=budget;return task;},
    createSkillSnapshot:()=>{records.skills++;return options.skill?.promise??Promise.resolve({});},
    createConfiguredLoopToolRegistry:()=>{records.registries++;return Promise.resolve({close:async()=>{}});}
  });
  vm.runInNewContext(compiled.outputText,sandbox);
  const p=new sandbox.exports.Page();
  Object.assign(p,{messages:[],nextChatBubbleId:1,activeTaskProgressId:-1,scroller:{scrollEdge(){}},createChatBubble(speaker,text,kind){return {id:this.nextChatBubbleId++,speaker,text,kind,imagePath:'',collapsible:false,expanded:false,revision:0};},pageActive:true,remoteRunGeneration:0,stopRequested:false,sending:false,message:'',skillSnapshot:options.skill?null:{},toolRegistryIncludesSkills:true,toolRegistryPromise:options.tools?.promise??Promise.resolve({close:async()=>{}}),activeRunner:null,liveReplyId:-1,liveReplyPending:false,processId:-1,collabController:null,conversation:{turns:[],addUser(x){this.turns.push(['user',x]);},addAssistant(x){this.turns.push(['assistant',x]);}},getAbilityContext:()=>({}),setCollaborationKeepScreenOn(){},refreshLinkChrome(){},appendLine(...x){records.lines.push(x);},appendUserMessage(){},appendProcess(e){records.events.push(e);},finishInferenceMetricsTask(){},formatElapsed:()=>'1.0 秒',commitLiveAnswer(x){records.commits.push(x);},dropLivePlaceholder(){this.liveReplyId=-1;},beginLiveReply(){records.setup.push('placeholder');},showLiveReply(){records.setup.push('preview');},addEvent(e){records.events.push(e);},disposeSingleDeviceSession(){},restoreConversation(){},initializeTabletSessions(){},restoreTabletSessions(){},persistTabletSessions(){},buildRemoteConversation(){return this.conversation;},setLivePhase(x){records.phases.push(x);},parallelObserver(){return {};},createParallelRunner(){return {requestStop(){records.parallelStops=(records.parallelStops||0)+1;},async tryRun(task,conversation,observer,listener){records.parallelTries=(records.parallelTries||0)+1;if(!options.parallel)return false;listener({kind:'FINAL',text:'merged '+task,status:options.parallel==='partial'?'partial':undefined});return true;}};}});
  if(options.ready) p.ensureRemoteReady=()=>options.ready.promise;
  p.agentEnabled=options.agentEnabled??true;
  p.chatMode=options.chatMode??(p.agentEnabled?'agent_split':'chat');
  p.conversation.toChatMessages=()=>p.conversation.turns.map(([role,content])=>({role,content}));
  return {p,client,channel,records};
}
const tests=[]; const test=(name,fn)=>tests.push([name,fn]);
test('ordinary chat streams and saves once without constructing any Agent services',async()=>{
 const h=harness({agentEnabled:false});h.p.skillSnapshot=null;h.p.toolRegistryPromise=null;h.p.toolRegistryIncludesSkills=false;
 await h.p.runRemoteAgent('task with attachment excerpt','shown','');
 assert.deepEqual(h.records.plain,['task with attachment excerpt']);assert.deepEqual(h.records.commits,['普通','普通回答']);
 assert.equal(h.records.tasks[0].phase,'running');assert.equal(h.records.tasks.at(-1).phase,'done');
 assert.equal(h.records.tasks.at(-1).input,'task with attachment excerpt');assert.equal(h.records.tasks.at(-1).answer,'普通回答');
 assert.equal(h.records.hooks[0].taskId,h.records.tasks[0].id);
 assert.equal(h.records.construct,0);assert.equal(h.records.skills,0);assert.equal(h.records.registries,0);assert.equal(h.records.parallelTries,undefined);
 assert.equal(h.records.saved,1);assert.equal(h.p.sending,false);assert.deepEqual(h.p.conversation.turns,[['user','shown'],['assistant','普通回答']]);
});
test('ordinary chat never reads saved conversation, including consecutive turns',async()=>{
 const h=harness({agentEnabled:false});h.p.conversation.turns=[['user','旧问题'],['assistant','旧答案']];
 h.p.buildRemoteConversation=()=>{throw new Error('ordinary chat must not read history');};
 await h.p.runRemoteAgent('第一轮\n附件正文','第一轮','');await h.p.runRemoteAgent('第二轮','第二轮','');
 assert.deepEqual(h.records.plain,['第一轮\n附件正文','第二轮']);assert.equal(h.records.plainBudget,32768);
 assert.equal(h.records.saved,2);assert.equal(h.p.conversation.turns.length,6);
});
test('ordinary chat stop ignores late streaming and final, then allows Agent mode',async()=>{
 const d=deferred(),h=harness({agentEnabled:false,plain:d});const old=h.p.runRemoteAgent('q','q','');await drain();
 h.p.changeAgentMode(true);assert.equal(h.p.agentEnabled,false);h.p.stopGeneration();h.p.changeAgentMode(true);
 const next=h.p.runRemoteAgent('new','new','');await drain();h.records.hooks[0].onDelta('stale');d.resolve('stale final');await old;await next;
 assert.deepEqual(h.records.commits,['new answer']);assert.equal(h.records.saved,1);assert.equal(h.records.runs,1);assert.deepEqual(h.records.settings,[true]);
});
test('ordinary chat passes this turn image to inference without creating Agent services',async()=>{
 const h=harness({agentEnabled:false});await h.p.runRemoteAgent('图中是什么','图中是什么','preview.jpg','/9j/4AAQSkZJRg==');
 assert.equal(h.records.plainImage,'/9j/4AAQSkZJRg==');assert.equal(h.records.construct,0);assert.equal(h.records.skills,0);
 await h.p.runRemoteAgent('新问题','新问题','');assert.equal(h.records.plainImage,'');assert.deepEqual(h.records.plain,['图中是什么','新问题']);
});
test('ordinary chat disposal ignores late results',async()=>{
 const d=deferred(),h=harness({agentEnabled:false,plain:d});const run=h.p.runRemoteAgent('q','q','');await drain();
 h.p.aboutToDisappear();h.records.hooks[0].onDelta('late');d.resolve('late');await run;
 assert.deepEqual(h.records.commits,[]);assert.equal(h.records.saved,0);assert.equal(h.records.reset,1);
});
test('ordinary chat failure and empty result are not saved and release sending',async()=>{
 for(const fail of [true,false]){const d=deferred(),h=harness({agentEnabled:false,plain:d});const run=h.p.runRemoteAgent('q','q','');await drain();
 if(fail)d.reject(new Error('connection lost'));else d.resolve('  ');await run;
 assert.equal(h.records.saved,0);assert.equal(h.p.sending,false);assert.equal(h.records.lines[0][0],'Error');}
});
test('startup restores mode without eagerly initializing tools',async()=>{
 for(const storedAgent of [false,true]){const h=harness({storedAgent});h.p.aboutToAppear();await drain();assert.equal(h.p.agentEnabled,storedAgent);assert.equal(h.records.registries,0);}
});
test('mode changes preserve history and switching back to ordinary chat skips Agent',async()=>{
 const h=harness();let closed=0;h.p.toolRegistryPromise=Promise.resolve({close:async()=>{closed++;}});
 await h.p.runRemoteAgent('agent','agent','');h.p.changeAgentMode(false);await h.p.runRemoteAgent('chat','chat','');
 assert.deepEqual(h.records.settings,[false]);assert.equal(h.records.runs,1);assert.equal(h.records.plain.length,1);assert.equal(h.p.conversation.turns.length,4);
 assert.equal(closed,1);assert.equal(h.p.toolRegistryPromise,null);assert.equal(h.p.toolRegistryIncludesSkills,false);
 assert.deepEqual(h.records.plain,['chat']);
});
for(const stage of ['ready','negotiate','skill','tools']) test('stop during '+stage+' prevents runner dispatch',async()=>{
 const d=deferred(), h=harness({[stage]:d}); const run=h.p.runRemoteAgent('task','task',''); await drain(); h.p.stopGeneration(); d.resolve(stage==='ready'?true:stage==='negotiate'?'':stage==='tools'?{close:async()=>{}}:{}); await run;
 assert.equal(h.records.construct,0); assert.equal(h.records.saved,0); assert.equal(h.records.commits.length,0); assert.equal(h.p.sending,false);
});
test('stop during runner suppresses late observation and final',async()=>{
 const d=deferred(),h=harness({runner:d}); const run=h.p.runRemoteAgent('task','task','');await drain();assert.equal(h.records.runs,1);h.p.stopGeneration();h.records.listener({kind:'OBSERVATION',text:'late'});d.resolve();await run;assert.equal(h.records.stops,1);assert.equal(h.records.commits.length,0);assert.equal(h.records.events.length,0);assert.equal(h.records.saved,0);
});
test('dispose invalidates runner events and history commit',async()=>{
 const d=deferred(),h=harness({runner:d});const run=h.p.runRemoteAgent('task','task','');await drain();h.p.aboutToDisappear();d.resolve();await run;assert.equal(h.p.pageActive,false);assert.equal(h.records.stops,1);assert.equal(h.records.saved,0);assert.equal(h.records.commits.length,0);assert.equal(h.records.reset,1);
});
test('old preparation finalizer does not disturb the replacement run',async()=>{
 const first=deferred(),next=deferred(),h=harness({runner:next});let n=0;h.p.ensureRemoteReady=()=>++n===1?first.promise:Promise.resolve(true);const old=h.p.runRemoteAgent('old','old','');await drain();h.p.stopGeneration();const fresh=h.p.runRemoteAgent('new','new','');await drain();first.resolve(true);await old;assert.equal(h.p.sending,true);assert.equal(h.records.hooks.length,1);next.resolve();await fresh;assert.deepEqual(h.records.commits,['new answer']);assert.equal(h.records.saved,1);
});
test('superseded run model hooks cannot drive the current placeholder',async()=>{
 const d=deferred(),h=harness({runner:d});
 const old=h.p.runRemoteAgent('old','old','');await drain();assert.equal(h.records.hooks.length,1);h.p.stopGeneration();
 const fresh=h.p.runRemoteAgent('new','new','');await drain();assert.equal(h.records.hooks.length,2);
 h.records.setup.length=0;h.records.hooks[0].onStart();h.records.hooks[0].onDelta('stale');assert.deepEqual(h.records.setup,[]);
 h.records.hooks[1].onStart();h.records.hooks[1].onDelta('live');assert.deepEqual(h.records.setup,['placeholder','preview']);
 d.resolve();await old;await fresh;assert.deepEqual(h.records.commits,['new answer']);
});
test('tool action updates the placeholder phase',async()=>{
 const d=deferred(),h=harness({runner:d});const run=h.p.runRemoteAgent('task','task','');await drain();
 h.records.listener({kind:'ACTION',text:'x',toolName:'weather'});h.records.listener({kind:'OBSERVATION',text:'y'});
 assert.deepEqual(h.records.phases,['正在生成…','正在调用工具：weather…','正在整理工具结果…']);d.resolve();await run;
});
test('a handled parallel run skips the single-device runner and is persisted once',async()=>{
 const h=harness({parallel:true});await h.p.runRemoteAgent('q','q','');assert.equal(h.records.parallelTries,1);assert.equal(h.records.runs,0);assert.deepEqual(h.records.commits,['merged q']);assert.deepEqual(h.p.conversation.turns,[['user','q'],['assistant','merged q']]);
});
test('a partial parallel answer is shown but stored only as a note',async()=>{
 const h=harness({parallel:'partial'});await h.p.runRemoteAgent('q','q','');assert.deepEqual(h.records.commits,['merged q']);assert.deepEqual(h.p.conversation.turns,[['user','q'],['assistant','（上一轮未得到完整回答）']]);
});
test('agent without splitting keeps tool calls on one runner',async()=>{
 const h=harness({chatMode:'agent'});await h.p.runRemoteAgent('q','q','');
 assert.equal(h.records.parallelTries,undefined);assert.equal(h.records.runs,1);assert.equal(h.records.construct,1);
 h.p.changeChatMode('agent_split');assert.deepEqual(h.records.modes,['agent_split']);
 h.p.changeChatMode('chat');assert.equal(h.p.agentEnabled,false);assert.equal(h.p.chatMode,'chat');
});
test('a declined split falls through to the single-device runner',async()=>{
 const h=harness();await h.p.runRemoteAgent('q','q','');assert.equal(h.records.parallelTries,1);assert.equal(h.records.runs,1);
});
test('stop and dispose also stop the parallel runner',async()=>{
 const d=deferred(),h=harness({runner:d});const run=h.p.runRemoteAgent('q','q','');await drain();h.p.stopGeneration();assert.equal(h.records.parallelStops,1);d.resolve();await run;
 const e=deferred(),g=harness({runner:e});const run2=g.p.runRemoteAgent('q','q','');await drain();g.p.aboutToDisappear();assert.equal(g.records.parallelStops,1);e.resolve();await run2;
});
test('partial final is shown but not persisted as an established answer',async()=>{
 const h=harness({finalStatus:'partial'});await h.p.runRemoteAgent('q','q','');assert.deepEqual(h.records.commits,['q answer']);
 assert.deepEqual(h.p.conversation.turns,[['user','q'],['assistant','（上一轮未得到完整回答）']]);
});
test('successful answer commits and persists once',async()=>{
 const h=harness();await h.p.runRemoteAgent('ok','ok','');assert.deepEqual(h.records.commits,['ok answer']);assert.equal(h.records.saved,1);assert.equal(h.p.conversation.turns.length,2);assert.equal(h.p.sending,false);
});
test('readiness continuation cannot connect after disposal',async()=>{
 const d=deferred(),h=harness();h.channel.isConnected=()=>false;h.channel.prepare=()=>d.promise;let discoveries=0;h.channel.computeDevices=async()=>{discoveries++;};const ready=h.p.ensureRemoteReady(0);h.p.aboutToDisappear();d.resolve();assert.equal(await ready,false);assert.equal(discoveries,0);
});
test('task card appears during preparation and records a completed text task',async()=>{
 const ready=deferred(),plain=deferred(),h=harness({agentEnabled:false,ready,plain});
 const run=h.p.runRemoteAgent('q','q','');
 assert.equal(h.p.messages[0].taskProgress.kind,'文本');assert.equal(h.p.messages[0].taskProgress.phase,'preparing');
 ready.resolve(true);await drain();assert.equal(h.p.messages[0].taskProgress.phase,'running');
 plain.resolve('answer');await run;
 const card=h.p.messages[0].taskProgress;assert.equal(card.phase,'done');assert.ok(card.endedAt>=card.startedAt);assert.equal(h.p.activeTaskProgressId,-1);
});
test('image and partial Agent tasks use the appropriate card kind and terminal status',async()=>{
 const h=harness({finalStatus:'partial'});await h.p.runRemoteAgent('image','image','preview.jpg','base64');
 assert.equal(h.p.messages[0].taskProgress.kind,'图像');assert.equal(h.p.messages[0].taskProgress.phase,'partial');
});
test('completed task keeps its total time when a different task is sent',async()=>{
 const h=harness({agentEnabled:false});await h.p.runRemoteAgent('text','text','');
 const first=JSON.stringify(h.p.messages[0].taskProgress);
 await h.p.runRemoteAgent('image','image','preview.jpg','base64');
 assert.equal(JSON.stringify(h.p.messages[0].taskProgress),first);
 assert.equal(h.p.messages[1].taskProgress.kind,'图像');assert.equal(h.p.messages[1].taskProgress.phase,'done');
 h.p.updateTaskProgress('cancelled');assert.equal(h.p.messages[1].taskProgress.phase,'done');
 assert.equal(h.p.conversation.turns.length,4);assert.ok(h.p.conversation.turns.every(([,text])=>!text.includes('总用时')));
});
test('readiness and inference failures close the task card',async()=>{
 const ready=deferred(),h=harness({ready});const run=h.p.runRemoteAgent('q','q','');ready.resolve(false);await run;
 assert.equal(h.p.messages[0].taskProgress.phase,'failed');
 const plain=deferred(),g=harness({agentEnabled:false,plain});const next=g.p.runRemoteAgent('q','q','');await drain();plain.reject(new Error('offline'));await next;
 assert.equal(g.p.messages[0].taskProgress.phase,'failed');
});
test('cancelled card remains frozen while an old result arrives during the next task',async()=>{
 const plain=deferred(),h=harness({agentEnabled:false,plain});const old=h.p.runRemoteAgent('old','old','');await drain();h.p.stopGeneration();
 const endedAt=h.p.messages[0].taskProgress.endedAt;assert.equal(h.p.messages[0].taskProgress.phase,'cancelled');
 const next=h.p.runRemoteAgent('next','next','');await drain();assert.equal(h.p.messages[1].taskProgress.phase,'running');
 plain.resolve('answer');await old;await next;
 assert.equal(h.p.messages[0].taskProgress.phase,'cancelled');assert.equal(h.p.messages[0].taskProgress.endedAt,endedAt);assert.equal(h.p.messages[1].taskProgress.phase,'done');
});
test('leaving the page freezes the running task card',async()=>{
 const plain=deferred(),h=harness({agentEnabled:false,plain});const run=h.p.runRemoteAgent('q','q','');await drain();h.p.aboutToDisappear();
 assert.equal(h.p.messages[0].taskProgress.phase,'cancelled');plain.resolve('late');await run;assert.equal(h.p.messages[0].taskProgress.phase,'cancelled');
});
test('connection completes service and capability negotiation without sending a task',async()=>{
 const d=deferred(),h=harness(),order=[];let connected=false;
 h.channel.isConnected=()=>connected;
 h.channel.prepare=async()=>{order.push('prepare');};
 h.channel.computeDevices=async()=>{order.push('discover');};
 h.channel.advertisedComputes=()=>[{mac:'hub'}];h.channel.connectComputes=()=>[{mac:'hub'}];
 h.channel.operation=()=>1;h.channel.connectAdvertiser=async()=>{connected=true;order.push('connect');};
 h.channel.waitUntilConnected=async()=>true;h.channel.checkService=async()=>{order.push('service');return '';};
 h.client.ensureReady=()=>{order.push('capabilities');return d.promise;};
 const ready=h.p.ensureRemoteReady(0);await drain();await drain();
 assert.deepEqual(order,['prepare','discover','connect','service','capabilities']);
 assert.equal(h.p.linkBusy,true);assert.equal(h.records.plain.length,0);assert.equal(h.records.runs,0);
 d.resolve('');assert.equal(await ready,true);assert.equal(h.p.linkBusy,false);assert.equal(h.p.remoteStatus,'算力已连接');
});
test('an existing transport link still waits for model capabilities',async()=>{
 const d=deferred(),h=harness({negotiate:d});let settled=false;
 const ready=h.p.ensureRemoteReady(0).then(value=>{settled=true;return value;});await drain();
 assert.equal(settled,false);assert.equal(h.p.linkBusy,true);
 d.resolve('');assert.equal(await ready,true);assert.equal(h.p.linkBusy,false);
});
test('capability failure releases connection controls and records a useful error',async()=>{
 const d=deferred(),h=harness({negotiate:d});const ready=h.p.ensureRemoteReady(0);
 d.resolve('模型服务未就绪');assert.equal(await ready,false);assert.equal(h.p.linkBusy,false);assert.equal(h.p.remoteStatus,'模型服务未就绪');
 assert.equal(h.records.runs,0);assert.equal(h.records.plain.length,0);
});
test('a disposed page cannot become ready from a late capability response',async()=>{
 const d=deferred(),h=harness({negotiate:d});let rendered=0;
 h.p.refreshLinkChrome=()=>rendered++;const ready=h.p.ensureRemoteReady(0);await drain();
 h.p.aboutToDisappear();const count=rendered;d.resolve('');assert.equal(await ready,false);
 assert.equal(rendered,count);assert.notEqual(h.p.remoteStatus,'算力已连接');
});
test('a link lost during negotiation is never reported as ready',async()=>{
 const d=deferred(),h=harness({negotiate:d});let connected=true;h.channel.isConnected=()=>connected;
 const ready=h.p.ensureRemoteReady(0);connected=false;d.resolve('');
 assert.equal(await ready,false);assert.match(h.p.remoteStatus,/连接已中断/);assert.equal(h.p.linkBusy,false);
});
(async()=>{let pass=0;for(const [name,fn] of tests){try{await fn();pass++;console.log('PASS '+name);}catch(e){console.error('FAIL '+name,e);process.exitCode=1;}}console.log(pass+'/'+tests.length+' actual Index lifecycle method tests passed (ArkUI rendering not compiled).');})().catch(e=>{console.error(e);process.exitCode=1;});
