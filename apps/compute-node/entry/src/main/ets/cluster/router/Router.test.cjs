// node Router.test.cjs [path/to/typescript/lib/typescript.js]
// 路由模块测试：least_load（原 pickNode）零回归（断言自 ComputeRouter.test.cjs
// 原样迁入）、注册表/回落，以及 cluster/router 的零依赖纪律护栏。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../../tests/ets-harness.cjs');

// 迷你 require 解析器：把相对 import 递归加载进同一模块图；非相对说明符
// （externals 之外）直接抛错——这就是零依赖纪律的运行时护栏。
function loadGraph(entryFile, externals = {}) {
  const cache = new Map();
  function req(fromDir, name) {
    if (!name.startsWith('.')) {
      if (externals[name] !== undefined) return externals[name];
      throw new Error('router modules must stay dependency-free: ' + name);
    }
    const file = path.resolve(fromDir, name + '.ets');
    if (cache.has(file)) return cache.get(file);
    const box = { exports: {}, require: (n) => req(path.dirname(file), n),
      Date, Map, Set, Math, Number, Array, JSON, Error };
    vm.runInNewContext(transpile(file), box);
    cache.set(file, box.exports);
    return box.exports;
  }
  return req(path.dirname(entryFile), './' + path.basename(entryFile, '.ets'));
}

// 纪律护栏：router/ 下纯文件的 import 必须相对；RouterSettings 只允许 @kit.CoreFileKit。
for (const file of fs.readdirSync(__dirname).filter((f) => f.endsWith('.ets'))) {
  for (const line of fs.readFileSync(path.join(__dirname, file), 'utf8').split('\n')) {
    if (!/^\s*import\s/.test(line) || !/\bfrom\b/.test(line)) continue; // 跨行 import 的首行由 from 行把关
    const ok = /from\s+'\./.test(line) ||
      (file === 'RouterSettings.ets' && /from\s+'@kit\.CoreFileKit'/.test(line));
    assert.ok(ok, file + ' must only use relative imports: ' + line.trim());
  }
}
loadGraph(path.join(__dirname, 'RouterRegistry.ets'));

const { ScheduleNode, RouteContext } = loadGraph(path.join(__dirname, 'RouterTypes.ets'));
const { createRouter, knownRouterNames, routerLabel, routerChoices } =
  loadGraph(path.join(__dirname, 'RouterRegistry.ets'));

function node(partial) {
  const item = new ScheduleNode();
  Object.assign(item, partial);
  return item;
}
function route(nodes, needs = [], taskTier = 0) {
  const ctx = new RouteContext();
  ctx.nodes = nodes; ctx.needs = needs; ctx.taskTier = taskTier;
  return createRouter('least_load').route(ctx);
}

// —— least_load（原 pickNode）零回归，断言文本原样 ——
assert.equal(route([]), null);
const imageOnly = node({ name: 'VL', model: 'VL', capabilities: ['vision'] });
assert.equal(route([imageOnly]), null, 'legacy empty needs still means text; VL-only node must not accept it');
assert.equal(route([imageOnly], ['vision']), imageOnly, 'VL-only node accepts image tasks');
assert.equal(route([node({ name: '空', model: '' })]), null, 'no model is not schedulable');
const idle = node({ name: '空闲', isSelf: true, model: 'Qwen', requests: 0, memAvail: 1000 });
const busy = node({ name: '忙', model: 'Qwen', requests: 2, memAvail: 9000 });
assert.equal(route([busy, idle]).name, '空闲', 'idle preferred over busy even with less memory');
const self = node({ name: '本机', isSelf: true, model: 'Qwen', requests: 1, memAvail: 2000 });
const peer = node({ name: '对端', model: 'Qwen', requests: 1, memAvail: 8000 });
assert.equal(route([self, peer]).name, '对端', 'same load prefers more memory');
assert.equal(route([self, node({ name: '对端2', model: 'Qwen', requests: 1, memAvail: 2000 })]).isSelf, true,
  'equal load and memory prefers self');
