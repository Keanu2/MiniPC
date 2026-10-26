// node TaskRules.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
// TaskRules 必须零 import：裸 vm（无 require）即可加载，与 ComputeRouter 同款约束。
const context = { exports: {}, Error, Number, Math };
vm.runInNewContext(transpile(__dirname + '/TaskRules.ets'), context);
const { classifyTask, classifyFromMessages, taskTextOf } = context.exports;
const ask = (text, extra = {}) => classifyTask({ text, turns: 1, hasImage: false, ...extra });
const repeat = (char, count) => char.repeat(count);
// 轻（1）：短、无标记、会话浅、预算小
assert.equal(ask('你好').tier, 1);
assert.equal(ask(repeat('好', 80)).tier, 1, '80 汉字权重恰 160，仍是轻');
assert.equal(ask(repeat('好', 81)).tier, 2, '81 汉字权重 162，超过轻档阈值');
assert.equal(ask('你好', { turns: 3 }).tier, 1, '三轮会话仍轻');
assert.equal(ask('你好', { turns: 4 }).tier, 2, '第四轮开始按常规处理');
// 输出预算不再参与定档：agent 端的固定 2048 上限曾是 path B 全员判复杂的元凶
assert.equal(ask('你好', { maxOutputTokens: 2048 }).tier, 1,
  '线上唯一的预算来源是 agent 固定上限 2048，常量不该把问候顶成复杂档');
// 生成类标记只挡轻、不构成重
assert.equal(ask('帮我写一首诗').tier, 2);
assert.equal(ask('帮我写一份邮件').tier, 2);
// 复杂（2）：代码
assert.equal(ask('帮我```python\nprint(1)\n```').tier, 2, '代码围栏');
assert.equal(ask('快速排序算法').tier, 2, '强代码词');
assert.equal(ask('这个函数报错了').tier, 2, '报错也是强代码词');
assert.equal(ask('import os\nimport sys').tier, 2, '同一弱代码词出现两次仍只算一个');
assert.equal(ask('import os\nreturn 1').tier, 2, '两个不同弱代码词构成复杂');
assert.equal(ask('python好用吗').tier, 2, '单个弱代码词不够重，但足够否决轻');
// H2b 共现：生成意图动词 × 代码名词（被定语隔开、短语级强代码词匹配不到的缺口）
assert.equal(ask('生成Python快排代码').tier, 2, '生成+代码共现构成复杂（实测案例）');
assert.equal(ask('生成Python快排代码').reason, '代码生成:生成+代码');
assert.equal(ask('帮我写Python快排代码').tier, 2);
assert.equal(ask('写个快排').tier, 2);
assert.equal(ask('写一个排序').tier, 2, '排序也是代码名词');
// 单调性：加定语不该降档（两档下同为复杂）
assert.equal(ask('生成代码').tier, ask('生成Python快排代码').tier);
// 两档收敛：复杂证据与中间地带（常规）同落 2，只有干净短问才落 1
assert.equal(ask('生成Python快排代码').tier, ask('帮我写一首诗').tier);

// 弱代码词大小写不敏感：大写变体同样计数
assert.equal(ask('Python好用吗').tier, 2, '大写 Python 计弱词、挡轻');
assert.equal(ask('Python和Java选哪个').tier, 2, '两个不同弱词（大写变体）构成复杂');
// 复杂（2）：数学推理（短文本仍然复杂）
assert.equal(ask('证明勾股定理').tier, 2);
assert.equal(ask('解方程 x+1=2').tier, 2);
// 复杂（2）：长文生成（动词 + 权重 ≥ 600）
assert.equal(ask('总结' + repeat('段', 300)).tier, 2, '总结 + 300 汉字（权重 604）触发长文生成');
assert.equal(ask('总结' + repeat('段', 200)).tier, 2, '总结 + 200 汉字不够长文阈值，也不是轻');
assert.equal(ask(repeat('段', 300)).tier, 2, '没有长文动词时纯长度只是常规');
// 空输入与默认
assert.equal(ask('').tier, 2);
assert.equal(ask('').reason, '空输入');
// 附图不改档位，只进 reason
const shot = ask('看图', { hasImage: true });
assert.equal(shot.tier, 1);
assert.ok(shot.reason.indexOf('附图') >= 0, 'reason 标注附图: ' + shot.reason);
// 确定性：同输入两次 deep-equal
assert.deepEqual(ask('帮我总结这段话' + repeat('字', 300)), ask('帮我总结这段话' + repeat('字', 300)));
// taskTextOf 按 '\n' 连接
assert.equal(taskTextOf([{ role: 'a', content: 'x' }, { role: 'b', content: 'y' }]), 'x\ny');
assert.equal(taskTextOf([]), '');
// classifyFromMessages：所有调用方的统一入口
const from = (contents, hasImage = false) =>
  classifyFromMessages(contents.map((content) => ({ role: 'user', content })), hasImage);
// agent 框架脚手架：只分类最后一个 User task 之后的真实任务文本
assert.equal(from(['Tools: search\nreturn: 结果\nUser task:\n你好']).tier, 1,
  '脚手架噪声被剥掉，短任务判轻');
assert.equal(from(['User task:\n证明勾股定理']).tier, 2, 'User task 段里的数学仍判复杂');
assert.equal(from(['Tools: search', 'User task:\n你好', 'User task:\n再看一次']).tier, 1,
  '多个 User task 取最后一个');
