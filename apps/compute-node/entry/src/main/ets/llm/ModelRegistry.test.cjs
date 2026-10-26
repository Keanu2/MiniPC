// node ModelRegistry.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
// 单一 files 映射模拟文件系统：键为完整路径，值为内容；'' 表示空文件。
const files = {};
let now = 0;
function markReady(base) {
  for (const name of ['api_config.json', 'params', 'tokenizer.json']) files[base + '/' + name] = 'x';
}
/** VL 布局：vl_params + tokenizer.json（旧版 Qwen2.5-VL-3B-NPU 部署形态）。 */
function markVlReady(base) {
  for (const name of ['vl_params', 'tokenizer.json']) files[base + '/' + name] = 'x';
}
const context = {
  exports: {}, ArrayBuffer, Date: { now: () => (now += 2000) }, require(name) {
    if (name === '@kit.CoreFileKit') {
      return { fileIo: {
        OpenMode: { READ_ONLY: 0, CREATE: 1, READ_WRITE: 2, TRUNC: 4 },
        listFileSync(path) {
          if (!path.endsWith('/models')) throw new Error('missing');
          const names = [];
          for (const key of Object.keys(files)) {
            if (key.indexOf(path + '/') !== 0) continue;
            const rest = key.slice(path.length + 1);
            const name = rest.slice(0, rest.indexOf('/'));
            if (name.length > 0 && names.indexOf(name) < 0) names.push(name);
          }
          return names;
        },
        openSync(path, mode) {
          if (mode & 1) files[path] = '';
          if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error('missing');
          return { fd: path };
        },
        readSync(fd) {
          return files[fd].length > 0 ? 1 : 0;
        },
        closeSync() {},
        writeSync(fd, content) { files[fd] = content; },
        renameSync(from, to) { files[to] = files[from]; delete files[from]; },
        readTextSync(path) {
          if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error('missing');
          return files[path];
        }
      } };
    }
    if (name === '../protocol/ChatProtocol') return { CAPABILITY_TAGS: ['text', 'vision'] };
    return {};
  }
};
vm.runInNewContext(transpile(__dirname + '/ModelRegistry.ets'), context);
const { readyModelDirs, manifestCapabilities, deviceCapabilities, selectModelDir, modelRequestType,
  readinessOf, isVlLayout } = context.exports;
// 空仓：没有 models 目录
assert.equal(readyModelDirs('/app').join(','), '', 'no models dir yields no dirs');
assert.equal(deviceCapabilities('/app').join(','), '', 'no models means no capabilities');
assert.equal(selectModelDir('/app', []).length, 0, 'no ready dir fails closed');
assert.equal(selectModelDir('/app', ['vision']).length, 0, 'no ready dir fails closed for needs too');
assert.equal(modelRequestType('/app', 'Any'), 'qwen2', 'unreadable api_config falls back to qwen2');
// 两个就绪模型（文本 + 多模态）与一个残缺目录
const TEXT_DIR = 'Qwen2.5-7B-Instruct-Q4_N_0';
const VL_DIR = 'Qwen2.5-VL-7B-Q4_N_0';
const VL_LAYOUT_DIR = 'Z-VL3B-NPU';
const BROKEN_DIR = 'A-broken-model';
markReady('/app/models/' + TEXT_DIR);
markReady('/app/models/' + VL_DIR);
markVlReady('/app/models/' + VL_LAYOUT_DIR);
files['/app/models/' + BROKEN_DIR + '/api_config.json'] = 'x';
files['/app/models/' + BROKEN_DIR + '/params'] = 'x';
assert.equal(readyModelDirs('/app').join(','), [TEXT_DIR, VL_DIR, VL_LAYOUT_DIR].join(','),
  'only ready dirs are listed, sorted by name; both layouts qualify');
assert.equal(readinessOf('/app/models/' + BROKEN_DIR).indexOf('tokenizer.json') >= 0, true,
  'readiness names the first missing file');
assert.equal(isVlLayout('/app/models/' + VL_LAYOUT_DIR), true, 'vl_params marks the VL layout');
assert.equal(isVlLayout('/app/models/' + TEXT_DIR), false, 'text layout has no vl_params');
// manifest 能力：缺省、未知标签、去重、损坏
assert.equal(manifestCapabilities('/app', TEXT_DIR).join(','), 'text', 'missing manifest is text-only');
assert.equal(manifestCapabilities('/app', VL_LAYOUT_DIR).join(','), 'text,vision',
  'VL layout without manifest honestly defaults to text+vision');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["text","vision"]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text,vision');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["vision","fly","vision"]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'vision', 'unknown tags drop and dupes dedupe');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":[]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text', 'empty declaration falls back to text');
