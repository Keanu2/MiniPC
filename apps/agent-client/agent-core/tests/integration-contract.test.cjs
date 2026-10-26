const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
function load(relative, stubs = {}) {
  const file = path.resolve(root, relative);
  const source = fs.readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, {fileName: file.replace(/\.ets$/, '.ts'), reportDiagnostics: true, compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}});
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const mod = {exports: {}};
  vm.runInThisContext('(function(require,module,exports){' + compiled.outputText + '\n})', {filename: file})(name => {
    if (!(name in stubs)) throw new Error('Unexpected import ' + name + ' in ' + relative);
    return stubs[name];
  }, mod, mod.exports);
  return mod.exports;
}
const events = load('src/main/ets/agent/AgentEvent.ets');
const {AgentEvent: E, AgentEventKind: K} = events;
const agentTool = load('src/main/ets/agent/AgentTool.ets');
const toolsSource = fs.readFileSync(path.join(root, 'src/main/ets/agent/ToolRegistry.ets'), 'utf8');
const toolStubs = {};
for (const m of toolsSource.matchAll(/from '([^']+)'/g)) toolStubs[m[1]] = {};
toolStubs['./AgentTool'] = agentTool;
toolStubs['./ToolContract'] = load('src/main/ets/agent/ToolContract.ets');
toolStubs['./A2uiObservationDigest'] = {summarizeA2uiObservation() {return {isA2ui: false, shouldStop: false};}};
const {ToolRegistry} = load('src/main/ets/agent/ToolRegistry.ets', toolStubs);
let eventBatch = [];
class Runner {async run(_prompt, listener) {for (const event of eventBatch) listener(event);}}
const backendStubs = {
  '../agent/AgentEvent': events, '../agent/ReActAgentRunner': {ReActAgentRunner: Runner},
  '../agent/ToolRegistry': {ToolRegistry}, '../agent/ConversationContext': {ConversationContext: class {addUser(){} addAssistant(){}}},
  '../model/LlmProvider': {LlmProvider: class {isConfigured(){return false;}}},
  '../model/OpenAiCompatibleModel': {}, '../model/ScriptedLocalModel': {ScriptedLocalModel: class {}},
  './AiphoneA2ui': {aiphoneInfoJsonl(){return '';}, splitJsonl(){return [];}},
  './AiphoneToolDefinitions': {allToolDefinitions(){return [];}}, './AiphoneToolExecutor': {}
};
const {LoopBackend} = load('src/main/ets/aiphone/LoopBackend.ets', backendStubs);
const request = {prompt:'test',history:[],modelSettings:{},surfaceId:'s',actionId:'a',maxSteps:3};
const tool = name => ({name: () => name, description: () => 'test', run: async () => 'ok'});
let passed = 0;
async function test(name, fn) {await fn(); passed++; console.log('PASS ' + name);}
const sent = []; let throwSend = false;
const {inferenceClient: client, INFERENCE_STOPPED} = load('../entry/src/main/ets/model/InferenceClient.ets', {
  '@kit.PerformanceAnalysisKit': {hilog:{info(){}, warn(){}}},
  '../nearby/LinkEnhanceChannel': {nearbyChannel: {inferenceReady: () => true, readyEpoch: () => 0, setInferenceHandler() {}, setInferenceLinkHandler() {}, send(m) {if (throwSend) throw new Error('disconnected'); sent.push(m);}}},
  './InferenceWire': {utf8Bytes: s => Buffer.from(s), sha256Hex: () => ''}, './Utf8Repair': {repairUtf8FromSource: s => s},
  '../protocol/ChatProtocol': load('../entry/src/main/ets/protocol/ChatProtocol.ets', {'@kit.ArkTS': {util: {}}})
});
const profile = {ready:true,modelId:'m',modelRevision:'1',promptFormat:'loop-react-split-v1',maxPromptBytes:32768,maxOutputTokens:2048,maxContextTokens:32768};
function capabilities(id) {client.onMessage({type:'infer.capabilities',requestId:id,profiles:[profile]});}
(async () => {
  await test('serial two actions keep separate call IDs and inputs', async () => {
    eventBatch = [new E(K.ACTION,'same(first) [call-1]','call-1','same','first'), new E(K.ACTION,'same(second) [call-2]','call-2','same','second'),new E(K.OBSERVATION,'one','call-1'),new E(K.OBSERVATION,'two','call-2')];
    const result = await new LoopBackend().run(request, {});
    assert.deepEqual(result.toolCalls.map(t => [t.callId,t.input,t.observation]), [['call-1','first','one'],['call-2','second','two']]);
  });
  await test('parallel completion order binds by callId not latest action', async () => {
    eventBatch = [new E(K.ACTION,'a(x) [a]','a','a','x'),new E(K.ACTION,'b(y) [b]','b','b','y'),new E(K.OBSERVATION,'B','b'),new E(K.OBSERVATION,'A','a')];
    const result = await new LoopBackend().run(request, {});
    assert.deepEqual(result.toolCalls.map(t => [t.toolId,t.input,t.observation]), [['b','y','B'],['a','x','A']]);
  });
  await test('legacy action batch uses FIFO rather than lastAction', async () => {
    eventBatch = [new E(K.ACTION,'a(x) [call-1]'),new E(K.ACTION,'b(y) [call-2]'),new E(K.OBSERVATION,'A'),new E(K.OBSERVATION,'B')];
    const result = await new LoopBackend().run(request, {});
    assert.deepEqual(result.toolCalls.map(t => [t.callId,t.toolId]), [['call-1','a'],['call-2','b']]);
  });
  await test('unmatched explicit callId never consumes a different action', async () => {
    eventBatch = [new E(K.ACTION,'a(x)','a','a','x'),new E(K.OBSERVATION,'unknown','bad'),new E(K.OBSERVATION,'A','a')];
    const result = await new LoopBackend().run(request, {});
    assert.equal(result.toolCalls[0].toolId,''); assert.equal(result.toolCalls[1].input,'x');
  });
  await test('registry unknown and unclassified policies default deny', async () => {
    const registry = new ToolRegistry(); registry.register(tool('unknown.safe.read'));
    for (const name of ['missing','unknown.safe.read']) {const m = registry.metadata(name); assert.equal(m.readOnly,false); assert.equal(m.supportsParallel,false); assert.equal(m.cacheable,false); assert.equal(m.risk,'high');}
    const result = await registry.run('unknown.safe.read','','id'); assert.equal(result.metadata.cacheable,false); assert.equal(result.callId,'id');
  });
  await test('registry clamps mutating policy and revokes stale privileges', async () => {
    const registry = new ToolRegistry();
    registry.register(tool('write'),{readOnly:false,supportsParallel:true,cacheable:true,risk:'low'});
    assert.equal(registry.metadata('write').supportsParallel,false); assert.equal(registry.metadata('write').cacheable,false);
    registry.register(tool('read'),{readOnly:true,supportsParallel:true,cacheable:true,risk:'low'});
    assert.equal(registry.metadata('read').cacheable,true); registry.register(tool('read'));
    assert.equal(registry.metadata('read').cacheable,false);
    assert.equal(registry.metadata('time').cacheable,false);
  });
  await test('reset settles original readiness and stale capability cannot revive it', async () => {
    const old = client.ensureReady(); const id = sent.at(-1).requestId;
    assert.equal(client.ensureReady(),old); client.reset(); assert.match(await old,/连接已中断/);
    const fresh = client.ensureReady(); const nextId = sent.at(-1).requestId;
    capabilities(id); assert.equal(client.isReady(),false); assert.notEqual(id,nextId);
    capabilities(nextId); assert.equal(await fresh,''); assert.equal(client.isReady(),true); client.reset();
  });
  await test('cancel settles pending negotiation and ignores late capability', async () => {
    const ready = client.ensureReady(); const id = sent.at(-1).requestId;
    client.cancel(); assert.equal(await ready,INFERENCE_STOPPED); capabilities(id); assert.equal(client.isReady(),false);
  });
  await test('cancel settles active completion even if transport send throws', async () => {
    client.profile = profile; const completion = client.complete('hello'); const id = Array.from(client.calls.values())[0].requestId;
    throwSend = true; assert.doesNotThrow(() => client.cancel()); throwSend = false;
    await assert.rejects(completion,/已停止生成/); assert.equal(client.calls.size,0);
    client.onMessage({type:'infer.delta',requestId:id,seq:1,text:'late'}); assert.equal(client.calls.size,0); client.reset();
  });
  await test('capability send failure settles promise immediately', async () => {
    throwSend = true; const ready = client.ensureReady(); throwSend = false;
    assert.match(await ready,/连接已中断/); assert.equal(client.negotiatePromise,null);
  });
  await test('RemoteComputeModel forwards optional cancellation', async () => {
    let cancelled = 0; const {RemoteComputeModel} = load('../entry/src/main/ets/model/RemoteComputeModel.ets', {'@loop/agent-core': {splitReActPrompt: () => null}, './InferenceClient': {inferenceClient: {cancel(){cancelled++;}, complete: async p => p}}});
    const model = new RemoteComputeModel(); model.cancel(); assert.equal(cancelled,1); assert.equal(await model.complete('ok'),'ok');
  });
  console.log(passed + ' integration contracts passed');
})().catch(error => {console.error(error); client.reset(); process.exitCode=1;});
