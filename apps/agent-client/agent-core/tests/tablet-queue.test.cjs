// Actual page dispatcher and session methods, controlled workers; no UI, device or external writes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH||'typescript'),{transpile}=require('../../../../tests/ets-harness.cjs');
const coreBox={exports:{}};vm.runInNewContext(transpile(path.resolve(__dirname,'../src/main/ets/agent/ConversationContext.ets')),coreBox);
const {ConversationContext}=coreBox.exports;
const ledgerBox={exports:{},require:()=>({ConversationContext})};vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/model/TaskConversationLedger.ets')),ledgerBox);
const source=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/pages/Index.ets'),'utf8').replace(/\r\n/g,'\n'),lines=source.split('\n');
const names=['initializeTabletSessions','captureEngineSession','saveSelectedDraft','selectSession','newSession','isEmptyTabletSession','restoreTabletSessions',
 'selectedSessionTitle','sessionStatus','visibleMessages','canClearSession','clearSelectedSession','drainTaskQueue','runAgent','canSend','clearAttachment','composeAttachmentTask',
 'ledgerFor','setSessionMessages','refreshTaskActivity','startConcurrentTask','updateConcurrentTask','finishConcurrentTask','cancelSessionTasks','cancelAllConcurrentTasks',
 'clearWaitingTasks','deleteSession','clearResults','resultTranscript','buildRemoteConversation','ensureTaskConnection'];
function method(name){const start=lines.findIndex(l=>['  private '+name+'(','  private async '+name+'('].some(p=>l.startsWith(p)));assert.ok(start>=0,name);let end=start+1;while(lines[end]!=='  }')end++;return lines.slice(start,end+1).join('\n');}
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
const workers=[];class Worker{
 constructor(input,ready,observe){this.input=input;this.observe=observe;this.gate=deferred();this.cancelled=false;workers.push(this);}
 run(){this.observe({phase:'running',status:'生成',answer:'',process:'',device:'',startedAt:100,endedAt:0});return this.gate.promise;}
 finish(answer,phase='done'){this.observe({phase,status:'完成',answer,process:'',device:'算力设备2',startedAt:100,endedAt:200});this.gate.resolve();}
 cancel(){this.cancelled=true;this.finish('已停止生成','cancelled');}
 late(answer){this.observe({phase:'done',status:'完成',answer,process:'',device:'',startedAt:100,endedAt:200});}
}
let savedSessions='[]',total=3;
const BubbleKind={USER:0,LOOP:1,PROCESS:2,TASK:3,ERROR:4};
const box={exports:{},fs:{readTextSync:()=>savedSessions},ConversationRole:coreBox.exports.ConversationRole,ConversationContext,TaskConversationLedger:ledgerBox.exports.TaskConversationLedger,
 ConcurrentChatTask:Worker,BubbleKind,PARTIAL_HISTORY_NOTE:'（上一轮未得到完整回答）',LIVE_PLACEHOLDER:'正在生成…',REMOTE_HISTORY_TURNS:6,REMOTE_HISTORY_MAX_CHARS:4000,
 inferenceClient:{clusterLoad:()=>({total,idle:total})},taskProgressActive:p=>p==='running'||p==='preparing',Edge:{Bottom:1},Date,
 encodeLocalImageBase64:async()=>{throw new Error('bad image');}};
