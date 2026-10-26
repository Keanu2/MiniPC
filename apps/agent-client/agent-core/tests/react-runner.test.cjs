/* Run: node apps/agent-client/agent-core/tests/react-runner.test.cjs
 * Optional TYPESCRIPT_PATH points to a local typescript.js. No network required.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const candidates = [process.env.TYPESCRIPT_PATH, 'typescript',
  'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript',
  'D:/command-line-tools/hvigor/hvigor/node_modules/typescript'].filter(Boolean);
let ts;
for (const candidate of candidates) { try { ts = require(candidate); break; } catch {} }
if (!ts) throw new Error('Install TypeScript locally or set TYPESCRIPT_PATH to its compiler module.');
const root = path.resolve(__dirname, '../src/main/ets');
const modules = new Map();
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true };
class AgentEvent { constructor(kind, text, callId, toolName, input, status) { Object.assign(this, {kind, text, callId, toolName, input, status}); } }
const AgentEventKind = { ACTION: 'action', OBSERVATION: 'observation', FINAL: 'final', ERROR: 'error', SKILL: 'skill' };
const stubs = {
  '@ohos.util': { default: { TextEncoder: class { encodeInto(text) { return Buffer.from(text, 'utf8'); } } } },
  './AgentEvent': { AgentEvent, AgentEventKind },
  '../skill/SkillSnapshot': { buildSkillsSection: () => 'SKILL_CONTRACT' }
};
function load(file) {
  file = path.resolve(root, file);
  if (modules.has(file)) return modules.get(file).exports;
  const source = fs.readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, { fileName: file.replace(/\.ets$/, '.ts'), compilerOptions, reportDiagnostics: true });
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), [], 'ETS syntax errors: ' + file);
  const module = { exports: {} };
  modules.set(file, module);
  const localRequire = name => {
    if (stubs[name]) return stubs[name];
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'));
    return createRequire(file)(name);
  };
  const wrapper = vm.runInThisContext('(function(require,module,exports){' + compiled.outputText + '\n})', { filename: file });
  wrapper(localRequire, module, module.exports);
  return module.exports;
}
const genericCore = load('agent/ReActCore.ets');
const {ToolContractCatalog,validateSchema}=load('agent/ToolContract.ets');
const {weatherContract}=load('agent/contracts/WeatherContract.ets');
const {trainContract}=load('agent/contracts/TrainContract.ets');
const {mapContract}=load('agent/contracts/MapContract.ets');
const {fileContract}=load('agent/contracts/FileContracts.ets');
const {utilityContract}=load('agent/contracts/UtilityContracts.ets');
function builtins(){const catalog=new ToolContractCatalog();
  catalog.register('weather_search',weatherContract('weather'));catalog.register('air_quality',weatherContract('air'));
  catalog.register('train_search',trainContract());catalog.register('map_search',mapContract());
  catalog.register('read',fileContract('read','skill'));catalog.register('read_sandbox_file',fileContract('read_sandbox_file','read'));catalog.register('list_sandbox_files',fileContract('list_sandbox_files','list'));
  catalog.register('calculator',utilityContract('calculator','arithmetic'));catalog.register('unit_convert',utilityContract('unit_convert','conversion'));catalog.register('date_calculator',utilityContract('date_calculator','date'));
  return catalog;}
const core={...genericCore,
  buildTaskLedger:(task,anchor)=>genericCore.buildTaskLedger(task,anchor,builtins()),
  bindResult:(entries,call,status,output,id)=>genericCore.bindResult(entries,call,status,output,id,builtins()),
  bindToolResult:(entries,call,result)=>genericCore.bindToolResult(entries,call,result,builtins()),
  finalIssues:(entries,answer)=>genericCore.finalIssues(entries,answer,builtins()),
  preserveTrainTimeWindow:(call,entries)=>builtins().prepare(call,entries)};
const { ReActAgentRunner } = load('agent/ReActAgentRunner.ets');
const tests = [];
const test = (name, body) => tests.push({ name, body });
const known = name => ['weather_search', 'air_quality', 'read', 'calculator', 'map_search', 'train_search', 'list_sandbox_files', 'read_sandbox_file', 'calendar.events.search'].includes(name);
const plan = text => core.parseCorePlan(text, known, name=>builtins().inputFormat(name));
async function run(task, responses, outputs = {}, options = {}) {
  const calls = [], prompts = [], events = [], contexts = [];
  const catalog=builtins();
  for(const [name,contract] of Object.entries(options.contracts||{}))catalog.register(name,contract);
  const safe = {readOnly:true, supportsParallel:true, cacheable:true, risk:'low'};
  const metadata = name => ({name, ...(options.policies?.[name] ??
    (['weather_search','air_quality','calculator','unit_convert','map_search','train_search','list_sandbox_files'].includes(name) ? safe :
      {readOnly:false,supportsParallel:false,cacheable:false,risk:'high'}))});
  const { normalizeToolResult } = load('agent/AgentTool.ets');
  const { summarizeA2uiObservation } = load('agent/A2uiObservationDigest.ets');
  const tools = { contracts:()=>catalog, has: name => known(name) || Object.hasOwn(outputs,name), metadata,
    describeTools: () => options.contract || 'IMMUTABLE_CONTRACT: query and context are independent; confirm before sending.',
    run: async (name, input, callId) => {
      calls.push({name,input});
      const output = outputs[name];
      if (output instanceof Error) throw output;
      const value = typeof output === 'function' ? await output(input,callId) : (output ?? 'ok');
      const declaration=catalog.get(name);
      const result = normalizeToolResult(value,callId,metadata(name),declaration?.legacyStatus);
      if(result.status==='success'){result.data=result.data??declaration?.legacyData?.(result.raw)??(declaration?.outputSchema?.type==='string'?result.raw:undefined);if(declaration?.outputSchema&&validateSchema(result.data,declaration.outputSchema).length){result.status='failed';result.displayText='Tool output does not satisfy its contract';}}
      if (typeof value === 'string') {
        const digest = summarizeA2uiObservation(value);
        if (digest.isA2ui) { result.displayText=digest.text; result.finalText=digest.finalText || undefined; }
        if (digest.shouldStop) { result.status='unavailable'; result.stop=true; }
      }
      return options.resultOverride ? options.resultOverride(result) : result;
    } };
  let i = 0;
  const model = { complete: async (prompt,context) => { prompts.push(prompt); contexts.push(context); const response=responses[Math.min(i++,responses.length-1)]; if(response instanceof Error) throw response; return response; }, cancel: () => options.onCancel?.() };
  // Legacy response fixtures exercise the explicit compatibility mode.
  const runner = new ReActAgentRunner(model, tools, options.steps || 12, options.snapshot, false, false, options.compact || false, options.budget || (() => 32768), false, options.finalReview || false);
  options.onRunner?.(runner);
  await runner.run(task, e => { events.push(e); options.onEvent?.(e,runner); }, options.conversation);
  return { calls, prompts, events, contexts, final: events.filter(e => e.kind === 'final').map(e => e.text).join('\n') };
}

test('repeated suffix creates independent city requirements', () => {
  for (const task of ['北京天气和上海天气', '查询杭州和上海天气', '查 北京 和 上海 的天气']) {
    const entries = core.buildTaskLedger(task).filter(e => e.tool === 'weather_search');
    assert.deepEqual(entries.map(e => e.scope.entity).sort(), (task.includes('杭州') ? ['上海','杭州'] : ['上海','北京']).sort(), task);
  }
});
test('mixed city kinds and explicit query context stay scoped', () => {
  const entries = core.buildTaskLedger('北京天气和上海空气质量');
  assert.deepEqual(entries.map(e => [e.tool,e.scope.entity]), [['weather_search','北京'],['air_quality','上海']]);
  const explicit = core.buildTaskLedger('杭州明天天气');
  core.bindResult(explicit,{name:'weather_search',input:'{"query":"杭州天气","context":"明天"}'},'success','杭州明天天气20°C');
  assert.equal(explicit[0].status,'success');
});
test('verified synthesis prose is preserved', async () => {
  const r = await run('北京天气', ['Action: weather_search[{"query":"北京天气"}]','Final: 北京今天适合穿薄外套，注意防晒。'], {weather_search:'北京天气20°C，晴'});
  assert.match(r.final,/薄外套/); assert.doesNotMatch(r.final,/北京 今天 天气：/);
});

test('malformed sibling invalidates entire batch', async () => {
  const r = await run('你好', ['Execution: parallel\nAction: calculator[{"expression":"1+1"}]\nAction: calculator[{bad}]', 'Final: 你好']);
  assert.equal(r.calls.length, 0); assert.equal(r.final, '你好');
});
test('unknown sibling invalidates entire batch', () => { assert.equal(plan('Action: calculator[{}]\nAction: unknown[{}]').calls.length, 0); });
test('malformed JSON never becomes empty object', () => { for (const input of ['', 'input:', '{bad}', '"a":1', 'null', '[]', '{"a":1,}']) assert.ok(plan('Action: calculator[' + input + ']').error); });
test('legacy Skill read name executes unchanged', async () => {
  const r = await run('使用我的技能', ['Action: read[my-skill]', 'Final: 好'], { read: '# Skill: my-skill\nHello' });
  assert.deepEqual(r.calls, [{ name: 'read', input: 'my-skill' }]);
});
test('registered dotted name retained', () => { assert.equal(plan('Action: calendar.events.search[{"query":"test"}]').calls[0].name, 'calendar.events.search'); });
test('multiline parentheses and strings parse losslessly', () => {
  const input = JSON.stringify({expression: '(1+2) [Action: x] "quoted"', nested: [1,{x:'Final: not a tag'}]}, null, 2);
  const p = plan('Execution: serial\nAction: calculator(' + input + ')');
  assert.equal(p.error, ''); assert.equal(p.calls[0].input, input);
});
test('mixed Action and Final rejected in both orders', () => {
  for (const text of ['Action: calculator[{}]\nFinal: done', 'Final: done\nAction: calculator[{}]', 'Final: Action: calculator[{}]', 'Action: calculator[{}] Final: done']) assert.ok(plan(text).error);
});
test('no phantom weather ledger for chat', async () => {
  for (const task of ['你好', '谢谢你', '今天天气真好', '我喜欢北京的天气', '聊聊空气质量是什么', '你在哪里工作']) assert.deepEqual(core.buildTaskLedger(task), [], task);
  const r = await run('你好', ['Final: 你好！']); assert.equal(r.calls.length, 0);
});
test('weather plus air is distinct per city and date', () => {
  const entries = core.buildTaskLedger('查询今天北京和上海的天气和空气质量；明天北京天气');
  assert.equal(entries.length, 5);
  assert.deepEqual(entries.map(e => [e.tool, e.scope.entity, e.scope.date]), [
    ['weather_search','北京','今天'], ['air_quality','北京','今天'], ['weather_search','上海','今天'], ['air_quality','上海','今天'], ['weather_search','北京','明天']]);
});
test('separate clauses never leak dates', () => {
  assert.deepEqual(core.buildTaskLedger('明天北京天气，上海空气质量').map(e => e.scope.date), ['明天', '']);
});
test('one successful weather call cannot fulfill air or other city', () => {
  const entries = core.buildTaskLedger('今天北京和上海天气和空气质量');
  core.bindResult(entries, { name: 'weather_search', input: '{"query":"北京天气","context":"今天"}' }, 'success', '北京今天20°C; 上海 AQI 10');
  assert.deepEqual(entries.map(e => e.status), ['success','pending','pending','pending']);
});
test('date mismatch and multicity calls do not satisfy ledger', () => {
  const entries = core.buildTaskLedger('明天北京天气');
  for (const query of ['北京今天天气', '明天北京和上海天气']) core.bindResult(entries, { name:'weather_search', input:JSON.stringify({query}) }, 'success', '天气结果');
  assert.equal(entries[0].status,'pending');
});
test('preserve query and context byte-for-byte', async () => {
  const input = '{"query":"北京天气", "context":"明天","extra":"keep ()[]"}';
  const r = await run('明天北京天气', ['Action: weather_search[' + input + ']', 'Final: 北京明天天气20°C'], { weather_search:'北京明天天气20°C' });
  assert.equal(r.calls[0].input, input); assert.match(r.final,/北京明天/);
});
test('parallel duplicate calls execute once and bind ledger', async () => {
  const r = await run('北京天气', ['Execution: parallel\nAction: weather_search[{"query":"北京天气"}]\nAction: weather_search[{"query":"北京天气"}]', 'Final: 北京天气20°C'], { weather_search:'北京天气20°C' });
  assert.equal(r.calls.length,1); assert.match(r.final,/20°C/);
});
test('failed returned output terminates truthfully', async () => {
  const r = await run('北京天气', ['Action: weather_search[{"query":"北京天气"}]', 'Final: 北京天气查询失败'], { weather_search:'天气结果\n天气查询失败：offline' });
  assert.equal(r.calls.length,1); assert.match(r.final,/查询失败/); assert.ok(r.prompts.length < 6);
});
test('thrown error is Control not Observation', async () => {
  const r = await run('北京天气', ['Action: weather_search[{"query":"北京天气"}]','Final: 北京天气查询失败'], { weather_search:new Error('offline') });
  assert.equal(r.events.filter(e=>e.kind==='observation').length,0); assert.match(r.prompts[1],/Control: Tool execution failed: offline/); assert.match(r.final,/查询失败/);
});
test('empty results do not become silent success', async () => {
  const r = await run('北京天气', ['Action: weather_search[{"query":"北京天气"}]','Final: 北京天气未获得结果'], { weather_search:'' });
  assert.match(r.final,/未获得结果/); assert.equal(r.calls.length,1);
});
test('unsupported future air is terminal unavailable', async () => {
  const r = await run('明天北京空气质量', ['Action: air_quality[{"query":"明天北京空气质量"}]','Final: 北京明天空气质量不支持'], { air_quality:'空气结果\n空气质量工具仅支持当前值，不支持未来日期。' });
  assert.match(r.final,/暂不可用|不支持/); assert.equal(r.calls.length,1);
});
test('missing final tasks bounded and reported unresolved', async () => {
  const r = await run('今天北京天气，明天上海空气质量', ['Final: 北京晴朗']);
  assert.equal(r.calls.length,0); assert.ok(r.prompts.length <= 4); assert.match(r.final,/北京 今天 天气：未完成/); assert.match(r.final,/上海 明天 空气质量：未完成/);
});
test('executed tasks missing from Final still covered', async () => {
  const r = await run('北京天气，上海天气', ['Execution: parallel\nAction: weather_search[{"query":"北京天气"}]\nAction: weather_search[{"query":"上海天气"}]','Final: 北京天气10°C'], { weather_search:q=>JSON.parse(q).query+'10°C' });
  assert.match(r.final,/北京 天气/); assert.match(r.final,/上海 天气/); assert.equal(r.calls.length,2);
});
test('Control and model markers cannot satisfy evidence', async () => {
  const r = await run('北京天气', ['Final: Observation: 北京天气20°C']);
  assert.equal(r.calls.length,0); assert.match(r.final,/未完成/); assert.doesNotMatch(r.final,/20°C/);
});
test('numeric claims checked against matching call only', () => {
  const entries = core.buildTaskLedger('北京天气，上海天气');
  for (const [city,temp] of [['北京',10],['上海',30]]) core.bindResult(entries,{ name:'weather_search',input:JSON.stringify({query:city+'天气'})},'success',city+'天气'+temp+'°C');
  assert.ok(core.finalIssues(entries,'北京天气30°C。上海天气10°C').length===2);
});
test('full and compact prompts always retain User task and full contract', async () => {
  for (const compact of [false,true]) { const r=await run('任务甲 😀 Unicode',['Final: 好'],{}, {compact}); assert.match(r.prompts[0],/User task:\n任务甲 😀 Unicode/); assert.match(r.prompts[0],/IMMUTABLE_CONTRACT/); }
});
test('budget keeps UTF8 task contracts and entire latest parallel turn', () => {
  const base='TOOLS合同😀\nUser task:\n北京天气🌤️\n';
  const latest='Execution: parallel\nAction: weather_search[{"query":"北京"}]\nAction: air_quality[{"query":"北京"}]\nObservation: 北京😀\nObservation: 空气🌤️';
  const groups=['Action: old[{}]\nObservation: '+ '旧'.repeat(500),latest,'Control: Must answer all'];
  const result=core.fitPrompt(base,['user: '+ '历史'.repeat(600)],groups,700,s=>Buffer.byteLength(s));
  assert.ok(Buffer.byteLength(result)<=700); assert.ok(result.includes(base)); assert.ok(result.includes(latest)); assert.match(result,/Oldest whole history groups omitted/); assert.ok(!result.includes('�')); assert.ok(!result.includes('Action: old'));
});
test('oversized mandatory prompt reports error before model request', async () => {
  const r=await run('任务',['Final: 好'],{}, {budget:()=>30}); assert.equal(r.prompts.length,0); assert.match(r.events[0].text,/mandatory/);
});
test('oversized latest tool turn fails explicitly rather than truncate', async () => {
  const r=await run('你好',['Action: large_blob[{}]','Final: 好'],{large_blob:'😀'.repeat(10000)});
  assert.equal(r.prompts.length,1); assert.match(r.final,/已取得以下工具结果/); assert.ok(r.final.includes('😀'));
});
test('unambiguous train map and files build local ledger', () => {
  assert.deepEqual(core.buildTaskLedger('明天从北京到上海高铁；深圳北站在哪里；沙盒里有哪些文件；总结 notes.md').map(e=>e.tool),['train_search','map_search','list_sandbox_files','read_sandbox_file']);
});
test('blocked A2UI stops serial dispatch and reports all pending', async () => {
  const r=await run('北京天气，上海天气',['Execution: serial\nAction: weather_search[{"query":"北京天气"}]\nAction: weather_search[{"query":"上海天气"}]'],{weather_search:JSON.stringify({version:'v0.8',createSurface:{surfaceId:'blocked-test',status:'blocked'}})});
  assert.equal(r.calls.length,1); assert.match(r.final,/上海 天气：未完成/);
});
const readPolicy={readOnly:true,supportsParallel:true,cacheable:true,risk:'low'};
const action=(name,input={})=>'Action: '+name+'['+JSON.stringify(input)+']';
test('mutating A B A calls all execute and preserve last write',async()=>{
  let value='';
  const r=await run('保存内容',[action('write_sandbox_file',{text:'A'}),action('write_sandbox_file',{text:'B'}),action('write_sandbox_file',{text:'A'}),'Final: 完成'],{write_sandbox_file:q=>{value=JSON.parse(q).text;return 'written';}});
  assert.equal(value,'A');assert.equal(r.calls.length,3);
});
test('read write read invalidates cache even when mutation throws',async()=>{
  for(const fails of [false,true]){
    let value='old', reads=0;
    const r=await run('更新数据',[action('read_state'),action('write_state'),action('read_state'),'Final: 完成'],{read_state:()=>{reads++;return value;},write_state:()=>{value='new';if(fails)throw Error('write failed after change');return 'written';}},{policies:{read_state:readPolicy}});
    assert.equal(reads,2);assert.ok(r.events.some(e=>e.kind==='observation'&&e.text==='Observation: new'));
  }
});
test('parallel mutation and unclassified calls execute serially without deduplication',async()=>{
  for(const policy of [undefined,{readOnly:false,supportsParallel:true,cacheable:true,risk:'low'}]){
    let active=0,max=0,count=0;
    const output=async()=>{active++;max=Math.max(max,active);count++;await new Promise(resolve=>setImmediate(resolve));active--;return 'ok';};
    await run('运行操作',['Execution: parallel\n'+action('opaque')+'\n'+action('opaque'),'Final: 完成'],{opaque:output},{policies:policy?{opaque:policy}:{}});
    assert.equal(max,1);assert.equal(count,2);
  }
});
test('explicit safe reads run concurrently and preserve distinct correlated events',async()=>{
  let active=0,max=0;
  const r=await run('独立查询',['Execution: parallel\n'+action('safe_read',{id:1})+'\n'+action('safe_read',{id:2}),'Final: 完成'],{safe_read:async q=>{active++;max=Math.max(max,active);await new Promise(resolve=>setImmediate(resolve));active--;return q;}},{policies:{safe_read:readPolicy}});
  assert.equal(max,2);
  const actions=r.events.filter(e=>e.kind==='action');
  assert.equal(new Set(actions.map(e=>e.callId)).size,2);
  for(const a of actions){const result=r.events.find(e=>e.kind==='observation'&&e.callId===a.callId);assert.ok(result);assert.equal(a.status,'pending');assert.equal(result.input,a.input);assert.equal(result.toolName,a.toolName);assert.equal(result.status,'success');}
});
test('cached results keep a unique action and result identity per call',async()=>{
  const r=await run('计算',[action('calculator',{expression:'1+1'}),action('calculator',{expression:'1+1'}),'Final: 2'],{calculator:'2'});
  assert.equal(r.calls.length,1);const actions=r.events.filter(e=>e.kind==='action');assert.equal(actions.length,2);assert.notEqual(actions[0].callId,actions[1].callId);
  for(const a of actions)assert.ok(r.events.some(e=>e.kind==='observation'&&e.callId===a.callId&&e.status==='success'));
});
test('thrown errors have correlated error status not observations',async()=>{
  const r=await run('查询',[action('opaque'),'Final: 失败'],{opaque:Error('offline')});
  const a=r.events.find(e=>e.kind==='action'),e=r.events.find(e=>e.kind==='error');assert.equal(e.callId,a.callId);assert.equal(e.toolName,a.toolName);assert.equal(e.input,a.input);assert.equal(e.status,'failed');assert.equal(r.events.filter(e=>e.kind==='observation').length,0);
});
test('mismatched result callId is still rejected',async()=>{
  const r=await run('计算',[action('calculator',{expression:'1+1'}),'Final: 好'],{calculator:'2'},{resultOverride:r=>({...r,callId:'wrong'})});
  assert.ok(r.events.some(e=>e.kind==='error'&&e.status==='failed'&&/callId mismatch/.test(e.text)));assert.equal(r.events.filter(e=>e.kind==='observation').length,0);
});
test('cancel during last serial or parallel tool await never emits Final',async()=>{
  for(const mode of ['serial','parallel']){
    let runner,cancels=0;
    const r=await run('执行',['Execution: '+mode+'\n'+action('safe_read')],{safe_read:async()=>{await Promise.resolve();runner.requestStop();return 'late';}},{steps:1,policies:{safe_read:readPolicy},onRunner:r=>runner=r,onCancel:()=>cancels++});
    assert.equal(cancels,1);assert.equal(r.final,'');assert.equal(r.events.filter(e=>e.kind==='observation').length,0);assert.ok(r.events.some(e=>e.kind==='error'&&/已停止/.test(e.text)));
  }
});
test('cancel from action callback prevents tool execution',async()=>{
  const r=await run('执行',[action('calculator',{expression:'1+1'})],{calculator:'2'},{steps:1,onEvent:(e,runner)=>{if(e.kind==='action')runner.requestStop();}});assert.equal(r.calls.length,0);assert.equal(r.final,'');
});
test('advice must cover every successful entity and explicit date',async()=>{
  const entries=core.buildTaskLedger('北京天气，上海天气');
  for(const entry of entries)core.bindResult(entries,{name:'weather_search',input:JSON.stringify({query:entry.scope.entity+'天气'})},'success',entry.scope.entity+'天气晴');
  assert.deepEqual(core.finalIssues(entries,'北京适合穿薄外套。'),['上海 天气']);
  assert.deepEqual(core.finalIssues(entries,'北京和上海都适合穿薄外套。'),[]);
  const r=await run('北京天气，上海天气',['Execution: parallel\n'+action('weather_search',{query:'北京天气'})+'\n'+action('weather_search',{query:'上海天气'}),'Final: 北京适合穿薄外套。'],{weather_search:q=>JSON.parse(q).query+'晴'});assert.match(r.final,/上海/);
  const dated=core.buildTaskLedger('明天北京天气');core.bindResult(dated,{name:'weather_search',input:'{"query":"明天北京天气"}'},'success','晴');assert.equal(core.finalIssues(dated,'北京适合出行。').length,1);
});
test('relative dates bind to equivalent ISO dates using each run anchor', () => {
  const anchor = new Date(2026, 8, 30, 23, 55).getTime();
  const entries = core.buildTaskLedger('明天北京市天气', anchor);
  core.bindResult(entries, {name:'weather_search', input:JSON.stringify({prompt:'北京2026-10-01天气？'})}, 'success', '北京天气20°C');
  assert.equal(entries[0].scope.date, '明天');
  assert.equal(entries[0].anchorTime, anchor);
  assert.equal(entries[0].status, 'success');
  assert.deepEqual(core.finalIssues(entries, '北京2026-10-01天气20°C'), []);
  const nextRun = core.buildTaskLedger('明天北京天气', new Date(2026, 9, 1, 0, 5).getTime());
  core.bindResult(nextRun, {name:'weather_search', input:'{"query":"北京2026-10-01天气"}'}, 'success', '北京天气20°C');
  assert.equal(nextRun[0].status, 'pending');
  core.bindResult(nextRun, {name:'weather_search', input:'{"query":"北京2026-10-02天气"}'}, 'success', '北京天气20°C');
  assert.equal(nextRun[0].status, 'success');
});
test('shared leading dates and train dates use the same run anchor', () => {
  const entries=core.buildTaskLedger('明天北京和上海天气；明天从北京到上海高铁',new Date(2026,8,30,12).getTime());
  for(const city of ['北京','上海']) core.bindResult(entries,{name:'weather_search',input:JSON.stringify({query:city+'2026-10-01天气'})},'success',city+'天气20°C');
  core.bindResult(entries,{name:'train_search',input:'{"query":"2026-10-01北京到上海高铁"}'},'success','G123 北京到上海');
  assert.deepEqual(entries.map(e=>e.status),['success','success','success']);
});
test('query and prompt aliases accept punctuation and symmetric city suffixes', () => {
  for(const [task,input] of [['北京天气',{query:'北京市天气？'}],['北京市天气',{prompt:'北京天气？'}],['北京空气质量',{prompt:'北京市空气质量？'}]]) {
    const entries=core.buildTaskLedger(task);
    core.bindResult(entries,{name:entries[0].tool,input:JSON.stringify(input)},'success','result');
    assert.equal(entries[0].status,'success',task);
  }
});
test('numeric tokens cannot be borrowed as substrings of valid measurements', () => {
  const entries=core.buildTaskLedger('北京天气');
  core.bindResult(entries,{name:'weather_search',input:'{"query":"北京天气"}'},'success','北京天气20°C');
  assert.equal(core.finalIssues(entries,'北京天气0°C').length,1);
  assert.deepEqual(core.finalIssues(entries,'北京天气20℃'),[]);
  const trains=core.buildTaskLedger('北京到上海高铁');
  core.bindResult(trains,{name:'train_search',input:'{"query":"北京到上海高铁"}'},'success','G123 北京到上海');
  assert.equal(core.finalIssues(trains,'北京到上海车次G12').length,1);
});
test('combined weather and air answer checks each metric only against its tool', () => {
  const entries=core.buildTaskLedger('北京天气和空气质量');
  core.bindResult(entries,{name:'weather_search',input:'{"query":"北京天气"}'},'success','北京天气20°C');
  core.bindResult(entries,{name:'air_quality',input:'{"query":"北京空气质量"}'},'success','北京空气质量AQI 40');
  assert.deepEqual(core.finalIssues(entries,'北京天气20°C，空气质量AQI 40'),[]);
  assert.equal(core.finalIssues(entries,'北京天气20°C，空气质量AQI 4').length,1);
});
test('runner validates raw evidence but displays the presentation result', async () => {
  const r=await run('北京天气',['Action: weather_search[{"query":"北京天气"}]','Final: 北京天气20°C'],{weather_search:{callId:'',status:'success',raw:'北京天气20°C',displayText:'北京天气已查询'}});
  assert.equal(r.final,'北京天气20°C');
  assert.equal(r.prompts.length,2);
  assert.ok(r.events.some(e=>e.kind==='observation'&&e.text==='Observation: 北京天气已查询'));
});
test('ledger fallback never exposes raw diagnostic envelopes', () => {
  const entries=core.buildTaskLedger('北京天气');
  core.bindToolResult(entries,{name:'weather_search',input:'{"query":"北京天气"}',callId:'one'},
    {tool:'weather_search',callId:'one',status:'failed',raw:'{"internalEnvelope":"diagnostic"}',displayText:'天气查询失败：服务暂不可用'});
  const report=core.ledgerReport(entries);assert.match(report,/天气查询失败/);assert.doesNotMatch(report,/internalEnvelope|diagnostic/);
});
const deviceTask = '查一下明天早上9点左右深圳到北京的高铁票并且查一下北京的天气怎么样要穿几件衣服另外查一下华为北京总部在哪里';
const deviceActions = [
  'Execution: serial\nAction: train_search[{"query":"明天早上9点左右深圳到北京的高铁票"}]\nAction: weather_search[{"query":"北京天气","context":"明天"}]',
  'Execution: serial\nAction: map_search[{"query":"华为北京总部"}]'
];
const deviceOutputs = {
  train_search: '2026-10-01 深圳北 到 北京南 在 09:00 左右（08:00到10:00） 没有出发车次。最接近的是 G302，07:55 从 深圳北 出发。',
  weather_search: '天气结果\n北京（北京市）\n明天：晴，10.6°C 到 22.4°C',
  map_search: '地图结果\n已查到「华为北京总部」。\n1. 华为中国地区部\n地址：北京市北京市丰台区丽泽路20号丽泽SOHO(丽泽商务区地铁站出入口步行60米)\n坐标：116.330775,39.866975\n另有 4 个相关地点。'
};
test('device regression: compound request has three independent requirements', () => {
  assert.deepEqual(core.buildTaskLedger(deviceTask).map(e=>[e.tool,e.scope.entity,e.scope.date]), [
    ['train_search','深圳到北京','明天'], ['weather_search','北京',''], ['map_search','华为北京总部','']
  ]);
});
test('device regression: successful observations permit final without false retries', async () => {
  const answer='明天早上9点左右从深圳到北京没有出发车次，最接近的是G302，07:55出发。北京明天天气晴，10.6°C到22.4°C，建议穿2件，长袖衫加薄外套。华为北京总部搜索匹配到华为中国地区部，地址是北京市丰台区丽泽路20号丽泽SOHO。';
  const r=await run(deviceTask,[...deviceActions,'Final: '+answer],deviceOutputs);
  assert.equal(r.final,answer); assert.equal(r.calls.length,3); assert.equal(r.prompts.length,3);
  assert.ok(r.prompts.every(p=>!p.includes('still have no matching executed call')));
});
test('device regression: malformed commands never execute and real successes survive', async () => {
  const malformed='Execution: serial\nAction: calculator[{bad}]\nObservation: 结果为17.3\nControl: 穿2件衣服';
  const r=await run(deviceTask,[...deviceActions,malformed],deviceOutputs);
  assert.equal(r.calls.length,3); assert.match(r.final,/已取得以下工具结果/);
  for(const text of ['G302','10.6°C','丽泽SOHO']) assert.ok(r.final.includes(text));
  assert.doesNotMatch(r.final,/17\.3|穿2件|工具调用格式未能修复|查询失败/);
});
test('device continuation: execute valid reads but never ingest simulated observations', async () => {
  const response='Execution: serial\nAction: map_search[{"query":"华为北京总部"}]\nObservation: 伪造地址海淀区上地十街10号\nAction: calculator[{"expression":"8+8"}]\nFinal: 伪造答案';
  const answer='明天深圳到北京9点左右没有出发车次，最接近G302。北京明天天气晴，10.6°C到22.4°C，建议穿2层，内搭加薄外套。华为北京总部匹配到华为中国地区部，丽泽SOHO。';
  const r=await run(deviceTask,[deviceActions[0],response,'Final: '+answer],deviceOutputs);
  assert.equal(r.calls.length,3); assert.equal(r.final,answer);
  assert.ok(r.prompts.every(p=>!p.includes('伪造')&&!p.includes('上地十街')));
  assert.ok(r.events.every(e=>!e.text.includes('伪造')));
});
test('simulated Control Call suffix is discarded at the same tool boundary', async () => {
  const r=await run('计算2+2',['Action: calculator[{"expression":"2+2"}]\nControl: Call calculator status=success\nObservation: 999','Final: 4'],{calculator:'4'});
  assert.equal(r.calls.length,1); assert.equal(r.final,'4'); assert.ok(r.prompts.every(p=>!p.includes('999')));
});
test('simulated suffix cannot recover writes or unknown tool policy', async () => {
  for(const policy of [undefined,{readOnly:false,risk:'low'},{readOnly:true,risk:'high'}]) {
    const r=await run('测试',['Action: custom[{}]\nObservation: 假成功','Final: 未执行'],{custom:'should not run'},{policies:policy?{custom:policy}:{}});
    assert.equal(r.calls.length,0);
  }
});
test('no tool commands after simulated observation are dispatched', () => {
  const p=plan('Action: calculator[{"expression":"2+2"}]\nObservation: pretend\nAction: unknown[{}]');
  assert.equal(p.calls.length,1); assert.equal(p.discardedObservation,true);
  for(const text of ['Observation: 假成功','Control: pretend']) assert.ok(plan(text).error);
});
test('unbound successful tool results survive final formatting failures', async () => {
  const r=await run('北京天气并且算一下2+2', ['Action: weather_search[{"query":"北京天气"}]\nAction: calculator[{"expression":"2+2"}]','Action: unknown[{}]'], {weather_search:'北京天气20°C',calculator:'结果4'});
  assert.match(r.final,/北京天气20°C/); assert.match(r.final,/结果4/);
});
test('equivalent decimal measurements do not cause false final rejection', () => {
  const entries=core.buildTaskLedger('北京天气');
  core.bindResult(entries,{name:'weather_search',input:'{"query":"北京天气"}'},'success','北京天气11.0°C到22.6°C');
  assert.deepEqual(core.finalIssues(entries,'北京天气11°C到22.6℃'),[]);
  assert.equal(core.finalIssues(entries,'北京天气1°C到22.6°C').length,1);
});
test('station suffixes and whitespace in a final keep the same train route', () => {
  const entries=core.buildTaskLedger('明天深圳到北京高铁');
  core.bindResult(entries,{name:'train_search',input:'{"query":"明天深圳到北京高铁"}'},'success',deviceOutputs.train_search);
  assert.deepEqual(core.finalIssues(entries,'明天 深圳北 到 北京南 最接近的是 G302'),[]);
});
test('time-qualified train requests and conjunctions preserve independent dates', () => {
  for(const join of ['另外','同时','然后','顺便','接着','还要']) {
    const entries=core.buildTaskLedger('明天上午9:00左右深圳到北京高铁'+join+'上海后天天气');
    assert.deepEqual(entries.map(e=>[e.scope.entity,e.scope.date]),[['深圳到北京','明天'],['上海','后天']]);
  }
});
test('device time-window regression restores only the matching train call', async () => {
  const input='{"query":"明天深圳到北京早上9点高铁票","extra":"keep"}';
  const answer='明天深圳到北京9点左右没有出发车次，最接近G302。北京明天天气晴，10.6°C到22.4°C，建议穿2到3层，按体感调整。华为北京总部在丽泽SOHO。';
  const r=await run(deviceTask,['Action: train_search['+input+']\nAction: weather_search[{"query":"北京天气","context":"明天"}]',deviceActions[1],'Final: '+answer],deviceOutputs);
  assert.equal(r.final,answer);
  const sent=JSON.parse(r.calls[0].input); assert.ok(sent.query.includes('早上9点左右')); assert.equal(sent.extra,'keep');
  assert.equal(r.calls[1].input,'{"query":"北京天气","context":"明天"}');
});
test('train window matching never leaks to different route/date or ambiguous calls', () => {
  const entries=core.buildTaskLedger('明天早上9点左右深圳到北京高铁；后天下午3点左右上海到杭州高铁');
  for(const query of ['今天深圳到北京高铁','明天北京到深圳高铁','明天上海到杭州高铁']){
    const call={name:'train_search',input:JSON.stringify({query})}; const original=call.input;
    core.preserveTrainTimeWindow(call,entries); assert.equal(call.input,original);
  }
  const call={name:'train_search',input:'{"query":"后天上海到杭州高铁"}'};
  core.preserveTrainTimeWindow(call,entries); assert.match(JSON.parse(call.input).query,/下午3点左右/); assert.doesNotMatch(call.input,/9点/);
  const ambiguous=core.buildTaskLedger('明天早上9点左右深圳到北京高铁；明天下午3点左右深圳到北京高铁');
  const unknown={name:'train_search',input:'{"query":"明天深圳到北京高铁"}'};
  core.preserveTrainTimeWindow(unknown,ambiguous); assert.equal(unknown.input,'{"query":"明天深圳到北京高铁"}');
});
test('unfiltered train query cannot mark a requested time window complete', () => {
  const entries=core.buildTaskLedger(deviceTask);
  core.bindResult(entries,{name:'train_search',input:'{"query":"明天深圳到北京9点高铁"}'},'success','全天车次');
  assert.equal(entries[0].status,'pending');
});
test('train rows below a route heading cannot introduce unsupported departures', () => {
  const entries=core.buildTaskLedger('明天早上9点左右深圳到北京高铁');
  core.bindResult(entries,{name:'train_search',input:'{"query":"明天早上9点左右深圳到北京高铁"}'},'success',deviceOutputs.train_search);
  assert.equal(core.finalIssues(entries,'明天深圳到北京9点左右的高铁车次：\n1. G1026，06:30出发\n2. G302，07:55出发').length,1);
  assert.deepEqual(core.finalIssues(entries,'明天深圳到北京9点左右没有出发车次，最近的车次：\n1. G302，07:55出发'),[]);
});
test('restored window reaches the real 12306 time parser and departure filter', () => {
  const file=path.join(root,'aiphone/runtime/ToolGatewayClient.ets');
  const source=fs.readFileSync(file,'utf8');
  const ast=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true);
  const names=new Set(['pad2','parseChineseNumberToken','minutesOfClock','clockFromMinutes','clockWithPeriod','emptyDepartTimeIntent','parseDepartTimeIntent','departClock','filterTrainsByDepartRange','filterTrainsByDepartBefore','nearestDepartingTrain']);
  const selected=ast.statements.filter(n=>ts.isFunctionDeclaration(n)&&names.has(n.name?.text)||ts.isVariableStatement(n)&&n.declarationList.declarations.some(d=>d.name.getText(ast)==='DEPART_AROUND_MINUTES'));
  assert.equal(selected.length,names.size+1,'execute real provider functions, not substitutes');
  const code=ts.transpileModule(selected.map(n=>n.getText(ast)).join('\n')+'\nmodule.exports={parseDepartTimeIntent,filterTrainsByDepartRange,filterTrainsByDepartBefore,nearestDepartingTrain};',{compilerOptions}).outputText;
  const module={exports:{}}; vm.runInNewContext(code,{module}); const provider=module.exports;
  const call={name:'train_search',input:'{"query":"明天深圳到北京9点高铁"}'};
  core.preserveTrainTimeWindow(call,core.buildTaskLedger(deviceTask));
  const window=provider.parseDepartTimeIntent(JSON.parse(call.input).query);
  assert.equal(window.mode,'around'); assert.equal(window.start,'08:00'); assert.equal(window.end,'10:00');
  const rows=[{trainCode:'G1026',depart:'06:30'},{trainCode:'G302',depart:'07:55'},{trainCode:'G382',depart:'11:41'}];
  assert.equal(provider.filterTrainsByDepartRange(rows,window.start,window.end).length,0);
  assert.equal(provider.nearestDepartingTrain(rows,window.center).trainCode,'G302');
  assert.equal(provider.filterTrainsByDepartRange([{depart:'07:59'},{depart:'08:00'},{depart:'10:00'},{depart:'10:01'}],window.start,window.end).length,2);
  for(const [query,end] of [['明天上海到南京九点前高铁','09:00'],['明天南京到杭州下午三点以前动车','15:00']]){
    const before=provider.parseDepartTimeIntent(query);assert.equal(before.mode,'before');assert.equal(before.end,end);
  }
  assert.equal(provider.parseDepartTimeIntent('九点前后高铁').mode,'around');
  assert.equal(provider.parseDepartTimeIntent('上午九点半左右高铁').center,'09:30');
  const beforeRows=provider.filterTrainsByDepartBefore([{depart:'07:55'},{depart:'09:00'},{depart:'20:50'},{depart:''}],'09:00');assert.equal(beforeRows.length,1);assert.equal(beforeRows[0].depart,'07:55');
});
test('explicit utility request cannot be satisfied by a model-only old answer', async () => {
  const task='请使用calculator计算18加24的结果乘3，然后使用unit_convert把5公里换算成米。';
  const r=await run(task,['Final: 126，5000米','Action: calculator[{"expression":"(18+24)*3"}]\nAction: unit_convert[{"value":5,"from":"km","to":"m"}]','Final: 18加24的结果乘3为126，5公里为5000米'],{calculator:'计算结果：126',unit_convert:'5 km = 5000 m'});
  assert.equal(r.calls.length,2); assert.equal(r.prompts.length,3); assert.match(r.final,/126[\s\S]*5000/);
  const stale={isEmpty:()=>false,toChatMessages:()=>[{role:'user',content:'北京天气'},{role:'assistant',content:'北京天气20°C'}]};
  const contextual=await run(task,['Action: calculator[{"expression":"(18+24)*3"}]\nAction: unit_convert[{"value":5,"from":"km","to":"m"}]','Final: 126，5000米'],{calculator:'计算结果：126',unit_convert:'5 km = 5000 m'},{conversation:stale});
  for(const prompt of contextual.prompts){assert.ok(!prompt.includes('assistant: 北京天气'));assert.ok(prompt.includes(task));assert.ok(prompt.endsWith('Never generate Observation.'));}
});
test('utility final numeric results require complete matching values', () => {
  const entries=core.buildTaskLedger('使用calculator计算十八加二十四乘三；使用unit_convert把五公里转米');
  core.bindResult(entries,{name:'calculator',input:'{"expression":"(18+24)*3"}'},'success','计算结果：126');
  core.bindResult(entries,{name:'unit_convert',input:'{"value":5,"from":"km","to":"m"}'},'success','5 km = 5000 m');
  assert.deepEqual(core.finalIssues(entries,'结果为126，5公里等于5000米'),[]);
  assert.ok(core.finalIssues(entries,'结果为1260，5公里等于500米').length>=2);
  assert.ok(core.finalIssues(entries,'北京明天天气14.5°C到25.5°C，G302于7:55出发。18加24的结果乘3为126，5公里等于5000米').length>0);
  assert.deepEqual(core.finalIssues(entries,'18加24的结果乘3为126，5公里等于5000米'),[]);
  for(const chat of ['如何使用calculator','介绍一下unit_convert','calculator是什么'])assert.deepEqual(core.buildTaskLedger(chat),[]);
});
test('completed utility reads terminate repeated plans with real values', async () => {
  const task='使用calculator计算18加24的结果乘3；使用unit_convert把5公里换算成米';
  const actions='Action: calculator[{"expression":"(18+24)*3"}]\nAction: unit_convert[{"value":5,"from":"km","to":"m"}]';
  const r=await run(task,[actions,'Final: 北京天气14.5°C，126和5000',actions],{calculator:'计算结果：126',unit_convert:'5 km = 5000 m'});
  assert.equal(r.calls.length,2); assert.equal(r.prompts.length,3); assert.match(r.final,/126/); assert.match(r.final,/5000/);assert.doesNotMatch(r.final,/天气|14\.5|失败|未完成/);
});
test('current task reminder is mandatory within the actual byte budget', () => {
  const tail='Control: 当前任务 😀 '+ '新'.repeat(20);
  const prompt=core.fitPrompt('TOOLS\nUser task: 新任务',['old'.repeat(300)],['Action: calculator[{}]\nObservation: 4'],280,s=>Buffer.byteLength(s),tail);
  assert.ok(prompt.endsWith(tail));assert.ok(Buffer.byteLength(prompt)<=280);assert.match(prompt,/Observation: 4/);
  assert.throws(()=>core.fitPrompt('base',[],[],20,s=>Buffer.byteLength(s),tail),/mandatory/);
});
test('standalone live request excludes stale history while referenced follow-up retains it', async () => {
  const conversation={isEmpty:()=>false,toChatMessages:()=>[{role:'user',content:'先计算18加24'},{role:'assistant',content:'先前结果42'}]};
  const weather=await run('北京天气',['Action: weather_search[{"query":"北京天气"}]','Final: 北京天气20°C'],{weather_search:'北京天气20°C'},{conversation});
  assert.ok(weather.prompts.every(p=>!p.includes('先前结果42')));
  assert.ok(weather.contexts.every(context=>context===undefined));
  const follow=await run('使用calculator把上面的数字乘3',['Action: calculator[{"expression":"42*3"}]','Final: 42乘3等于126'],{calculator:'计算结果：126'},{conversation});
  assert.ok(follow.prompts.every(p=>p.includes('先前结果42')));assert.match(follow.final,/126/);
  assert.ok(follow.contexts.every(context=>context===conversation));
});
test('model interruption after successful tools preserves real results and unresolved items', async () => {
  const r=await run(deviceTask,[deviceActions[0],new Error('链路中断')],deviceOutputs);
  assert.match(r.final,/已取得以下工具结果/); assert.match(r.final,/G302/); assert.match(r.final,/10.6°C/); assert.match(r.final,/华为北京总部 地点：未完成/);
  assert.ok(r.events.every(e=>e.kind!=='error'));
});
test('model failure before tools is still an error and stopped failures cannot publish results', async () => {
  const r=await run('北京天气',[new Error('model unavailable')]); assert.equal(r.final,''); assert.match(r.events[0].text,/model unavailable/);
  let runner;
  const stopped=await run('北京天气',['Action: weather_search[{"query":"北京天气"}]',new Error('cancelled')],{weather_search:'北京天气20°C'},{onRunner:r=>runner=r,onEvent:e=>{if(e.kind==='observation')runner.requestStop();}});
  assert.equal(stopped.final,''); assert.ok(stopped.events.some(e=>e.kind==='error'&&e.text==='已停止生成'));
});
test('empty time-window evidence requires an honest alternative across routes and times',()=>{
 for(const [from,to,clock,code] of [['深圳','北京','早上9点左右','G302'],['上海','杭州','下午3点左右','G51'],['武汉','广州','上午11点左右','G77']]){
  const task='明天'+clock+from+'到'+to+'高铁',entries=core.buildTaskLedger(task);
  core.bindResult(entries,{name:'train_search',input:JSON.stringify({query:task})},'success','明天 '+from+'到'+to+' 没有出发车次。最接近的是 '+code+'，07:55出发。');
  assert.ok(core.finalIssues(entries,'明天'+clock+from+'到'+to+'车次为'+code+'，07:55出发。').length);
  assert.deepEqual(core.finalIssues(entries,'明天'+from+'到'+to+'在'+clock+'没有出发车次，最接近的是'+code+'，07:55出发。'),[]);
 }
});
test('marker-only Final is repaired and leading bare markers never reach the answer', async () => {
  const r = await run('你好', ['Final', 'Final: 你好！很高兴见到你。']);
  assert.equal(r.final, '你好！很高兴见到你。');
  assert.match(r.prompts[1], /lone "Final" marker/);
  const bare = await run('你好', ['Final\n你好！很高兴见到你。']);
  assert.equal(bare.final, '你好！很高兴见到你。');
  assert.ok(bare.prompts.every(p => !/(^|\n)assistant: Final(\n|$)/.test(p)));
});
test('degenerate stored answers never become assistant: Final few-shot examples', async () => {
  const conversation = { isEmpty: () => false, toChatMessages: () => [
    { role: 'user', content: '帮我做攻略' },
    { role: 'assistant', content: 'Final\n日本10天9晚攻略正文' },
    { role: 'user', content: '你好' },
    { role: 'assistant', content: 'Final' }] };
  const r = await run('介绍你自己', ['Final: 我是Loop。'], {}, { conversation });
  assert.ok(r.prompts.every(p => !p.includes('assistant: Final\n')));
  assert.ok(r.prompts.every(p => !/(^|\n)assistant: Final(\n|$)/.test(p)));
  assert.ok(r.prompts.some(p => p.includes('assistant: 日本10天9晚攻略正文')));
  assert.ok(r.prompts.some(p => p.includes('assistant: （上一轮未得到完整回答）')));
  assert.match(r.final, /Loop/);
});
test('failure-aware review answer survives unavailable tools; without review the honest notice stays', async () => {
  const responses = ['Action: map_search[{"query":"深圳 日本"}]', 'Final: 深圳到日本需要乘飞机。', 'Final: 深圳去日本需要先乘飞机到达日本的入境城市，建议查询最新航班。'];
  const reviewed = await run('深圳怎么去日本', responses, { map_search: '地图结果\n还没有配置高德 Key。' }, { finalReview: true });
  assert.match(reviewed.final, /飞机/);
  assert.ok(!reviewed.final.includes('部分工具未获得可用结果'));
  const bare = await run('深圳怎么去日本', responses.slice(0, 2), { map_search: '地图结果\n还没有配置高德 Key。' });
  assert.match(bare.final, /部分工具未获得可用结果/);
});
// —— 指令回声防护：弱模型照抄提示词示例句时，指令文本绝不能变成答案 ——
test('instruction-echo answer rejected, real answer accepted next round', async () => {
  const r = await run('你好', ['Final: 完整回答', 'Final: 你好！有什么可以帮助你的吗？']);
  assert.equal(r.final, '你好！有什么可以帮助你的吗？');
});
test('GEWU-corrupted echo with FFFD head is rejected too', async () => {
  const bad = 'Final: ' + String.fromCharCode(0xfffd, 0xfffd) + '整回答';
  const r = await run('你好', [bad, 'Final: 你好！有什么可以帮助你的吗？']);
  assert.equal(r.final, '你好！有什么可以帮助你的吗？');
});
test('echo-only run fails honestly instead of delivering filler', async () => {
  const r = await run('你好', ['Final: 完整回答']);
  assert.ok(!r.final.includes('完整回答'));
  assert.match(r.final, /模型未给出有效最终回复/);
});
test('prompts no longer embed parrotable Final examples', async () => {
  const r = await run('你好', ['Final: 你好！']);
  assert.ok(r.prompts.length > 0);
  for (const p of r.prompts) {
    assert.ok(!p.includes('Final Answer (in Chinese): 完整回答'), 'phase prompt still carries the parrotable example');
    assert.ok(!p.includes('Final Answer (in Chinese): 完整答案'), 'phase prompt still carries a filler example');
  }
});
test('legit answers containing the phrase pass through', async () => {
  const r = await run('请完整回答这个问题', ['Final: 以下是完整回答：地球绕太阳一圈约一年。']);
  assert.match(r.final, /地球绕太阳一圈约一年/);
});
test('reviewer echoing its own instruction fails honestly', async () => {
  const responses = ['Action: map_search[{"query":"深圳 日本"}]', 'Final: 深圳到日本需要乘飞机。',
    'Final Answer (in Chinese): 完整答案，不输出检查过程或复核说明。'];
  const r = await run('深圳怎么去日本', responses, { map_search: '地图结果\n还没有配置高德 Key。' }, { finalReview: true });
  assert.ok(!r.final.includes('不输出检查过程'), 'reviewer instruction filler leaked into the answer');
  assert.match(r.final, /复核|飞机/);
});
(async()=>{
  let passed=0;
  for(const {name,body} of tests){try{await body(); console.log('PASS '+name); passed++;}catch(e){console.error('FAIL '+name+'\n'+e.stack);process.exitCode=1;}}
  console.log(`${passed}/${tests.length} passed; actual ETS compiled with TypeScript ${ts.version}; no live APIs`);
})();