assert.equal(route([busy]).name, '忙', 'all busy still returns a modeled node');
// 能力过滤：needs 是硬门槛，排在空闲/负载/内存/本机之前
const textIdle = node({ name: '空闲文本', model: 'Qwen', requests: 0, memAvail: 9000 });
const visionBusy = node({ name: '忙碌多模态', model: 'VL', requests: 3, memAvail: 100, capabilities: ['text', 'vision'] });
assert.equal(route([textIdle, visionBusy], ['vision']).name, '忙碌多模态',
  'capability gates before the idle preference');
assert.equal(route([textIdle], ['vision']), null, 'no capable node fails closed');
assert.equal(route([node({ name: '默认', model: 'Qwen', requests: 0 })], ['vision']), null,
  'a node without declared capabilities is text-only');
assert.equal(route([textIdle, visionBusy], ['text']).name, '空闲文本',
  'declared needs still follow the load order');
assert.equal(route([textIdle, visionBusy]).name, '空闲文本', 'no needs keeps the old behaviour');
// 档位：负载平手时贴近决胜（贴近再平手 → 就高）；负载不平手时空闲决胜（自然降档）
const weakIdle = node({ name: '弱档闲', model: 'Lite', requests: 0, memAvail: 500, modelTier: 1 });
const midIdle = node({ name: '中档闲', model: 'Mid', requests: 0, memAvail: 500, modelTier: 2 });
const strongIdle = node({ name: '强档闲', model: 'Big', requests: 0, memAvail: 500, modelTier: 3 });
const strongBusy = node({ name: '强档忙', model: 'Big', requests: 1, memAvail: 9000, modelTier: 3 });
assert.equal(route([weakIdle, midIdle], [], 3).name, '中档闲', 'load tie picks the closer tier');
assert.equal(route([strongBusy, weakIdle], [], 3).name, '弱档闲',
  'heavy task downgrades to the idle weak node when the strong one is busy');
assert.equal(route([strongIdle, weakIdle], [], 1).name, '弱档闲', 'light task prefers the weak node');
assert.equal(route([weakIdle, strongIdle], [], 2).name, '强档闲',
  'closeness tie at tier 2 prefers the higher tier');
assert.equal(route([strongBusy], [], 3).name, '强档忙', 'tier never blocks an otherwise usable node');
assert.equal(route([node({ name: '强档纯文本', model: 'Big', modelTier: 3 })], ['vision']), null,
  'capability still fails closed regardless of tier');
// 零回归：全默认集群（无人声明）任何 taskTier 都与 0 / 不传参同赢家
const defaultA = node({ name: '默认甲', isSelf: true, model: 'Qwen', requests: 0, memAvail: 2000 });
const defaultB = node({ name: '默认乙', model: 'Qwen', requests: 0, memAvail: 8000 });
for (const taskTier of [0, 1, 2, 3]) {
  assert.equal(route([defaultA, defaultB], [], taskTier).name, '默认乙',
    'default cluster ignores taskTier=' + taskTier);
}
assert.equal(route([defaultA, defaultB]).name, '默认乙', 'omitted taskTier keeps the legacy winner');
assert.equal(route([defaultA, defaultB], [], 3).name, route([defaultA, defaultB], [], 0).name);

// —— 注册表 ——
assert.equal(createRouter('least_load').name(), 'least_load');
assert.equal(createRouter('nope').name(), 'least_load', 'unknown name falls back to least_load');
assert.equal(JSON.stringify(knownRouterNames()), JSON.stringify(['least_load']));
for (const name of knownRouterNames()) {
  assert.ok(routerLabel(name).length > 0, 'label exists for ' + name);
}
const choices = routerChoices();
assert.equal(JSON.stringify(choices.map((c) => c.name)), JSON.stringify(['least_load']));
assert.equal(choices[0].label, '最小负载（空闲优先，档位决胜）');
console.log('PASS: least_load zero-regression, registry fallback, dependency-free guard');