files['/app/models/' + VL_DIR + '/manifest.json'] = 'not json';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text', 'broken manifest falls back to text');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["text","vision"]}';
// 设备能力 = 并集（VL 布局缺省也贡献 vision）
assert.equal(deviceCapabilities('/app').join(','), 'text,vision', 'device capability is the union');
// 按需选模：vision → 首个覆盖目录（VL_DIR 排序靠前）；空需求 → 首个文本布局目录（绝不落到 VL 权重目录）
assert.equal(selectModelDir('/app', []), TEXT_DIR, 'text request prefers the GEWU text dir');
assert.equal(selectModelDir('/app', ['text']), TEXT_DIR);
assert.equal(selectModelDir('/app', ['vision']), VL_DIR, 'vision needs pick the multimodal dir');
delete files['/app/models/' + VL_DIR + '/manifest.json'];
files['/app/models/' + VL_DIR + '/api_config.json'] = '{"name":"qwen2vl"}';
assert.equal(selectModelDir('/app', ['vision']), VL_LAYOUT_DIR,
  'VL layout dir covers vision even without a manifest');
// 请求类型跟随 api_config
assert.equal(modelRequestType('/app', VL_DIR), 'qwen2vl', 'api_config name drives the request type');
files['/app/models/' + VL_DIR + '/api_config.json'] = '{"type":"llama"}';
assert.equal(modelRequestType('/app', VL_DIR), 'llama', 'type is used when name is absent');
// manifestTier：缺失/损坏/越界一律 2 强档（fail open）；两档下 3 已属越界
const { manifestTier, deviceTier } = context.exports;
assert.equal(manifestTier('/app', TEXT_DIR), 2, 'missing manifest is strong tier 2');
files['/app/models/' + TEXT_DIR + '/manifest.json'] = '{"tier":1}';
assert.equal(manifestTier('/app', TEXT_DIR), 1);
files['/app/models/' + TEXT_DIR + '/manifest.json'] = '{"tier":2}';
assert.equal(manifestTier('/app', TEXT_DIR), 2);
for (const [body, why] of [['{"tier":0}', 'below range'], ['{"tier":3}', 'legacy 3 now above range'],
  ['{"tier":4}', 'above range'], ['{"tier":2.5}', 'fractional'], ['{"tier":"strong"}', 'non-numeric'], ['not json', 'broken json']]) {
  files['/app/models/' + TEXT_DIR + '/manifest.json'] = body;
  assert.equal(manifestTier('/app', TEXT_DIR), 2, why + ' falls back to strong 2');
}
files['/app/models/' + TEXT_DIR + '/manifest.json'] = '{"tier":1}';
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"tier":1}';
files['/app/models/' + VL_LAYOUT_DIR + '/manifest.json'] = '{"tier":1}';
assert.equal(deviceTier('/app'), 1, 'all-weak manifests yield device tier 1');
files['/app/models/' + VL_LAYOUT_DIR + '/manifest.json'] = '{"tier":2}';
assert.equal(deviceTier('/app'), 2, 'device tier takes the maximum (one strong dir lifts it)');
assert.equal(deviceTier('/none'), 0, 'no ready model means tier 0 (field omitted on the wire)');
// 双文本目录 tier1/tier2：档位贴近选目录，taskTier=0 保持旧行为
markReady('/tier/models/A-lite');
markReady('/tier/models/B-strong');
files['/tier/models/A-lite/manifest.json'] = '{"tier":1}';
files['/tier/models/B-strong/manifest.json'] = '{"tier":2}';
assert.equal(selectModelDir('/tier', [], 0), 'A-lite', 'taskTier 0 keeps the old sorted-first behaviour');
assert.equal(selectModelDir('/tier', []), 'A-lite', 'omitted taskTier defaults to 0');
assert.equal(selectModelDir('/tier', [], 2), 'B-strong', 'complex task picks the strong dir');
assert.equal(selectModelDir('/tier', [], 1), 'A-lite', 'simple task picks the lite dir');
// 双 VL 目录：vision 需求同样按档位贴近选
markVlReady('/tier2/models/V-A');
markVlReady('/tier2/models/V-B');
files['/tier2/models/V-A/manifest.json'] = '{"capabilities":["text","vision"],"tier":1}';
files['/tier2/models/V-B/manifest.json'] = '{"capabilities":["text","vision"],"tier":2}';
assert.equal(selectModelDir('/tier2', ['vision'], 2), 'V-B', 'complex vision task prefers the strong VL dir');
assert.equal(selectModelDir('/tier2', ['vision'], 1), 'V-A');
// 只有低档 VL 目录时重任务降档使用它（档位绝不构成可用性门槛）
files['/tier2/models/V-B/manifest.json'] = '{"capabilities":["text","vision"],"tier":1}';
assert.equal(selectModelDir('/tier2', ['vision'], 2), 'V-A', 'complex vision task downgrades to the only capable VL tier');
// 私有 VL SDK 需要图片，绝不把纯文本交给 VL 权重的 GEWU probe。
assert.equal(selectModelDir('/tier2', [], 2), '', 'VL-only deployment has no text engine');
// 能力不覆盖仍然 fail closed
assert.equal(selectModelDir('/tier', ['vision'], 2), '', 'no vision coverage fails closed regardless of tier');
const { modelSelection, saveModelSelection, activeModelDirs } = context.exports;
markReady('/switch/models/Small');
markReady('/switch/models/Large');
markVlReady('/switch/models/VL-A');
markVlReady('/switch/models/VL-B');
files['/switch/models/Small/manifest.json'] = '{"tier":1}';
files['/switch/models/Large/manifest.json'] = '{"tier":2}';
assert.equal(selectModelDir('/switch', [], 2), 'Large');
assert.equal(saveModelSelection('/switch', {model:'Small'}), '');
assert.equal(selectModelDir('/switch', [], 2), 'Small', 'manual pin overrides task tier');
assert.equal(activeModelDirs('/switch').join(','), 'Small');
assert.equal(deviceCapabilities('/switch').join(','), 'text', 'inactive image model is not advertised');
assert.equal(deviceTier('/switch'), 1, 'inactive stronger models do not raise the advertised tier');
assert.equal(selectModelDir('/switch', ['vision']), '', 'image requests cannot bypass disable');
assert.equal(saveModelSelection('/switch', {model:'VL-B'}), '');
assert.equal(selectModelDir('/switch', ['vision']), 'VL-B');
assert.equal(selectModelDir('/switch', []), '', 'selected VL cannot be sent to the GEWU text engine');
assert.equal(deviceCapabilities('/switch').join(','), 'vision', 'VL SDK is honestly advertised as image-only');
assert.notEqual(saveModelSelection('/switch', {model:'../outside'}), '', 'only discovered models can be selected');
assert.equal(modelSelection('/switch').model, 'VL-B', 'invalid settings keep the previous selection');
assert.equal(saveModelSelection('/switch', {model:'Small'}), '');
const reopened = { ...context, exports: {} };
vm.runInNewContext(transpile(__dirname + '/ModelRegistry.ets'), reopened);
assert.equal(reopened.exports.selectModelDir('/switch', [], 2), 'Small', 'manual selection survives application restart');
delete files['/switch/models/Small/params'];
assert.equal(selectModelDir('/switch', []), '', 'missing pinned model never silently runs another one');
assert.equal(saveModelSelection('/switch', {model:''}), '', 'automatic mode can recover a missing pin');
assert.equal(selectModelDir('/switch', []), 'Large');
console.log('PASS: model discovery, manifest capabilities, VL layout, per-need model selection, request type, manifest tier and tiered dir picking');
// New GEWU families use their deployed API configuration without model-name branches.
const qwen35=JSON.parse(require('node:fs').readFileSync(require('node:path').resolve(__dirname,'../../../../../../../configs/models/qwen3_5/api_config.json'),'utf8'));
markReady('/new-family/models/Qwen3.5-9B-Q4_N_0_G128');
files['/new-family/models/Qwen3.5-9B-Q4_N_0_G128/api_config.json']=JSON.stringify(qwen35);
assert.equal(modelRequestType('/new-family','Qwen3.5-9B-Q4_N_0_G128'),'qwen3_5');
assert.equal(selectModelDir('/new-family',[]),'Qwen3.5-9B-Q4_N_0_G128');
assert.equal(deviceCapabilities('/new-family').join(','),'text');
assert.equal(qwen35.hparams.linear_layers_per_group,3);assert.equal(qwen35.format,'gewu');
