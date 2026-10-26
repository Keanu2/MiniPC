/**
 * 任务档位分类器：把请求意图与复杂度折算成强度档位 tier 1-2（1 简单、2 复杂）。
 * 纯规则、零 LLM 调用、确定性纯函数——hub 用它路由设备，执行端用同一函数选本机
 * 模型目录；消息与 maxOutputTokens 逐字转发，因此两侧输入一致、结果一致。
 *
 * 两档语义：简单（1）要过全关 L1-L3（短、净、浅），其余一律复杂（2）——
 * 复杂证据（原重档标记 H1-H5）与"够不上简单"的中间地带都落 2（fail open：
 * 不确定就按复杂处理，最坏是强模型答简单题，绝不反过来）。
 *
 * 输出预算不参与定档：线上唯一的预算来源是 agent 端的固定上限
 * min(2048, profile.maxOutputTokens)——常量说明不了任务性质，曾经把 path B
 * 的所有请求（包括"你好"）一律顶成复杂档。预算只约束执行侧的生成长度。
 *
 * 档位是质量偏好（fail open）：分错的最坏结果是次优选点/选目录，绝不失败。
 * 能力（needs/capabilities）才是正确性约束，由路由层 fail closed 把关。
 *
 * 本模块必须保持零 import、零 hilog：它要在无 require 的裸 vm 测试环境里加载
 * （先例：ComputeRouter / DevicePool）。
 */

export interface TaskMessage { role: string; content: string; }
export interface TaskSignals { text: string; turns: number; hasImage: boolean; }
export interface TaskProfile { tier: number; reason: string; }

/** 轻/重文本权重阈值：ASCII 记 1、其余记 2；≤160 视为短输入。 */
const SHORT_TEXT_WEIGHT: number = 160;
/** 长文生成类动词构成复杂档所需的最低权重。 */
const LONG_FORM_WEIGHT: number = 600;
/** agent 框架脚手架分隔标记（与 agent 端 PROMPT_TASK_MARKERS 对齐）：常规
 *  ReAct 步骤用 'User task:'，终审阶段（FinalAnswerReviewer）用 '原始问题：'。
 *  分类只看最后一个标记之后的真实任务文本。 */
const USER_TASK_MARKERS: string[] = ['User task:\n', '原始问题：\n'];
/** 标记之后会重新出现的脚手架行（行首锚定，即带前置换行）：ReAct 输出组
 *  （Thought/Action/Observation/Plan/Execution/Final/Rejected）、fitPrompt 的
 *  Control 尾巴与省略通知、证据段（本轮工具证据：/Call …）。任务本体到第一处
 *  为止；首行没有前置换行，天然不会被误切。 */
const TASK_END_PREFIXES: string[] = ['\nControl:', '\nThought:', '\nAction:', '\nObservation:',
  '\nPlan:', '\nExecution:', '\nFinal:', '\nRejected ', '\n本轮工具证据：', '\nCall '];

/** 强代码标记：单个命中即复杂（H2）。 */
const STRONG_CODE_MARKERS: string[] = ['写代码', '生成代码', '代码实现', '函数', '算法', '复杂度', '递归',
  '编程', '重构', '调试', '报错', 'Traceback', 'traceback', 'debug', 'Debug'];
/** 弱代码词：不同词命中 ≥2 个才复杂（H3）。 */
const WEAK_CODE_WORDS: string[] = ['import', 'return', 'def ', 'class ', 'var ', 'const ', 'python', 'java',
  'javascript', 'typescript', 'c++', 'sql', '正则', '脚本', '编译', '变量'];
/** 数学推理标记：单个命中即复杂（H4）。 */
const MATH_MARKERS: string[] = ['证明', '推导', '解方程', '方程', '微积分', '逻辑推理', '深入分析', '原因分析',
  '权衡', '方案设计', '架构设计', 'step by step', 'step-by-step', 'prove', 'proof', 'equation',
  'derivative', 'integral'];
/** 长文生成动词：命中且权重 ≥ LONG_FORM_WEIGHT 才复杂（H5）。 */
const LONG_FORM_VERBS: string[] = ['总结', '摘要', '概括', '提炼', '翻译', '改写', '润色', '扩写', '续写',
  'summarize', 'translate', 'rewrite', 'proofread', 'paraphrase'];
/** 生成类标记：只阻止简单档（L2），不构成复杂档。 */
const GENERATION_MARKERS: string[] = ['写', '生成', '创作', '编写', '起草', '作文', '故事', '诗', '邮件',
  '报告', '方案', 'write ', 'compose', 'generate', 'create ', 'draft'];
/** 生成意图动词：与代码名词共现即复杂（H2b）。短语级强代码词（"生成代码"）被定语
 *  隔开时匹配不到——"生成Python快排代码"即是实例，共现规则补上这个缺口。 */
const GEN_INTENT_VERBS: string[] = ['写', '生成', '编写', '实现', '创作', '起草',
  'write ', 'implement', 'generate', 'create '];
/** 代码名词：与生成意图动词共现即复杂（H2b）。 */
const CODE_NOUNS: string[] = ['代码', '函数', '程序', '脚本', '算法', '快排', '排序',
  'code', 'function', 'program', 'script', 'algorithm'];

/** 两侧共用的文本拼接：按 '\n' 连接全部消息内容。 */
export function taskTextOf(messages: TaskMessage[]): string {
  const parts: string[] = [];
  for (const message of messages) {
    parts.push(message.content);
  }
  return parts.join('\n');
}

