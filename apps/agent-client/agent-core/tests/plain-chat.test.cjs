const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets/model');
function load(name, imports) {
  const compiled = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    fileName: name + '.ts', reportDiagnostics: true,
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
  });
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const mod = {exports: {}};
  vm.runInNewContext(compiled.outputText, {module: mod, exports: mod.exports, require: name => {
    assert.ok(Object.hasOwn(imports, name), 'Unexpected import: ' + name);
    return imports[name];
  }});
  return mod.exports;
}
const {buildPlainChatPrompt: prompt} = load('PlainChat', {'./InferenceWire': {utf8Bytes: s => Buffer.from(s)}});
test('new ordinary chat sends user content unchanged with no Agent instruction', () => {
  assert.equal(prompt('你好，帮我解释这段附件\n正文内容', 32768), '你好，帮我解释这段附件\n正文内容');
});
test('budget checks current UTF-8 input without clipping message or attachment', () => {
  assert.equal(prompt('追问', 6), '追问');
  assert.throws(() => prompt('追问', 5), /输入限制/);
  assert.throws(() => prompt('附件：\n' + '中'.repeat(30), 20), /输入限制/);
});
test('mode defaults off, survives reload, and reports persistence failures', async () => {
  const values = new Map(); let flushes = 0, fail = false;
  const store = {getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
    putSync: (key, value) => values.set(key, value), flush: async () => {flushes++; if (fail) throw new Error('disk');}};
  const imports = {'@kit.ArkData': {preferences: {getPreferencesSync: () => store}}};
  let settings = load('ChatModeStore', imports);
  assert.equal(settings.loadChatMode({}), 'chat');
  assert.equal(settings.loadAgentEnabled({}), false);
  await settings.saveChatMode({}, 'agent');
  settings = load('ChatModeStore', imports);
  assert.equal(settings.loadChatMode({}), 'agent');
  assert.equal(settings.loadAgentEnabled({}), true);
  await settings.saveChatMode({}, 'agent_split');
  assert.equal(settings.loadChatMode({}), 'agent_split');
  await settings.saveAgentEnabled({}, false);
  assert.equal(settings.loadChatMode({}), 'chat');
  assert.equal(settings.loadAgentEnabled({}), false); assert.equal(flushes, 3);
  values.delete('chat_mode'); values.set('agent_enabled', true);
  assert.equal(settings.loadChatMode({}), 'agent_split');
  fail = true; await assert.rejects(settings.saveAgentEnabled({}, true), /disk/);
  values.set('chat_mode', 'nope'); values.set('agent_enabled', 'true');
  assert.equal(settings.loadAgentEnabled({}), false);
  const unreadable = load('ChatModeStore', {'@kit.ArkData': {preferences: {getPreferencesSync: () => {throw new Error('disk');}}}});
  assert.equal(unreadable.loadAgentEnabled({}), false);
});
