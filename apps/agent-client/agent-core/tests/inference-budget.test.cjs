const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const file = path.resolve(__dirname, '../../entry/src/main/ets/model/InferenceClient.ets');
const source = fs.readFileSync(file, 'utf8');
const compiled = ts.transpileModule(source, {fileName: 'InferenceClient.ts', compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}, reportDiagnostics: true});
assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
const sent = [];
const stubs = {
  '../protocol/ChatProtocol': { validTaskSnapshot: () => true },
  '@kit.PerformanceAnalysisKit': {hilog: {info() {}, warn() {}}},
  '../nearby/LinkEnhanceChannel': {nearbyChannel: {send(m) {sent.push(m);}, inferenceReady() {return true;}, readyEpoch() {return 0;}}},
  './InferenceWire': {utf8Bytes: s => Buffer.from(s, 'utf8'), sha256Hex: () => ''},
  './Utf8Repair': {repairUtf8FromSource: s => s}
};
const moduleValue = {exports: {}};
vm.runInThisContext('(function(require,module,exports){' + compiled.outputText + '\n})', {filename: file})(name => {
  if (!stubs[name]) throw new Error('Unexpected import ' + name);
  return stubs[name];
}, moduleValue, moduleValue.exports);
const client = moduleValue.exports.inferenceClient;
const profile = (bytes, extra = {}) => ({ready: true, promptFormat: 'loop-react-split-v1', maxPromptBytes: bytes, maxOutputTokens: 2048, maxContextTokens: 32768, ...extra});
let passed = 0;
function test(name, body) { body(); passed++; console.log('PASS ' + name); }
(async () => {
  test('unnegotiated budget fails explicitly', () => assert.throws(() => client.promptBudgetBytes(), /有效的输入预算/));
  test('budget clamps to wire ceiling', () => {client.profile = profile(65536); assert.equal(client.promptBudgetBytes(), 32768);});
  test('lower negotiated budget is honored', () => {client.profile = profile(1024); assert.equal(client.promptBudgetBytes(), 1024);});
  test('invalid negotiated budget fails explicitly', () => {client.profile = profile(NaN); assert.throws(() => client.promptBudgetBytes());});
  test('negotiation skips invalid first profile and selects ready compatible one', () => {
    client.negotiateId = 'cap-test';
    client.onMessage({type: 'infer.capabilities', requestId: 'cap-test', profiles: [profile(-1), profile(4096), profile(8192)]});
    assert.equal(client.promptBudgetBytes(), 4096);
  });
  test('negotiation rejects all invalid profiles', () => {
    client.profile = null; client.negotiateId = 'bad';
    client.onMessage({type: 'infer.capabilities', requestId: 'bad', profiles: [profile(4096, {maxOutputTokens: NaN}), profile(4096, {ready: false})]});
    assert.equal(client.failed(), true); assert.equal(client.isReady(), false);
  });
  client.profile = profile(4);
  await assert.rejects(client.complete('中文'), /6\/4 bytes/);
  assert.equal(sent.length, 0); assert.equal(client.calls.size, 0);
  passed++; console.log('PASS oversize UTF-8 input rejected before request state/send');
  test('retry waiting sends display-only queue and cancellation notices without image payloads', () => {
    const state={requestId:'queue-test',epoch:0,firstStarted:Date.now()-3000,queuedSince:Date.now()-2000,
      waiting:false,timer:null,retryTimer:null,hooks:{},image:'PRIVATE IMAGE',prompt:'PRIVATE PROMPT'};
    client.wait(state);
    const queued=sent.at(-1);assert.equal(queued.source,'queue-display');assert.equal(queued.state,'queued');
    assert(Number(queued.text)>=2000);assert(!JSON.stringify(queued).includes('PRIVATE'));
    client.fail(state,'cancelled');assert.equal(sent.at(-1).state,'cleared');assert.equal(client.waitingCalls.length,0);
  });
  console.log(passed + ' tests passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
