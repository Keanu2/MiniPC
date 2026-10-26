const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
let ts;
for (const candidate of [process.env.TYPESCRIPT_PATH, 'typescript', 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'].filter(Boolean)) {
  try { ts = require(candidate); break; } catch {}
}
if (!ts) throw new Error('Set TYPESCRIPT_PATH to an installed TypeScript compiler module.');
const root = path.resolve(__dirname, '../src/main/ets');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'loop-core-typecheck-'));
const actual = ['agent/ReActCore', 'agent/ReActAgentRunner', 'agent/FinalAnswerReviewer', 'agent/ReActResponseCompatibility', 'agent/AgentEvent', 'agent/AgentTool', 'agent/ConversationContext', 'model/LocalModel', 'agent/ToolContract', 'agent/TaskContract', 'agent/TaskCoordinator', 'agent/TaskPlanner', 'agent/ReActTaskWorker', 'agent/ModelTaskAggregator', ...fs.readdirSync(path.join(root,'agent/parallel')).filter(n=>n.endsWith('.ets')).map(n=>'agent/parallel/'+n.slice(0,-4)), ...fs.readdirSync(path.join(root,'agent/contracts')).filter(n=>n.endsWith('.ets')).map(n=>'agent/contracts/'+n.slice(0,-4))];
function write(name, text) { const file = path.join(temp, name); fs.mkdirSync(path.dirname(file), {recursive:true}); fs.writeFileSync(file, text); }
try {
  for (const name of actual) write(name + '.ts', fs.readFileSync(path.join(root, name + '.ets'), 'utf8'));
  write('agent/ToolRegistry.ts', 'import {ToolMetadata,ToolResult} from "./AgentTool"; import {ToolContractCatalog} from "./ToolContract"; export declare class ToolRegistry {contracts():ToolContractCatalog;cancelActive(prefix?:string):void;close():Promise<void>;has(name:string):boolean; metadata(name:string):ToolMetadata; describeToolsBrief():string; describeTools(compact?:boolean):string; run(name:string,input:string,callId?:string):Promise<ToolResult>;}');
  write('skill/AgentSkill.ts', 'export declare class AgentSkill {name:string; instructions():string;}');
  write('skill/SkillSnapshot.ts', 'import {AgentSkill} from "./AgentSkill"; export declare class SkillSnapshot {findByName(name:string):AgentSkill|null; findByNaturalLanguageTask(task:string):AgentSkill|null;} export declare function buildSkillsSection(snapshot:SkillSnapshot|null):string;');
  write('platform.d.ts', 'declare module "@ohos.util" { namespace util {class TextEncoder {encodeInto(text:string):Uint8Array;}} export default util;}');
  const program = ts.createProgram(actual.map(name => path.join(temp,name + '.ts')).concat(path.join(temp,'platform.d.ts')), {strict:true,useUnknownInCatchVariables:false,noEmit:true,skipLibCheck:true,target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,moduleResolution:ts.ModuleResolutionKind.NodeJs});
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) console.log(ts.formatDiagnosticsWithColorAndContext(diagnostics, {getCanonicalFileName:x=>x,getCurrentDirectory:()=>temp,getNewLine:()=>String.fromCharCode(10)}));
  const errors = diagnostics.filter(d=>d.category === ts.DiagnosticCategory.Error);
  if (errors.length) process.exitCode = 1;
  else console.log('PASS strict noEmit core: ' + actual.length + ' actual ETS files; registry/skill/platform declaration stubs; TypeScript ' + ts.version + '; zero errors. Not a full ArkTS build.');
} finally { fs.rmSync(temp,{recursive:true,force:true}); }
