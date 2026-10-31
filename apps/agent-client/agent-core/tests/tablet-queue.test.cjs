// Exercise the actual page queue/session methods without ArkUI or device I/O.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8').replace(/\r\n?/g, '\n');
const names = ['initializeTabletSessions','captureEngineSession','saveSelectedDraft','selectSession','newSession','isEmptyTabletSession','restoreTabletSessions',
 'selectedSessionTitle','sessionStatus','visibleMessages','canClearSession','clearSelectedSession','drainTaskQueue','runAgent','canSend','clearAttachment','composeAttachmentTask'];
const lines = source.split('\n');
function method(name) {
 const start = lines.findIndex(line => ['  private '+name+'(', '  private async '+name+'('].some(p => line.startsWith(p)));
 assert.ok(start >= 0, name); let end = start+1; while(lines[end] !== '  }') end++;
 return lines.slice(start,end+1).join('\n');
}
let savedSessions='[]';
const box = {exports:{}, fs:{readTextSync:()=>savedSessions}, BubbleKind:{USER:0}, ConversationContext:class {static fromMessages(turns){return {toChatMessages:()=>turns};}}, encodeLocalImageBase64:async()=>{throw new Error('bad image');}};
vm.runInNewContext(ts.transpileModule('class Page {'+names.map(method).join('\n')+'} exports.Page=Page;',
 {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,box);
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {resolve,promise};}
async function drain(){for(let i=0;i<20;i++)await Promise.resolve();}
function page(){const p=new box.exports.Page();Object.assign(p,{sessions:[],messages:[],conversation:{},message:'',taskQueue:[],nextSessionId:1,
 nextQueuedTaskId:1,pageActive:true,sending:false,queueDraining:false,preparingSubmission:false,pendingPath:'',pendingKind:'',pendingName:'',pendingLocal:'',chatMode:'chat',getAbilityContext:()=>({filesDir:'/test'}),buildMessagesFromConversation:c=>c.toChatMessages().map(t=>({text:t.content})),persistTabletSessions(){}});
 p.initializeTabletSessions();return p;}
(async()=>{
 const initial=page();assert.equal(initial.sessions.length,1);const blank=initial.selectedSessionId;
 initial.newSession();initial.newSession();assert.equal(initial.sessions.length,1);assert.equal(initial.selectedSessionId,blank);
 initial.message='草稿';initial.newSession();assert.equal(initial.sessions.length,2,'draft must keep its own session');
 initial.newSession();assert.equal(initial.sessions.length,2,'repeated new reuses the remaining empty session');
 savedSessions=JSON.stringify([{title:'新会话',transcript:'[]',draft:''},{title:'新对话',transcript:'[]',draft:''},
 {title:'历史会话',transcript:JSON.stringify([{role:'user',content:'保留历史'}]),draft:''},
 {title:'新会话',transcript:'[]',draft:'保留草稿'}]);
 const restored=page();restored.restoreTabletSessions();assert.equal(restored.sessions.length,3);
 assert.equal(restored.sessions.filter(s=>restored.isEmptyTabletSession(s)).length,1);assert.equal(restored.sessions[1].messages[0].text,'保留历史');
 assert.equal(restored.sessions[2].draft,'保留草稿');
 const p=page(), gates=[deferred(),deferred(),deferred()], calls=[];
 p.runRemoteAgent=async(task)=>{p.sending=true;const i=calls.length;calls.push({task,session:p.engineSessionId});await gates[i].promise;
 p.messages=[...p.messages,{text:'answer '+task}];p.sending=false;};
 p.message='first';await p.runAgent();assert.equal(calls.length,1);assert.equal(p.preparingSubmission,false);
 p.message='second';await p.runAgent();assert.equal(p.taskQueue.length,1);assert.equal(calls.length,1);
 const first=p.selectedSessionId;p.newSession();const second=p.selectedSessionId;
 p.message='third';await p.runAgent();assert.equal(p.taskQueue.length,2);assert.match(p.visibleMessages()[0].text,/third/);
 p.message='draft in second';p.selectSession(first);assert.equal(p.message,'');p.selectSession(second);assert.equal(p.message,'draft in second');
 assert.equal(p.canClearSession(),false);gates[0].resolve();await drain();assert.equal(calls[1].task,'second');
 assert.equal(calls[1].session,first);assert.match(p.visibleMessages()[0].text,/third/);
 gates[1].resolve();await drain();assert.equal(calls[2].session,second);assert.equal(p.message,'draft in second');
 gates[2].resolve();await drain();assert.equal(p.queueDraining,false);assert.equal(p.taskQueue.length,0);
 p.selectSession(first);assert.equal(p.visibleMessages().length,2);assert.equal(p.visibleMessages()[0].text,'answer first');
 p.selectSession(second);assert.equal(p.visibleMessages()[0].text,'answer third');assert.equal(p.canClearSession(),true);
 p.clearSelectedSession();assert.equal(p.visibleMessages().length,0);p.selectSession(first);assert.equal(p.visibleMessages().length,2);
 const q=page(),g=deferred();let n=0;q.runRemoteAgent=async()=>{q.sending=true;n++;await g.promise;q.sending=false;};
 q.message='a';await q.runAgent();q.message='b';await q.runAgent();q.taskQueue=[];g.resolve();await drain();assert.equal(n,1);
 const r=page();r.pendingKind='image';r.pendingPath='photo';r.pendingLocal='image.jpg';r.message='keep';await r.runAgent();
 assert.equal(r.message,'keep');assert.equal(r.pendingPath,'photo');assert.equal(r.taskQueue.length,0);assert.equal(r.preparingSubmission,false);
 console.log('Tablet queue: continuous submission, FIFO, session isolation, drafts, clear waiting, and encoding failure passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