/**
 * 分类主入口：所有调用方一律用它（而不是手工拼 TaskSignals），
 * 保证 hub 与执行端对同一请求算出同一档位。
 * 只看当前任务（最后一条 user 消息）：历史里的旧问题与旧回答不参与定档——
 * 否则问过一次代码问题后，连"你好"都会被历史标记判成复杂。
 */
export function classifyFromMessages(messages: TaskMessage[], hasImage: boolean): TaskProfile {
  const question = lastUserTextOf(messages);
  return classifyTask({ text: question, turns: 1, hasImage: hasImage });
}

/** 当前任务文本：最后一条 user 消息；没有 user 消息时回落整段拼接（防御异常形状）。 */
function lastUserTextOf(messages: TaskMessage[]): string {
  for (let index = messages.length - 1; index >= 0; index--) {
    if (messages[index].role === 'user') return messages[index].content;
  }
  return taskTextOf(messages);
}

export function classifyTask(signals: TaskSignals): TaskProfile {
  const text = effectiveTaskText(signals.text);
  const tier = signals.hasImage ? ',附图' : '';
  if (text.length === 0) return { tier: 2, reason: '空输入' + tier };
  const weight = weightedLength(text);
  // 复杂证据（H1-H5）既给出 reason，也先行否决简单档——代码围栏等证据不在
  // L2 的挡轻词表里，不先查会漏进 1 档。
  const heavy = heavyReasonOf(text, weight);
  if (heavy.length > 0) return { tier: 2, reason: heavy + tier };
  if (isLight(text, weight, signals)) return { tier: 1, reason: '轻量' + tier };
  return { tier: 2, reason: '常规' + tier };
}

/** 剥掉 agent 框架脚手架（同 inferQuestion 手法）：取最后一个任务标记之后的
 *  段落，再切掉标记后重新出现的脚手架行。只切尾巴不够——Control 尾巴会把任务
 *  复述一遍并带上 "Never generate Observation" 等协议文案，权重和 generate
 *  标记曾把"你好"顶成复杂档；多步请求的任务后面还跟着 Thought/Action/
 *  Observation 输出组，终审提示词后面跟着证据段。无标记 = path A 裸文本，
 *  整段参与分类且不切。 */
function effectiveTaskText(text: string): string {
  let at = -1;
  let markerLength = 0;
  for (const marker of USER_TASK_MARKERS) {
    const found = text.lastIndexOf(marker);
    if (found > at) { at = found; markerLength = marker.length; }
  }
  if (at < 0) return text;
  const section = text.substring(at + markerLength);
  let end = section.length;
  for (const prefix of TASK_END_PREFIXES) {
    const cut = section.indexOf(prefix);
    if (cut >= 0 && cut < end) end = cut;
  }
  return section.substring(0, end).trim();
}

/** ASCII 记 1、其余记 2 的加权长度；用索引循环（ArkTS 限制）。 */
function weightedLength(text: string): number {
  let weight = 0;
  for (let i = 0; i < text.length; i++) {
    weight += text.charCodeAt(i) < 128 ? 1 : 2;
  }
  return weight;
}

function firstMatch(text: string, markers: string[]): string {
  for (const marker of markers) {
    if (text.indexOf(marker) >= 0) return marker;
  }
  return '';
}

/** 弱代码词计数（不同词各计一次）：小写比对，Python/Java 等大写变体同样命中。 */
function countDistinct(text: string, words: string[]): number {
  const lower = text.toLowerCase();
  let count = 0;
  for (const word of words) {
    if (lower.indexOf(word) >= 0) count++;
  }
  return count;
}

/** H2b 证据串：生成意图动词与代码名词共现返回 "动词+名词"；空串 = 不构成复杂。 */
function codeGenerationPair(text: string): string {
  const verb = firstMatch(text, GEN_INTENT_VERBS);
  if (verb.length === 0) return '';
  const noun = firstMatch(text, CODE_NOUNS);
  return noun.length === 0 ? '' : verb + '+' + noun;
}

/** 复杂证据（H1-H5，按序检查）：返回触发原因，空串 = 无复杂证据。 */
function heavyReasonOf(text: string, weight: number): string {
  if (text.indexOf('```') >= 0) return '代码围栏';
  const strong = firstMatch(text, STRONG_CODE_MARKERS);
  if (strong.length > 0) return '强代码词:' + strong;
  const pair = codeGenerationPair(text);
  if (pair.length > 0) return '代码生成:' + pair;
  if (countDistinct(text, WEAK_CODE_WORDS) >= 2) return '弱代码词x2';
  const math = firstMatch(text, MATH_MARKERS);
  if (math.length > 0) return '数学推理:' + math;
  if (weight >= LONG_FORM_WEIGHT && firstMatch(text, LONG_FORM_VERBS).length > 0) return '长文生成';
  return '';
}

/** 简单判定（L1-L3，全部满足才算 1 档）。单个弱代码词不够复杂（H3 要 ≥2），但足够否决简单。 */
function isLight(text: string, weight: number, signals: TaskSignals): boolean {
  if (weight > SHORT_TEXT_WEIGHT) return false;
  if (firstMatch(text, STRONG_CODE_MARKERS).length > 0 ||
    firstMatch(text, MATH_MARKERS).length > 0 ||
    firstMatch(text, LONG_FORM_VERBS).length > 0 ||
    countDistinct(text, WEAK_CODE_WORDS) >= 1 ||
    firstMatch(text, GENERATION_MARKERS).length > 0) return false;
  if (signals.turns > 3) return false;
  return true;
}
