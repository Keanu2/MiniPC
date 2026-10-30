/* Run: node apps/agent-client/agent-core/tests/react-compatibility.test.cjs
 * Optional TYPESCRIPT_PATH points to a local typescript.js. No network required.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const candidates = [process.env.TYPESCRIPT_PATH, 'typescript',
  'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript',
  'D:/command-line-tools/hvigor/hvigor/node_modules/typescript'].filter(Boolean);
let ts;
for (const candidate of candidates) { try { ts = require(candidate); break; } catch {} }
if (!ts) throw new Error('Install TypeScript locally or set TYPESCRIPT_PATH to its compiler module.');

const source = fs.readFileSync(path.join(__dirname, '../src/main/ets/agent/ReActResponseCompatibility.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  fileName: 'ReActResponseCompatibility.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true },
  reportDiagnostics: true
});
const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
assert.deepEqual(errors.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), [], 'ETS syntax errors');
const moduleObject = { exports: {} };
vm.runInThisContext('(function(require,module,exports){' + compiled.outputText + '\n})',
  { filename: 'ReActResponseCompatibility.ets' })(() => ({}), moduleObject, moduleObject.exports);
const { extractCompatibleFinalAnswer, extractCompatiblePlainAnswer, stripLeadingFinalMarker } = moduleObject.exports;

const tests = [];
const test = (name, body) => tests.push({ name, body });

test('marker-only responses are rejected as answers', () => {
  for (const text of ['Final', 'final', 'Final Answer', 'answer', '最终答案', '答案', '**Final**', '# Final', 'Final\n']) {
    assert.equal(extractCompatiblePlainAnswer(text), null, JSON.stringify(text));
  }
});

test('leading bare marker line is stripped from plain answers', () => {
  assert.equal(extractCompatiblePlainAnswer('Final\n日本10天9晚攻略\nDay 1 抵达东京'), '日本10天9晚攻略\nDay 1 抵达东京');
  assert.equal(extractCompatiblePlainAnswer('Final Answer\n42'), '42');
  assert.equal(extractCompatiblePlainAnswer('答案\n今天晴'), '今天晴');
});

test('bare marker lines inside an answer stay untouched', () => {
  assert.equal(extractCompatiblePlainAnswer('问题\n答案\n42'), '问题\n答案\n42');
  assert.equal(extractCompatiblePlainAnswer('常见问题\nfinal\n更多内容'), '常见问题\nfinal\n更多内容');
});

test('colon forms and plain chat keep working', () => {
  assert.equal(extractCompatibleFinalAnswer('Final: 42'), '42');
  assert.equal(extractCompatibleFinalAnswer('Final:'), null);
  assert.equal(extractCompatiblePlainAnswer('Final: 你好'), '你好');
  assert.equal(extractCompatiblePlainAnswer('你好！很高兴见到你。'), '你好！很高兴见到你。');
});

test('stripLeadingFinalMarker only eats leading marker lines', () => {
  assert.equal(stripLeadingFinalMarker('Final\n日本攻略'), '日本攻略');
  assert.equal(stripLeadingFinalMarker('Final'), '');
  assert.equal(stripLeadingFinalMarker('Final\nFinal\n内容'), '内容');
  assert.equal(stripLeadingFinalMarker('\n\nFinal\n\n今天晴\n'), '今天晴');
  assert.equal(stripLeadingFinalMarker('你好'), '你好');
  assert.equal(stripLeadingFinalMarker('前文\nFinal\n后文'), '前文\nFinal\n后文');
});

(async () => {
  let passed = 0;
  for (const { name, body } of tests) { try { await body(); console.log('PASS ' + name); passed++; } catch (e) { console.error('FAIL ' + name + '\n' + e.stack); process.exitCode = 1; } }
  console.log(`${passed}/${tests.length} passed; actual ETS compiled with TypeScript ${ts.version}; no live APIs`);
})();
