/**
 * 推理通道抽象，对齐 modelshare：聊天只认传输接口。
 * 本机有模型走 LocalLlmTransport；否则走近场远端。
 */
import { ChatMessage, ChatUpdate, LocalChat } from './LocalChat';

export interface LlmTransport {
  readinessError(): string;
  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId?: string): string;
  cancel(requestId?: string): void;
}

export class LocalLlmTransport implements LlmTransport {
  private chat: LocalChat;
  constructor(chat: LocalChat) { this.chat = chat; }
  readinessError(): string { return this.chat.hasModel() ? '' : this.chat.readinessError(); }
  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, _requestId?: string): string {
    return this.chat.start(messages, callback);
  }
  cancel(_requestId?: string): void { this.chat.cancel(); }
}
