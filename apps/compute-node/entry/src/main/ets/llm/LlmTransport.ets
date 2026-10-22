/**
 * 推理通道抽象，对齐 modelshare chat/LlmTransport：
 * 上层只依赖本接口，不感知推理发生在本机还是远端。
 */
import { ChatBackend, ChatMessage, ChatUpdate } from './LocalChat';

export interface LlmTransport {
  readinessError(): string;
  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId?: string, image?: string): string;
  cancel(requestId?: string): void;
}

export class LocalLlmTransport implements LlmTransport {
  private chat: ChatBackend;
  constructor(chat: ChatBackend) { this.chat = chat; }
  readinessError(): string { return this.chat.readinessError(); }
  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId?: string, image?: string): string {
    return this.chat.start(messages, callback, requestId || '', { image: image || '' });
  }
  cancel(requestId?: string): void { this.chat.cancel(requestId); }
}
