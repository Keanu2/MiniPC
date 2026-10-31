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
const names = ['aboutToAppear','aboutToDisappear','ensureRemoteReady','isCurrentRemoteRun','changeChatMode','changeAgentMode','beginTaskProgress','updateTaskProgress'];
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
  Object.assign(p,{messages:[],nextChatBubbleId:1,activeTaskProgressId:-1,scroller:{scrollEdge(){}},createChatBubble(speaker,text,kind){return {id:this.nextChatBubbleId++,speaker,text,kind,imagePath:'',collapsible:false,expanded:false,revision:0};},pageActive:true,remoteRunGeneration:0,stopRequested:false,sending:false,message:'',skillSnapshot:options.skill?null:{},toolRegistryIncludesSkills:true,toolRegistryPromise:options.tools?.promise??Promise.resolve({close:async()=>{}}),activeRunner:null,liveReplyId:-1,liveReplyPending:false,processId:-1,collabController:null,conversation:{turns:[],addUser(x){this.turns.push(['user',x]);},addAssistant(x){this.turns.push(['assistant',x]);}},getAbilityContext:()=>({}),setCollaborationKeepScreenOn(){},refreshLinkChrome(){},appendLine(...x){records.lines.push(x);},appendUserMessage(){},appendProcess(e){records.events.push(e);},finishInferenceMetricsTask(){},formatElapsed:()=>'1.0 秒',commitLiveAnswer(x){records.commits.push(x);},dropLivePlaceholder(){this.liveReplyId=-1;},beginLiveReply(){records.setup.push('placeholder');},showLiveReply(){records.setup.push('preview');},addEvent(e){records.events.push(e);},disposeSingleDeviceSession(){},restoreConversation(){},initializeTabletSessions(){},initializeTabletPreferences(){},startRoutingView(){},stopRoutingView(){},cancelAllConcurrentTasks(){},restoreTabletSessions(){},persistTabletSessions(){},buildRemoteConversation(){return this.conversation;},setLivePhase(x){records.phases.push(x);},parallelObserver(){return {};},createParallelRunner(){return {requestStop(){records.parallelStops=(records.parallelStops||0)+1;},async tryRun(task,conversation,observer,listener){records.parallelTries=(records.parallelTries||0)+1;if(!options.parallel)return false;listener({kind:'FINAL',text:'merged '+task,status:options.parallel==='partial'?'partial':undefined});return true;}};}});
  if(options.ready) p.ensureRemoteReady=()=>options.ready.promise;
  p.agentEnabled=options.agentEnabled??true;
  p.chatMode=options.chatMode??(p.agentEnabled?'agent_split':'chat');
  p.conversation.toChatMessages=()=>p.conversation.turns.map(([role,content])=>({role,content}));
  return {p,client,channel,records};
}
// Task execution now has its own per-submission lifecycle in ConcurrentChatTask.
const tests=[]; const test=(name,fn)=>tests.push([name,fn]);
test('startup restores mode without eagerly initializing tools',async()=>{
 for(const storedAgent of [false,true]){const h=harness({storedAgent});h.p.aboutToAppear();await drain();assert.equal(h.p.agentEnabled,storedAgent);assert.equal(h.records.registries,0);}
});
test('readiness continuation cannot connect after disposal',async()=>{
 const d=deferred(),h=harness();h.channel.isConnected=()=>false;h.channel.prepare=()=>d.promise;let discoveries=0;h.channel.computeDevices=async()=>{discoveries++;};const ready=h.p.ensureRemoteReady(0);h.p.aboutToDisappear();d.resolve();assert.equal(await ready,false);assert.equal(discoveries,0);
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
(async()=>{let pass=0;for(const [name,fn] of tests){try{await fn();pass++;console.log('PASS '+name);}catch(e){console.error('FAIL '+name,e);process.exitCode=1;}}console.log(pass+'/'+tests.length+' actual Index connection lifecycle tests passed.');})().catch(e=>{console.error(e);process.exitCode=1;});
