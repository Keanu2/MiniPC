import { utf8Bytes } from './InferenceWire';

/** Each ordinary chat request contains only the current message and attachment. */
export function buildPlainChatPrompt(task: string, maxBytes: number): string {
  if (utf8Bytes(task).length > maxBytes) {
    throw new Error('本轮消息或附件超过输入限制，请缩小内容后重试');
  }
  return task;
}
