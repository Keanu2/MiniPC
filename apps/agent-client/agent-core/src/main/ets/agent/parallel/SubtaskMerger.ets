import { LocalModel } from '../../model/LocalModel';

export type OutcomeStatus = 'ok' | 'partial' | 'failed' | 'cancelled';

export interface SubtaskOutcome {
  id: string;
  title: string;
  /** Device that ran the sub-task's last request; empty when unknown. */
  device: string;
  status: OutcomeStatus;
  text: string;
}

export function outcomeComplete(outcome: SubtaskOutcome): boolean {
  return outcome.status === 'ok';
}

function statusLabel(outcome: SubtaskOutcome): string {
  return outcome.status === 'ok' ? '已完成' : (outcome.status === 'partial' ? '部分完成' : '未完成');
}

/** Section-per-sub-task fallback used when merging fails; never invents content. */
export function concatOutcomes(outcomes: SubtaskOutcome[]): string {
  return outcomes.map((outcome: SubtaskOutcome, index: number): string => {
    const heading = (index + 1).toString() + '. ' + outcome.title + (outcome.status === 'ok' ? '' : '（' + statusLabel(outcome) + '）');
    return heading + '\n' + (outcome.text.trim().length > 0 ? outcome.text.trim() : '该部分没有得到结果。');
  }).join('\n\n');
}

const MAX_SECTION_CHARS = 3000;

function bounded(text: string): string {
  const value = text.trim();
  return value.length <= MAX_SECTION_CHARS ? value : value.substring(0, MAX_SECTION_CHARS) + '…';
}

/** English label used only inside the merge prompt; the section format is parsed by the compute dashboard. */
function promptStatus(outcome: SubtaskOutcome): string {
  return outcome.status === 'ok' ? 'completed' : (outcome.status === 'partial' ? 'partial' : 'unfinished');
}

const MERGE_INSTRUCTIONS =
  '# Role\n' +
  'You merge the results of several independent parts of one user request into a single final answer.\n\n' +
  '## Output language\n' +
  '- Write the whole answer in Simplified Chinese.\n\n' +
  '## Rules\n' +
  '- Answer every part of the user request, in the order the user asked.\n' +
  '- Use only facts that appear in the results below. Never add data that is not there.\n' +
  '- A part marked unfinished or partial was NOT completed: tell the user plainly that this item is not done or only partly done. Never present it as an obtained result.\n' +
  '- Do not mention the words "subtask" or "part" in the answer.\n' +
  '- Output the answer text only, with no headings about the merge process.\n\n' +
  '## Example\n' +
  'Request: 查一下明天北京的天气，再查一下华为北京研究所在哪里\n' +
  'Results: item 1 (completed) 北京明天阴，11.6~24.4℃; item 2 (unfinished) 地图服务暂时不可用\n' +
  'Good answer:\n' +
  '明天北京阴，气温约 11.6℃ 到 24.4℃。\n' +
  '华为北京研究所的位置这次没有查到（地图服务暂时不可用），可以稍后再试。\n\n';

export function buildMergePrompt(task: string, outcomes: SubtaskOutcome[]): string {
  let sections = '';
  for (let index = 0; index < outcomes.length; index++) {
    const outcome = outcomes[index];
    sections += '### Subtask ' + (index + 1).toString() + ': ' + outcome.title + ' [' + promptStatus(outcome) + ']\n';
    sections += outcome.status === 'ok' ? bounded(outcome.text) :
      (outcome.status === 'partial' ? '(The following result is incomplete.)\n' + bounded(outcome.text) : 'This part could not be completed: ' + bounded(outcome.text));
    sections += '\n\n';
  }
  return MERGE_INSTRUCTIONS +
    '## User request\n' + task.trim() + '\n\n' +
    '## Subtask results\n\n' + sections.trim();
}

export async function mergeOutcomes(task: string, outcomes: SubtaskOutcome[], model: LocalModel): Promise<string> {
  const answer = (await model.complete(buildMergePrompt(task, outcomes))).trim();
  if (answer.length === 0) {
    throw new Error('合并没有返回内容');
  }
  return answer;
}
