const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
let ts;
for (const candidate of [process.env.TYPESCRIPT_PATH, 'typescript', 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { ts = require(candidate); break; } catch {}
}
if (!ts) throw new Error('Set TYPESCRIPT_PATH to an installed TypeScript compiler module.');
const root = path.resolve(__dirname, '../src/main/ets');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'loop-concurrent-typecheck-'));
const actual = ['agent/ReActCore', 'agent/ReActAgentRunner', 'agent/FinalAnswerReviewer', 'agent/ReActResponseCompatibility', 'agent/AgentEvent', 'agent/AgentTool', 'agent/ConversationContext', 'model/LocalModel', 'agent/ToolContract', 'agent/TaskContract', 'agent/TaskCoordinator', 'agent/TaskPlanner', 'agent/ReActTaskWorker', 'agent/ModelTaskAggregator', ...fs.readdirSync(path.join(root,'agent/parallel')).filter(n=>n.endsWith('.ets')).map(n=>'agent/parallel/'+n.slice(0,-4)), ...fs.readdirSync(path.join(root,'agent/contracts')).filter(n=>n.endsWith('.ets')).map(n=>'agent/contracts/'+n.slice(0,-4))];
function write(name, text) { const file = path.join(temp, name); fs.mkdirSync(path.dirname(file), {recursive:true}); fs.writeFileSync(file, text); }
try {
  for (const name of actual) write(name + '.ts', fs.readFileSync(path.join(root, name + '.ets'), 'utf8'));
  write('agent/ToolRegistry.ts', 'import {ToolMetadata,ToolResult} from "./AgentTool"; import {ToolContractCatalog} from "./ToolContract"; export declare class ToolRegistry {contracts():ToolContractCatalog;cancelActive(prefix?:string):void;close():Promise<void>;has(name:string):boolean; metadata(name:string):ToolMetadata; describeToolsBrief():string; describeTools(compact?:boolean):string; run(name:string,input:string,callId?:string):Promise<ToolResult>;}');
  write('skill/AgentSkill.ts', 'export declare class AgentSkill {name:string; instructions():string;}');
  write('skill/SkillSnapshot.ts', 'import {AgentSkill} from "./AgentSkill"; export declare class SkillSnapshot {findByName(name:string):AgentSkill|null; findByNaturalLanguageTask(task:string):AgentSkill|null;} export declare function buildSkillsSection(snapshot:SkillSnapshot|null):string;');
  write('platform.d.ts', 'declare module "@ohos.util" { namespace util {class TextEncoder {encodeInto(text:string):Uint8Array;}} export default util;}');
  const entry = path.resolve(root, '../../../../entry/src/main/ets');
  const entryFiles = ['ConcurrentChatTask','TaskConversationLedger','RemoteComputeModel','InferenceClient','TaskReporter','TaskProgress','PlainChat','ChatModeStore'];
  for (const name of entryFiles) write('model/' + name + '.ts', fs.readFileSync(path.join(entry,'model',name+'.ets'),'utf8'));
  const protocol = fs.readFileSync(path.join(entry,'protocol/ChatProtocol.ets'),'utf8');
  write('protocol/ChatProtocol.ts', protocol.slice(0,protocol.indexOf('const PROTOCOL')).replace(/^import .*;\r?\n/gm,'')+'\nexport declare function validTaskSnapshot(task:TaskSnapshot):boolean;');
  write('model/InferenceWire.ts','export declare function utf8Bytes(s:string):Uint8Array; export declare function sha256Hex(b:Uint8Array):string;');
  write('model/Utf8Repair.ts','export declare function repairUtf8FromSource(s:string,p:string):string;');
  write('nearby/LinkEnhanceChannel.ts','import {WireMessage} from "../protocol/ChatProtocol"; export declare const nearbyChannel:{send(m:WireMessage,epoch?:number):Promise<boolean>; inferenceReady():boolean; readyEpoch():number; setInferenceHandler(h:(m:WireMessage,epoch:number)=>void):void; setInferenceLinkHandler(h:((epoch:number)=>void)|null):void};');
  const registry = fs.readFileSync(path.join(temp,'agent/ToolRegistry.ts'),'utf8');
  write('agent/ToolRegistry.ts',registry+'\nimport {SkillSnapshot} from "../skill/SkillSnapshot"; import {common} from "@kit.AbilityKit"; export declare function createConfiguredLoopToolRegistry(c:common.UIAbilityContext,s:SkillSnapshot):Promise<ToolRegistry>;');
  write('skill/SkillSnapshot.ts',fs.readFileSync(path.join(temp,'skill/SkillSnapshot.ts'),'utf8')+'\nimport {common} from "@kit.AbilityKit"; export declare function createSkillSnapshot(c:common.UIAbilityContext):Promise<SkillSnapshot>;');
  write('node_modules/@loop/agent-core/index.ts',[
   'export * from "../../../agent/ConversationContext";', 'export * from "../../../agent/AgentEvent";',
   'export * from "../../../agent/ReActAgentRunner";', 'export * from "../../../agent/ReActCore";',
   'export * from "../../../agent/parallel/ParallelTaskRunner";', 'export * from "../../../model/LocalModel";',
   'export * from "../../../agent/ToolRegistry";', 'export * from "../../../skill/SkillSnapshot";'].join('\n'));
  fs.appendFileSync(path.join(temp,'platform.d.ts'),
   'declare module "@kit.AbilityKit" {export namespace common {class Context {} class UIAbilityContext extends Context {filesDir:string;}}} '+
   'declare module "@kit.PerformanceAnalysisKit" {export const hilog:{info(d:number,t:string,f:string,...a:(string|number)[]):void;warn(d:number,t:string,f:string,...a:(string|number)[]):void}} '+
   'declare module "@kit.ArkData" {import {common} from "@kit.AbilityKit";export namespace preferences {interface Store {getSync(k:string,d:string|boolean):string|boolean;putSync(k:string,v:string|boolean):void;flush():Promise<void>;}function getPreferencesSync(c:common.Context,o:{name:string}):Store;}}');
  actual.push(...entryFiles.map(name=>'model/'+name));
  const page = fs.readFileSync(path.join(entry,'pages/Index.ets'),'utf8').replace(/\r\n/g,'\n');
  const pageLines = page.split('\n');
  const methods = ['initializeTabletSessions','captureEngineSession','saveSelectedDraft','selectSession','newSession','isEmptyTabletSession','restoreTabletSessions',
   'selectedSessionTitle','sessionStatus','visibleMessages','canClearSession','clearSelectedSession','drainTaskQueue','runAgent','canSend','clearAttachment','composeAttachmentTask',
   'ledgerFor','setSessionMessages','refreshTaskActivity','startConcurrentTask','updateConcurrentTask','finishConcurrentTask','cancelSessionTasks','cancelAllConcurrentTasks',
   'clearWaitingTasks','deleteSession','clearResults','resultTranscript','buildRemoteConversation','ensureTaskConnection'];
  const methodText = name => {const start=pageLines.findIndex(line=>['  private '+name+'(','  private async '+name+'('].some(p=>line.startsWith(p)));if(start<0)throw Error(name);let end=start+1;while(pageLines[end]!=='  }')end++;return pageLines.slice(start,end+1).join('\n');};
  const fields = ['conversation','sessions','message','messages','selectedSessionId','engineSessionId','taskQueue','sending','activeTaskSessions','activeChatTasks','taskLedgers',
   'queueDraining','taskClosing','taskConnection','nextSessionId','nextQueuedTaskId','pageActive','remoteRunGeneration','preparingSubmission','pendingPath','pendingName','pendingKind','pendingLocal','attachError','chatMode'];
  const fieldText = fields.map(name=>{const line=pageLines.find(line=>['  @State '+name+':','  private '+name+':'].some(p=>line.startsWith(p)));if(!line)throw Error(name);return line.replace('@State ','');}).join('\n');
  const bubbleTypes = page.slice(page.indexOf('enum BubbleKind'),page.indexOf('function bubbleBackground'));
  const sessionTypes = page.slice(page.indexOf('interface StoredTabletSession'),page.indexOf('@Entry'));
  const imports = 'import {common} from "@kit.AbilityKit"; import {ChatMessage,ConversationContext,ConversationRole} from "@loop/agent-core"; import {TaskProgress,taskProgressActive} from "./TaskProgress"; import {ChatMode} from "./ChatModeStore"; import {ConcurrentChatTask,ChatTaskInput,ChatTaskUpdate} from "./ConcurrentChatTask"; import {TaskConversationLedger} from "./TaskConversationLedger"; import {inferenceClient} from "./InferenceClient";';
  const services = 'declare const LIVE_PLACEHOLDER:string,PARTIAL_HISTORY_NOTE:string,REMOTE_HISTORY_TURNS:number,REMOTE_HISTORY_MAX_CHARS:number; declare const Edge:{Bottom:number}; declare const fs:{readTextSync(p:string):string}; declare function readTextExcerpt(p:string):string; declare function encodeLocalImageBase64(p:string):Promise<string>; declare class PageServices {scroller:{scrollEdge(e:number):void}; getAbilityContext():common.UIAbilityContext; ensureRemoteReady(g:number):Promise<boolean>; createChatBubble(s:string,t:string,k:BubbleKind,image?:string):ChatBubble; setCollaborationKeepScreenOn(b:boolean):void; persistTabletSessions():void; buildMessagesFromConversation(c:ConversationContext):ChatBubble[];}';
  write('model/TabletTaskDispatcher.ts',imports+bubbleTypes+sessionTypes+services+'class Dispatcher extends PageServices {'+fieldText+methods.map(methodText).join('\n')+'}');
  actual.push('model/TabletTaskDispatcher');
  const program = ts.createProgram(actual.map(name => path.join(temp,name + '.ts')).concat(path.join(temp,'platform.d.ts')), {strict:true,useUnknownInCatchVariables:false,noEmit:true,skipLibCheck:true,target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,moduleResolution:ts.ModuleResolutionKind.NodeJs});
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) console.log(ts.formatDiagnosticsWithColorAndContext(diagnostics, {getCanonicalFileName:x=>x,getCurrentDirectory:()=>temp,getNewLine:()=>String.fromCharCode(10)}));
  const errors = diagnostics.filter(d=>d.category === ts.DiagnosticCategory.Error);
  if (errors.length) process.exitCode = 1;
  else console.log('PASS strict noEmit concurrent task engine and core: ' + actual.length + ' actual ETS files; registry/skill/platform declaration stubs; TypeScript ' + ts.version + '; zero errors. Not a full ArkTS build.');
} finally { fs.rmSync(temp,{recursive:true,force:true}); }
