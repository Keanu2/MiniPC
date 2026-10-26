const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'loop-integration-check-'));
function write(name, text) {const dest = path.join(temp, name); fs.mkdirSync(path.dirname(dest), {recursive:true}); fs.writeFileSync(dest, text);}
const files = {
  'agent/AgentEvent': 'agent-core/src/main/ets/agent/AgentEvent',
  'agent/AgentTool': 'agent-core/src/main/ets/agent/AgentTool',
  'agent/ToolContract':'agent-core/src/main/ets/agent/ToolContract',
  'model/LocalModel': 'agent-core/src/main/ets/model/LocalModel',
  'model/RemoteComputeModel': 'entry/src/main/ets/model/RemoteComputeModel',
  'model/InferenceClient': 'entry/src/main/ets/model/InferenceClient'
};
try {
  for (const [name, file] of Object.entries(files)) write(name + '.ts', fs.readFileSync(path.join(root, file + '.ets'), 'utf8'));
  const protocol = fs.readFileSync(path.join(root, 'entry/src/main/ets/protocol/ChatProtocol.ets'), 'utf8');
  const declarations = protocol.slice(0, protocol.indexOf('const PROTOCOL')).replace(/^import .*;\r?\n/gm, '');
  write('protocol/ChatProtocol.ts', declarations + '\nexport declare function validTaskSnapshot(task: TaskSnapshot): boolean;\n');
  write('agent/ConversationContext.ts', 'export interface ConversationContext {}');
  write('model/InferenceWire.ts', 'export declare function utf8Bytes(s:string):Uint8Array; export declare function sha256Hex(b:Uint8Array):string;');
  write('model/Utf8Repair.ts', 'export declare function repairUtf8FromSource(s:string,p:string):string;');
  write('nearby/LinkEnhanceChannel.ts', 'import {WireMessage} from "../protocol/ChatProtocol"; export declare const nearbyChannel:{send(m:WireMessage,epoch?:number):Promise<boolean>; inferenceReady():boolean; readyEpoch():number; setInferenceHandler(h:(m:WireMessage,epoch:number)=>void):void; setInferenceLinkHandler(h:((epoch:number)=>void)|null):void};');
  write('platform.d.ts', 'declare module "@loop/agent-core" {export interface LocalModel {complete(p:string):Promise<string>; cancel?():void} export interface SplitPrompt {system:string; user:string} export function splitReActPrompt(p:string):SplitPrompt|null} declare module "@kit.PerformanceAnalysisKit" {export const hilog:{info(domain:number,tag:string,fmt:string,...args:(string|number)[]):void; warn(domain:number,tag:string,fmt:string,...args:(string|number)[]):void}}');
  const options = {strict:true,useUnknownInCatchVariables:false,noEmit:true,skipLibCheck:true,target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,moduleResolution:ts.ModuleResolutionKind.NodeJs};
  const program = ts.createProgram([...Object.keys(files).map(f => path.join(temp,f + '.ts')),path.join(temp,'platform.d.ts')],options);
  const errors = ts.getPreEmitDiagnostics(program);
  if(errors.length) {console.log(ts.formatDiagnosticsWithColorAndContext(errors,{getCanonicalFileName:x=>x,getCurrentDirectory:()=>temp,getNewLine:()=> '\n'}));process.exitCode=1;}
  else console.log('PASS strict noEmit integration: ' + Object.keys(files).length + ' actual ETS files and actual wire declarations; platform stubs; TypeScript ' + ts.version);
} finally {fs.rmSync(temp,{recursive:true,force:true});}
