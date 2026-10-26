/** Short display text only. The original model input is kept separately. */
export function inferenceTaskText(prompt: string): string {
  let normalized = prompt.replace(/\r\n/g, '\n');
  const userTurn = normalized.lastIndexOf('[user]\n');
  const historyEndMarker = normalized.indexOf('之前的对话结束。\n') >= 0 ? '之前的对话结束。\n' : 'End of earlier conversation.\n';
  const historyEnd = normalized.indexOf(historyEndMarker);
  if (userTurn >= 0) normalized = normalized.substring(userTurn + 7);
  else if (historyEnd >= 0) normalized = normalized.substring(historyEnd + historyEndMarker.length);
  let text = '';
  const markers = ['User task:\n', '## User request\n', 'Original question:\n', '用户请求：\n', '原始问题：\n'];
  for (const marker of markers) {
    const at = normalized.indexOf(marker);
    if (at >= 0) { text = normalized.substring(at + marker.length); break; }
  }
  if (text.length > 0) {
    text = text.split(/\n(?:Call \S+ tool=|Control:|Action:|Observation:|Execution:|Plan:|Thought:|Rejected Final|Actual evidence:|Current evidence:|For:|## Subtask results|### Subtask|【子任务|Earlier conversation|之前的对话|请只输出|只输出)/)[0].trim();
  }
  return text;
}

export function inferenceSummary(prompt: string, label: string = ''): string {
  let text: string;
  if (label === '普通聊天') {
    // PlainChat sends the current question as-is, or after recent exchanges.
    // Do not feed ordinary user text through the Agent prompt parser.
    text = prompt.replace(/\r\n/g, '\n').trim();
    if (text.startsWith('用户：') && text.endsWith('\n助手：')) {
      const current = text.lastIndexOf('\n用户：');
      if (current >= 0) {
        text = text.substring(current + '\n用户：'.length, text.length - '\n助手：'.length).trim();
      }
    }
  } else {
    text = inferenceTaskText(prompt);
  }
  text = text.split('\n')[0].replace(/\s+/g, ' ').trim();
  if (text.length === 0) text = label === '任务拆分' ? '正在分析任务分工' : (label === '合并结果' ? '汇总子任务结果' : '推理请求');
  if (text.length > 80) text = text.substring(0, 80) + '…';
  return label.length > 0 && label !== '普通聊天' ? '【' + label + '】' + text : text;
}