vm.runInNewContext(ts.transpileModule('class Page {'+names.map(method).join('\n')+'} exports.Page=Page;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,box);
function page(){const p=new box.exports.Page();Object.assign(p,{sessions:[],messages:[],conversation:new ConversationContext(),message:'',taskQueue:[],nextSessionId:1,
 nextQueuedTaskId:1,nextChatBubbleId:1,pageActive:true,sending:false,queueDraining:false,taskClosing:false,activeTaskSessions:[],activeChatTasks:new Map(),taskLedgers:new Map(),
 preparingSubmission:false,pendingPath:'',pendingKind:'',pendingName:'',pendingLocal:'',chatMode:'chat',remoteRunGeneration:0,
 getAbilityContext:()=>({filesDir:'/test'}),buildMessagesFromConversation:c=>c.toChatMessages().map(t=>({text:t.content,kind:t.role==='user'?0:1})),
 createChatBubble(speaker,text,kind,imagePath=''){return {id:this.nextChatBubbleId++,speaker,text,kind,imagePath,collapsible:false,expanded:false,revision:0};},
 scroller:{scrollEdge(){}},setCollaborationKeepScreenOn(){},ensureRemoteReady:async()=>true,persistTabletSessions(){this.captureEngineSession();this.saveSelectedDraft();}});p.initializeTabletSessions();return p;}
async function tick(){for(let i=0;i<30;i++)await Promise.resolve();}
async function submit(p,text){p.message=text;await p.runAgent();}
(async()=>{
 const p=page();assert.equal(p.sessions.length,1);p.newSession();p.newSession();assert.equal(p.sessions.length,1);
 const start=workers.length;await submit(p,'一');await submit(p,'二');await submit(p,'三');assert.equal(workers.length-start,3,'three submissions start before any completes');
 assert.equal(p.activeTaskSessions.length,3);assert.equal(p.taskQueue.length,0);assert.equal(p.sending,true);
 await submit(p,'四');assert.equal(p.taskQueue.length,1,'excess work waits without locking the composer');
 workers[start+1].finish('答案二');await tick();assert.equal(workers.length-start,4,'a released device slot immediately starts the next task');
 workers[start].finish('答案一');workers[start+2].finish('答案三');workers[start+3].finish('答案四');await tick();
 assert.equal(p.sending,false);assert.deepEqual(Array.from(p.conversation.toChatMessages(),t=>t.content),['一','答案一','二','答案二','三','答案三','四','答案四']);
 assert.equal(p.visibleMessages().find(b=>b.text==='答案二').kind,BubbleKind.LOOP);
 const c=page(),w=workers.length;await submit(c,'隐藏旧输出');c.clearResults();assert.equal(c.visibleMessages().length,0);
 workers[w].finish('不能重新出现');await tick();assert.equal(c.visibleMessages().length,0);assert.equal(JSON.parse(c.resultTranscript(c.sessions[0])).length,0);
 assert.deepEqual(Array.from(c.conversation.toChatMessages(),t=>t.content),['隐藏旧输出','不能重新出现'],'clearing the result view preserves conversation context');
 await submit(c,'新输出');workers[w+1].finish('新答案');await tick();assert.ok(c.visibleMessages().some(b=>b.text==='新答案'));assert.ok(!c.visibleMessages().some(b=>b.text==='不能重新出现'));
 const d=page(),offset=workers.length;await submit(d,'A1');await submit(d,'A2');const a=d.selectedSessionId;d.newSession();const b=d.selectedSessionId;await submit(d,'B1');
 d.selectSession(a);await submit(d,'A3');assert.equal(d.taskQueue.length,1);d.deleteSession(a);await tick();
 assert.equal(workers[offset].cancelled,true);assert.equal(workers[offset+1].cancelled,true);assert.equal(workers[offset+2].cancelled,false,'deleting A must not stop B');
 assert.equal(d.taskQueue.length,0);assert.equal(d.selectedSessionId,b);workers[offset].late('过期 A');assert.ok(!d.visibleMessages().some(x=>x.text==='过期 A'));
 workers[offset+2].finish('B答案');await tick();d.deleteSession(b);assert.equal(d.sessions.length,1);assert.equal(d.sessions[0].title,'新对话');
 const e=page();e.message='保留草稿';e.newSession();assert.equal(e.sessions.length,2);e.newSession();assert.equal(e.sessions.length,2);
 savedSessions=JSON.stringify([{title:'新会话',transcript:'[]',draft:''},{title:'新对话',transcript:'[]',draft:''},
 {title:'历史',transcript:JSON.stringify([{role:'user',content:'历史内容'}]),resultTranscript:'[]',draft:''},{title:'新会话',transcript:'[]',draft:'草稿'}]);
 const restored=page();restored.restoreTabletSessions();assert.equal(restored.sessions.length,3);assert.equal(restored.sessions[1].messages.length,0);assert.equal(restored.sessions[1].conversation.toChatMessages()[0].content,'历史内容');
 const f=page();f.pendingKind='image';f.pendingPath='photo';f.pendingLocal='image.jpg';f.message='保留';await f.runAgent();assert.equal(f.message,'保留');assert.equal(f.pendingPath,'photo');assert.equal(f.taskQueue.length,0);
 const pending=page(),pendingStart=workers.length;await submit(pending,'stop');pending.cancelAllConcurrentTasks();await tick();assert.equal(workers[pendingStart].cancelled,true);assert.equal(pending.sending,false);
 console.log('PASS actual page: concurrent capacity, FIFO admission, out-of-order history, result clearing fences, per-session deletion/cancellation, drafts and restore');
})().catch(e=>{console.error(e);process.exitCode=1;});
