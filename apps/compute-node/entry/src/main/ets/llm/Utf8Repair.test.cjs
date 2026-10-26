// node Utf8Repair.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
// Utf8Repair 必须零 import：裸 vm（无 require）即可加载，与 TaskRules 同款约束。
const context = { exports: {} };
vm.runInNewContext(transpile(__dirname + '/Utf8Repair.ets'), context);
const { sanitizeModelOutput, repairUtf8FromSource } = context.exports;
// 源文件保持纯 ASCII：U+FFFD 一律运行时构造，避免不可见字符进仓库。
const BAD = String.fromCharCode(0xFFFD);
const clean = (text) => text.indexOf(BAD) < 0;

// 干净文本恒等（幂等的前提）
assert.equal(sanitizeModelOutput('你好，世界', '任意源'), '你好，世界');
assert.equal(sanitizeModelOutput('', '源'), '');
// 空 source：无从修复，剔除后返回
assert.equal(sanitizeModelOutput('a' + BAD + 'b', ''), 'ab');
// 全 FFFD：剔除后为空（LocalChat 视作无内容，fail closed）
assert.equal(sanitizeModelOutput(BAD + BAD + BAD, '写一首诗'), '');

// 修复命中：输出回显源文本，FFFD 恰好替换锚点前一个字符（股）
assert.equal(sanitizeModelOutput('证明勾' + BAD + '定理的方法如下', '证明勾股定理的方法'),
  '证明勾股定理的方法如下');
// 修复命中：任务文本在提示词里出现两次（User task 段 + Control 尾巴），
// 两处锚点前字符一致（写）→ 仍修复
assert.equal(sanitizeModelOutput(BAD + '一首诗，题目是春', 'User task:\n写一首诗\nControl: 写一首诗'),
  '写一首诗，题目是春');

// 真机案例 1（Max，猫）：任务文本不含锚点 → 不修复，剔除（宁缺字不出错字）
assert.equal(sanitizeModelOutput(BAD + BAD + BAD + '是一种常见的家养动物', '猫是什么动物；写Python快排代码'),
  '是一种常见的家养动物');
// 真机案例 2（Max，以下）：同理剔除
assert.equal(sanitizeModelOutput(BAD + BAD + '是Python冒泡排序代码示例', '写Python冒泡排序代码'),
  '是Python冒泡排序代码示例');
// 否决案例：锚点在源里的唯一出现前面是 FFFD（损坏的历史被回显进提示词）→ 不许照抄
assert.equal(sanitizeModelOutput(BAD + '乙丙', '甲' + BAD + '乙丙'), '乙丙');
// 大于 6 的连续 FFFD 不进修复循环（防御），剔除照常
assert.equal(sanitizeModelOutput(BAD.repeat(7) + 'abc', '源文本'), 'abc');

// repairUtf8FromSource 原语义不变：无 FFFD / 有 FFFD 无锚点时原样返回（不剔除）
assert.equal(repairUtf8FromSource(BAD + '乙丙', '别的'), BAD + '乙丙');
assert.equal(repairUtf8FromSource('干净', ''), '干净');

// 幂等：sanitize 两层套娃与一层等价（InferenceHost 对已清洗 delta 的二次清洗）
for (const [output, source] of [
  ['证明勾' + BAD + '定理的方法如下', '证明勾股定理的方法'],
  [BAD + BAD + '是Python冒泡排序代码示例', '写Python冒泡排序代码'],
  ['干净文本', '源']
]) {
  const once = sanitizeModelOutput(output, source);
  assert.equal(sanitizeModelOutput(once, source), once);
  assert.ok(clean(once), 'sanitized output must not contain U+FFFD');
}
console.log('PASS: model output sanitization (repair, strip, veto, idempotence)');
