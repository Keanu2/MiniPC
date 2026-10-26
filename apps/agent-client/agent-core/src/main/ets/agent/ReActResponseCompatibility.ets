const FINAL_PREFIXES: string[] = [
  'Final:',
  'Final Answer:',
  'Answer:',
  '最终答案:',
  '最终答案：',
  '答案:',
  '答案：'
];

const CONTROL_PREFIXES: string[] = [
  'Thought:',
  'Execution:',
  'Action:',
  'Action Input:',
  'Observation:'
];

const BARE_FINAL_MARKERS: string[] = ['final', 'final answer', 'answer', '最终答案', '答案'];

// 弱模型常把提示词里的指令句原样抄进 Final 行。这些是我们自己的固定文案片段：
// 抄出来的"答案"是指令填充文本，绝不能当答案展示。宁可拒收进重试/诚实失败。
const INSTRUCTION_ECHO_SIGNATURES: string[] = [
  '<complete answer>',
  'answer, or Execution',
  '不输出检查过程',
  '完整回答 for this request',
  '完整答案，不输出'
];
const ECHO_EXACT_VALUES: string[] = ['完整回答', '整回答', '完整答案'];

export function isInstructionEchoAnswer(answer: string): boolean {
  const probes: string[] = [answer];
  // GEWU 首字乱码：剥掉前导 U+FFFD 再比对一次（"□□整回答"→"整回答"）。
  const stripped = answer.replace(/^�+/, '');
  if (stripped !== answer) { probes.push(stripped); }
  for (const probe of probes) {
    if (ECHO_EXACT_VALUES.indexOf(probe) >= 0) { return true; }
    for (const signature of INSTRUCTION_ECHO_SIGNATURES) {
      if (probe.indexOf(signature) >= 0) { return true; }
    }
  }
  return false;
}

function isBareFinalMarker(value: string): boolean {
  return BARE_FINAL_MARKERS.indexOf(value.toLowerCase()) >= 0;
}

/**
 * Qwen-style replies often open with a bare "Final" line (no colon) before the
 * answer text. Drop those leading marker lines so the marker never reaches the
 * displayed answer or conversation history.
 */
export function stripLeadingFinalMarker(content: string): string {
  const lines = content.split(/\r?\n/);
  let index = 0;
  while (index < lines.length) {
    const normalized = normalizeProtocolLine(lines[index]);
    if (normalized.length === 0) { index++; continue; }
    if (!isBareFinalMarker(normalized)) { break; }
    index++;
  }
  return lines.slice(index).join('\n').trim();
}

function normalizeProtocolLine(line: string): string {
  let value = line.trim();
  while (value.startsWith('#')) {
    value = value.substring(1).trim();
  }
  value = value.replace(/\*\*/g, '');
  // GEWU 首块拆分可能损坏标记括号内的字节（FFFD），按结构折叠而不是逐字匹配。
  return value.replace(/^Final\s+Answer\s*\([^)]{0,32}\)\s*[::]/i, 'Final Answer:');
}

function startsWithIgnoreCase(value: string, prefix: string): boolean {
  return value.toLowerCase().startsWith(prefix.toLowerCase());
}

function matchingPrefix(value: string, prefixes: string[]): string | null {
  for (const prefix of prefixes) {
    if (startsWithIgnoreCase(value, prefix)) {
      return prefix;
    }
  }
  return null;
}

function isControlLine(value: string): boolean {
  return matchingPrefix(value, CONTROL_PREFIXES) !== null ||
    matchingPrefix(value, FINAL_PREFIXES) !== null;
}

/**
 * Accept the final-answer labels commonly emitted by Qwen and other chat models.
 */
export function extractCompatibleFinalAnswer(response: string): string | null {
  const lines = response.split(/\r?\n/);
  for (let index = 0; index < lines.length; index++) {
    const normalized = normalizeProtocolLine(lines[index]);
    const prefix = matchingPrefix(normalized, FINAL_PREFIXES);
    if (prefix === null) {
      continue;
    }

    const answerLines: string[] = [];
    const inlineValue = normalized.substring(prefix.length).trim();
    if (matchingPrefix(inlineValue, CONTROL_PREFIXES) !== null) {
      return null;
    }
    if (inlineValue.length > 0) {
      answerLines.push(inlineValue);
    }
    for (let tailIndex = index + 1; tailIndex < lines.length; tailIndex++) {
      const tail = normalizeProtocolLine(lines[tailIndex]);
      if (tail.length > 0 && isControlLine(tail)) {
        break;
      }
      if (tail.length > 0 && tail !== '```') {
        answerLines.push(tail);
      }
    }
    const answer = answerLines.join('\n').trim();
    return answer.length > 0 ? answer : null;
  }
  return null;
}

/**
 * Treat untagged natural-language output as a final chat answer. Responses that
 * still contain an Action are deliberately excluded so tool calls are never
 * mistaken for user-visible text.
 */
export function extractCompatiblePlainAnswer(response: string): string | null {
  const taggedFinal = extractCompatibleFinalAnswer(response);
  if (taggedFinal !== null) {
    return taggedFinal;
  }

  const lines = response.split(/\r?\n/);
  const answerLines: string[] = [];
  for (const line of lines) {
    const normalized = normalizeProtocolLine(line);
    if (normalized.length === 0 || normalized === '```') {
      continue;
    }
    if (startsWithIgnoreCase(normalized, 'Action:') ||
      startsWithIgnoreCase(normalized, 'Action Input:')) {
      return null;
    }
    if (matchingPrefix(normalized, CONTROL_PREFIXES) !== null) {
      continue;
    }
    // A leading bare marker line ("Final" without colon) labels the answer; it
    // is not content. A marker-only response stays empty and is rejected.
    if (answerLines.length === 0 && isBareFinalMarker(normalized)) {
      continue;
    }
    answerLines.push(normalized);
  }

  const answer = answerLines.join('\n').trim();
  return answer.length > 0 ? answer : null;
}
