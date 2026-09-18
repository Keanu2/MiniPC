import { util } from '@kit.ArkTS';

export interface ChatMessage { role: string; content: string; }
export interface WireMessage {
  protocol?: string;
  type: string;
  requestId?: string;
  messages?: ChatMessage[];
  text?: string;
  finishReason?: string;
  error?: string;
  peerRole?: string;
}

const PROTOCOL = 'nearby-chat-v1';
const MAX_FRAME = 65536;

// Validate before forwarding anything to the model or UI.
export function validMessage(m: WireMessage): boolean {
  if (m === null || typeof m !== 'object' || m.protocol !== PROTOCOL || typeof m.type !== 'string') return false;
  if (['hello', 'hello_ack'].includes(m.type)) {
    return m.peerRole === undefined || m.peerRole === 'compute' || m.peerRole === 'chat';
  }
  if (typeof m.requestId !== 'string' || m.requestId.length === 0 || m.requestId.length > 128) return false;
  if (m.type === 'cancel' || m.type === 'prepare') return true;
  if (m.type === 'prepared') return m.error === undefined ||
    (typeof m.error === 'string' && m.error.length <= 2048);
  if (m.type === 'delta') return typeof m.text === 'string' && m.text.length <= 16000;
  if (m.type === 'done') return m.finishReason === undefined ||
    (typeof m.finishReason === 'string' && m.finishReason.length <= 128);
  if (m.type === 'error') return typeof m.error === 'string' && m.error.length <= 2048;
  if (m.type !== 'request' || !Array.isArray(m.messages) || m.messages.length === 0 || m.messages.length > 7) return false;
  let length = 0;
  for (const message of m.messages) {
    if (message === null || typeof message !== 'object' ||
      (message.role !== 'user' && message.role !== 'assistant') || typeof message.content !== 'string') return false;
    length += message.content.length;
  }
  return length <= 1800 && m.messages[m.messages.length - 1].role === 'user' &&
    m.messages[m.messages.length - 1].content.trim().length > 0;
}


const CHUNK_BYTES = 480;
const MAX_PARTS = Math.ceil(MAX_FRAME / CHUNK_BYTES);
const MAX_PENDING = 8;
const FRAGMENT_TIMEOUT = 15000;
interface Fragment { version: number; id: string; index: number; count: number; data: string; }
class PendingMessage {
  created: number = Date.now();
  count: number;
  bytes: number = 0;
  parts: Map<number, Uint8Array> = new Map();
  constructor(count: number) { this.count = count; }
}

function validId(id: string): boolean {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);
}

export function encodeMessage(message: WireMessage, id: string): string[] {
  if (!validId(id)) throw new Error('Invalid fragment ID');
  // Outgoing callers retain the original optional protocol convention.
  message.protocol = PROTOCOL;
  if (!validMessage(message)) throw new Error('Invalid chat message');
  const bytes = new util.TextEncoder().encodeInto(JSON.stringify(message));
  if (bytes.length > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
  const count = Math.ceil(bytes.length / CHUNK_BYTES);
  const output: string[] = [];
  for (let index = 0; index < count; index++) {
    const fragment: Fragment = { version: 1, id: id, index: index, count: count,
      data: new util.Base64Helper().encodeToStringSync(bytes.subarray(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES)) };
    output.push(JSON.stringify(fragment));
  }
  return output;
}

export class MessageAssembler {
  private pending: Map<string, PendingMessage> = new Map();
  // Session-local replay window; clear on disconnect. No timers apply to inference.
  private completed: string[] = [];

  clear(): void { this.pending.clear(); this.completed = []; }

  checkExpiry(): void {
    for (const entry of this.pending) {
      if (Date.now() - entry[1].created >= FRAGMENT_TIMEOUT) {
        this.clear();
        throw new Error('Incomplete chat fragments timed out');
      }
    }
  }

  receive(text: string): WireMessage | null {
    this.checkExpiry();
    if (typeof text !== 'string' || text.length >= 1024 ||
      new util.TextEncoder().encodeInto(text).length >= 1024) throw new Error('Fragment exceeds limit');
    const fragment = JSON.parse(text) as Fragment;
    if (fragment === null || typeof fragment !== 'object' || fragment.version !== 1 || !validId(fragment.id) ||
      !Number.isInteger(fragment.count) || fragment.count < 1 || fragment.count > MAX_PARTS ||
      !Number.isInteger(fragment.index) || fragment.index < 0 || fragment.index >= fragment.count ||
      typeof fragment.data !== 'string' || fragment.data.length === 0 || fragment.data.length > 640 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(fragment.data)) {
      throw new Error('Malformed chat fragment');
    }
    const bytes = new util.Base64Helper().decodeSync(fragment.data);
    if (new util.Base64Helper().encodeToStringSync(bytes) !== fragment.data ||
      bytes.length === 0 || bytes.length > CHUNK_BYTES ||
      (fragment.index < fragment.count - 1 && bytes.length !== CHUNK_BYTES) ||
      (fragment.count - 1) * CHUNK_BYTES + (fragment.index === fragment.count - 1 ? bytes.length : 1) > MAX_FRAME) {
      throw new Error('Invalid fragment payload');
    }
    if (this.completed.includes(fragment.id)) return null;
    let pending = this.pending.get(fragment.id);
    if (pending === undefined) {
      if (this.pending.size >= MAX_PENDING) throw new Error('Too many incomplete chat messages');
      pending = new PendingMessage(fragment.count);
      this.pending.set(fragment.id, pending);
    }
    if (pending.count !== fragment.count) throw new Error('Conflicting fragment count');
    const previous = pending.parts.get(fragment.index);
    if (previous !== undefined) {
      if (new util.Base64Helper().encodeToStringSync(previous) !== fragment.data) throw new Error('Conflicting duplicate fragment');
      return null;
    }
    pending.parts.set(fragment.index, bytes);
    pending.bytes += bytes.length;
    if (pending.bytes > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
    if (pending.parts.size !== pending.count) return null;
    const joined = new Uint8Array(pending.bytes);
    for (let index = 0; index < pending.count; index++) {
      const part = pending.parts.get(index);
      if (part === undefined) throw new Error('Missing chat fragment');
      joined.set(part, index * CHUNK_BYTES);
    }
    const decoded = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(joined);
    const message = JSON.parse(decoded) as WireMessage;
    if (!validMessage(message)) throw new Error('Invalid chat message');
    this.pending.delete(fragment.id);
    this.completed.push(fragment.id);
    if (this.completed.length > 128) this.completed.shift();
    return message;
  }
}
