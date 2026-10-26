import { LocalModel } from '../../model/LocalModel';

export interface Subtask { id: string; title: string; task: string; }

const MIN_SUBTASKS = 2;
const MAX_SUBTASKS = 4;
const MAX_TASK_CHARS = 500;
const MAX_TITLE_CHARS = 20;
const MAX_CONTEXT_CHARS = 1500;

// Cheap signals that a request bundles several jobs. Without one, splitting would only add two inferences.
const BUNDLE_SIGNAL = /分别|并且|同时|另外|还有|以及|顺便|；|;|然后再|再帮|再查|再算|再写|再翻译|\balso\b|\bas well\b|\band then\b/i;
const NUMBERED_ITEM = /(?:^|\n)\s*(?:\d{1,2}[.、)）]|[①②③④⑤]|[-*•]\s)/g;
// A sub-task that leans on another one cannot run in parallel.
const DEPENDENCY_WORDS = /上一步|上一个任务|上述|以上结果|前一个任务|根据(?:子)?任务|第[一二三四1234]个(?:子)?任务|子任务\s*\d|结果(?:再|来)/;

/** Rule screen run before any model call: true when the request looks like several independent jobs. */
export function shouldTrySplit(task: string): boolean {
  const text = task.trim();
  if (text.length < 12) {
    return false;
  }
  const questions = text.match(/[？?]/g);
  if (questions !== null && questions.length >= 2) {
    return true;
  }
  const items = text.match(NUMBERED_ITEM);
  if (items !== null && items.length >= 2) {
    return true;
  }
  return BUNDLE_SIGNAL.test(text);
}

function clip(text: string, max: number): string {
  const value = text.trim();
  return value.length <= max ? value : value.substring(0, max);
}

const SPLIT_INSTRUCTIONS =
  '# Role\n' +
  'You split one user request into independent subtasks that can run at the same time.\n\n' +
  '## Output language\n' +
  '- The "title" and "task" values must be written in Simplified Chinese.\n\n' +
  '## Rules\n' +
  '1. Every subtask must be one complete, self-contained sentence. Replace references such as "this", "that", "above", "it" with the concrete content.\n' +
  '2. Subtasks must not depend on each other or refer to another subtask result. A part that needs information another part looks up (advice based on the weather, a choice based on a search result) belongs in the same subtask as that lookup; never split it out.\n' +
  '3. If the request contains only one thing, or the parts depend on each other in order, output [].\n' +
  '4. At most ' + MAX_SUBTASKS.toString() + ' subtasks. Do not omit anything the user asked for and do not add anything the user did not ask for.\n\n' +
  '## Output format\n' +
  'Output exactly one JSON array and nothing else: [{"title":"short title","task":"complete subtask"}]\n\n' +
  '## Examples\n' +
  'Request: 查一下明天北京的天气，再查一下华为北京研究所在哪里\n' +
  'Output: [{"title":"北京天气","task":"查询明天北京的天气情况"},{"title":"研究所位置","task":"查询华为北京研究所的具体位置"}]\n\n' +
  'Request: 查一下上海周末的天气适合穿什么，再查一下故宫的开放时间\n' +
  'Output: [{"title":"上海天气与穿衣","task":"查询上海周末的天气，并根据天气建议穿什么"},{"title":"故宫开放时间","task":"查询故宫的开放时间"}]\n\n' +
  'Request: 先查明天深圳到北京的高铁，再根据到达时间推荐酒店\n' +
  'Output: []\n\n' +
  'Request: 你好\n' +
  'Output: []\n\n';

export function buildSplitPrompt(task: string, context: string): string {
  return SPLIT_INSTRUCTIONS +
    (context.length > 0 ? '## Recent conversation (only for resolving references)\n' + clip(context, MAX_CONTEXT_CHARS) + '\n\n' : '') +
    '## User request\n' + task.trim();
}

/** Strict parse: anything doubtful returns null so the caller keeps the single-device path. */
export function parseSubtasks(response: string, original: string): Subtask[] | null {
  const start = response.indexOf('[');
  const end = response.lastIndexOf(']');
  if (start < 0 || end <= start) {
    return null;
  }
  let parsed: object;
  try {
    parsed = JSON.parse(response.substring(start, end + 1)) as object;
  } catch (_error) {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length < MIN_SUBTASKS || parsed.length > MAX_SUBTASKS) {
    return null;
  }
  const result: Subtask[] = [];
  const seen: string[] = [];
  for (let index = 0; index < parsed.length; index++) {
    const item = parsed[index] as Record<string, Object>;
    if (item === null || typeof item !== 'object' || typeof item['task'] !== 'string') {
      return null;
    }
    const task = (item['task'] as string).trim();
    if (task.length === 0 || task.length > MAX_TASK_CHARS || task === original.trim() ||
      DEPENDENCY_WORDS.test(task) || seen.indexOf(task) >= 0) {
      return null;
    }
    seen.push(task);
    const rawTitle = typeof item['title'] === 'string' ? (item['title'] as string).trim() : '';
    result.push({ id: 's' + (index + 1).toString(),
      title: clip(rawTitle.length > 0 ? rawTitle : '子任务' + (index + 1).toString(), MAX_TITLE_CHARS), task: task });
  }
  return result;
}

/** One model call. Returns null when the request should not be split (or the call failed). */
export async function splitTask(task: string, context: string, model: LocalModel): Promise<Subtask[] | null> {
  const response = await model.complete(buildSplitPrompt(task, context));
  return parseSubtasks(response, task);
}