// 无标记文本整段分类（path A 形状）：脚手架词没有被标记包裹时仍参与分类
assert.equal(from(['return 数据']).tier, 2, '无标记时整段参与分类：单个弱词否决轻');
// 真实 ReAct 提示词形状（ReActAgentRunner.buildPrompt + fitPrompt，逐字对照生成
// 代码抄录）：标记之后还跟着 Control 尾巴——它把任务复述一遍，并带上
// "Never generate Observation" 等英文协议文案。权重膨胀（~220 > 160）和
// generate 生成标记曾把"你好"顶成复杂档（实测：infer relay tier=2）。
const realFirstStep = 'You are a ReAct agent.\nTools:\n- search: 搜索\n' +
  'Current device local datetime: Wed Oct 15 2026.\nUser task:\n你好\n\n' +
  'Control: Current user request (answer only this; earlier history is context, not current evidence):\n你好\n' +
  'Control: Return complete Action lines, or Final for this request. Stop after Action. Never generate Observation.';
assert.equal(from([realFirstStep]).tier, 1, '真实首步提示词：Control 尾巴被剥掉，问候判轻');
// 真实终审提示词（FinalAnswerReviewer.buildFinalReviewPrompt）：用另一个标记
// '原始问题：'，其后是证据段——不认识这个标记时整段兜底分类必判复杂。
const realFinalReview = 'Final review phase.\n你是结果综合器，只根据本轮证据完整回答原始问题。\n' +
  '先拆出每个问题，分别编号，先直接回答再解释；不要遗漏额外写作要求。\n' +
  '直接输出 Final: 完整答案，不输出检查过程或复核说明。\n原始问题：\n你好\n' +
  '本轮工具证据：\n工具：search；调用：r1；状态：success\n返回：\n晴，25 度\n';
assert.equal(from([realFinalReview]).tier, 1, '终审提示词：原始问题标记 + 证据段被剥掉');
assert.equal(from([realFinalReview.replace('你好', '证明勾股定理')]).tier, 2,
  '终审标记下的真实任务仍按内容定档');
// 多步请求：任务后面跟着上一轮的 Thought/Action/Observation 输出组
const multiStep = 'You are a ReAct agent.\nTools:\n- search: 搜索\nUser task:\n帮我查上海天气\n\n' +
  'Thought: 需要天气查询\nAction: search {"query": "上海天气"}\nObservation: 晴，25 度\n' +
  'Control: Current user request (answer only this; earlier history is context, not current evidence):\n帮我查上海天气';
assert.equal(from([multiStep]).tier, 1, '多步提示词：ReAct 输出组被剥掉，短问题仍轻');
// 证据审查阶段（buildPrompt 证据分支）：任务后面直接跟 'Call …' 证据条目
const evidenceStep = 'Tools for additional dependent work:\n- search\nUser task:\n你好\n\n' +
  'Call r1 tool=search status=success\nObservation: 晴，25 度\n';
assert.equal(from([evidenceStep]).tier, 1, '证据审查阶段：Call 证据段被剥掉');
// 历史里嵌着旧标记、当前用终审标记：取位置靠后的当前标记
const mixedMarkers = 'User task:\n旧问题\n原始问题：\n你好\n本轮工具证据：\n工具：search\n返回：\n结果\n';
assert.equal(from([mixedMarkers]).tier, 1, '混合标记取最后一个（当前任务）');
// 首行天然受保护：任务第一行没有前置换行，长得像脚手架前缀也不会被误切
assert.equal(from(['User task:\nAction: 帮我订机票']).tier, 1, '首行不被前缀误切');
assert.equal(classifyFromMessages([{ role: 'user', content: '你好' }], false).tier, 1);
assert.equal(classifyFromMessages([{ role: 'user', content: '快速排序算法' }], false).tier, 2);
assert.equal(classifyFromMessages([{ role: 'user', content: 'hi' }, { role: 'user', content: '你好' }], false).tier, 1);
// 历史不参与定档：旧问题/旧回答里的代码标记不许污染新问题（实测案例——
// 问过"生成Python快排代码"之后发"你好"被历史标记判成复杂档）
const poisoned = classifyFromMessages([
  { role: 'user', content: '生成Python快排代码' },
  { role: 'assistant', content: 'def quicksort(a):\n  if len(a) <= 1: return a\n  return quicksort([x for x in a[1:] if x < a[0]]) + [a[0]] + quicksort([x for x in a[1:] if x >= a[0]])' },
  { role: 'user', content: '你好' }], false);
assert.equal(poisoned.tier, 1, '旧问题的代码标记不给出新问题定档');
assert.equal(poisoned.reason, '轻量', '判轻而非代码生成: ' + poisoned.reason);
// 两轮历史（turns 旧逻辑会是 5）同样只看当前问题
const deeper = classifyFromMessages([
  { role: 'user', content: '生成Python快排代码' },
  { role: 'assistant', content: 'def quicksort(a): ...' },
  { role: 'user', content: '总结一下' },
  { role: 'assistant', content: '快速排序是分治算法，平均复杂度 O(n log n)。' },
  { role: 'user', content: '你好' }], false);
assert.equal(deeper.tier, 1, '深会话里的短问题仍判轻（turns 不再吃历史深度）');
// 反向：历史是闲聊，新问题是代码 → 仍判复杂
assert.equal(classifyFromMessages([
  { role: 'user', content: '你好' },
  { role: 'assistant', content: '你好！有什么可以帮你？' },
  { role: 'user', content: '生成Python快排代码' }], false).tier, 2);
// 无 user 消息的异常形状：回落整段拼接
assert.equal(classifyFromMessages([{ role: 'developer', content: 'User task:\n证明勾股定理' }], false).tier, 2);
console.log('PASS: task tier classification (light/default/heavy), scaffolding extraction, determinism, budget/text helpers');
