const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

// 两端各有一份同源拷贝：聊天端决定最终显示，算力端只影响本机仪表盘预览。保持逐字节一致。
const chatCopy = path.resolve(__dirname, '../../entry/src/main/ets/model/Utf8Repair.ets');
const computeCopy = path.resolve(__dirname, '../../../compute-node/entry/src/main/ets/llm/Utf8Repair.ets');
assert.equal(fs.readFileSync(chatCopy, 'utf8'), fs.readFileSync(computeCopy, 'utf8'), 'Utf8Repair copies drifted');

const source = fs.readFileSync(chatCopy, 'utf8');
const compiled = ts.transpileModule(source, {fileName: 'Utf8Repair.ts', compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}, reportDiagnostics: true});
assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
const moduleValue = {exports: {}};
vm.runInThisContext('(function(require,module,exports){' + compiled.outputText + '\n})', {filename: chatCopy})(() => {
  throw new Error('Utf8Repair must not import anything');
}, moduleValue, moduleValue.exports);
const repair = moduleValue.exports.repairUtf8FromSource;

let passed = 0;
function test(name, body) { body(); passed++; console.log('PASS ' + name); }

test('text without FFFD is unchanged', () => {
  assert.equal(repair('Final Answer (in Chinese): 深圳去日本', '深圳怎么去日本'), 'Final Answer (in Chinese): 深圳去日本');
});

test('multi-char anchor repair still works', () => {
  assert.equal(repair('A���好，今天', '你说好，今天天气不错'), 'A说好，今天');
});

test('single-char repair fires when answer and prompt independently agree', () => {
  const output = 'Final Answer (in Chinese): ���圳去日本可以乘坐飞机。从深圳宝安国际机场出发比较方便。';
  const prompt = 'Final review phase.\n原始问题：\n深圳怎么去日本\n本轮工具证据：\nmap_search unavailable 还没有配置高德 Key。';
  assert.equal(repair(output, prompt), 'Final Answer (in Chinese): 深圳去日本可以乘坐飞机。从深圳宝安国际机场出发比较方便。');
});

test('answer echo plus prompt agreement restores an inverted-prone opener', () => {
  const output = 'Final Answer (in Chinese): ���以先从长沙前往北京、上海等城市，可以先乘高铁到上海，再从上海飞往日本。';
  const prompt = 'User task:\n长沙怎么去日本\n历史回答：深圳去日本可以乘坐飞机。';
  assert.equal(repair(output, prompt), 'Final Answer (in Chinese): 可以先从长沙前往北京、上海等城市，可以先乘高铁到上海，再从上海飞往日本。');
});

test('prompt evidence alone is not enough to repair', () => {
  assert.equal(repair('���圳到日本', '深圳怎么去日本？深圳很大。'), '���圳到日本');
});

test('answer evidence alone is not enough to repair', () => {
  assert.equal(repair('���圳到日本，可以先到深圳再乘船。', '长沙有什么好玩的地方'), '���圳到日本，可以先到深圳再乘船。');
});

test('answer and prompt disagreeing keeps FFFD', () => {
  const output = 'Final Answer (in Chinese): ���去日本的航班很多，很多人选择周末去。';
  const prompt = '从长沙出发去东京有什么方案';
  assert.equal(repair(output, prompt), 'Final Answer (in Chinese): ���去日本的航班很多，很多人选择周末去。');
});

test('agreed negative replacement is rejected', () => {
  const output = 'Final Answer (in Chinese): ���能携带上机。刀具不能随身携带，需要办理托运。';
  const prompt = '充电宝不能带上飞机吗';
  assert.equal(repair(output, prompt), 'Final Answer (in Chinese): ���能携带上机。刀具不能随身携带，需要办理托运。');
});

test('single-char fallback rejects ASCII anchor char', () => {
  assert.equal(repair('���abc', '说abc 亦abc'), '���abc');
});

test('single-char fallback only applies to a one-char loss (run <= 3)', () => {
  assert.equal(repair('����圳去日本', '深圳怎么去日本'), '����圳去日本');
});

test('anchor char absent everywhere keeps FFFD', () => {
  assert.equal(repair('���航线', '深圳怎么去日本'), '���航线');
});

console.log(`utf8-repair: ${passed} passed`);
