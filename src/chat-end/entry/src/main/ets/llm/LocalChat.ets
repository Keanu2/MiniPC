import probe from 'libgewu_probe.so';
import { fileIo } from '@kit.CoreFileKit';

export interface ChatMessage { role: string; content: string; }
export interface ChatUpdate { kind: 'delta' | 'done'; text: string; error?: string; finishReason?: string; }
interface ChatRequest { type: string; messages: ChatMessage[]; stream: boolean; max_tokens: number; }
interface NativeEvent { event: string; payload: string; }
interface NativeResponse { message?: ChatMessage; finish_reason?: string | null; }

export class LocalChat {
  private filesDir: string;
  private timer: number = -1;
  private busy: boolean = false;
  private closed: boolean = false;
  private cancelled: boolean = false;
  private answer: string = '';
  private failure: string = '';
  private finishReason: string = '';
  private callback: ((update: ChatUpdate) => void) | undefined = undefined;

  constructor(filesDir: string) { this.filesDir = filesDir; }
  isBusy(): boolean { return this.busy; }
  hasModel(): boolean { return this.modelFileError() === ''; }

  // Basic readiness only: leave GEWU initialization to the actual request.
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    if (this.busy) return '上一条回复还未结束。';
    return this.modelFileError();
  }

  private modelFileError(): string {
    for (const name of ['api_config.json', 'params', 'tokenizer.json']) {
      try {
        const file = fileIo.openSync(this.filesDir + '/models/Qwen2.5-7B-Instruct-Q4_N_0/' + name,
          fileIo.OpenMode.READ_ONLY);
        try {
          if (fileIo.readSync(file.fd, new ArrayBuffer(1)) !== 1) return '模型文件为空：' + name;
        } finally {
          fileIo.closeSync(file);
        }
      } catch (_) { return '模型文件缺失或无法读取：' + name; }
    }
    return '';
  }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void): string {
    if (this.closed) return '模型服务已关闭。';
    if (this.busy) return '上一条回复还未结束。';
    if (messages.length === 0) return '请输入问题。';
    const request: ChatRequest = { type: 'qwen2', messages: messages, stream: true, max_tokens: 256 };
    try {
      if (!probe.start(this.filesDir + '/models/Qwen2.5-7B-Instruct-Q4_N_0', JSON.stringify(request),
        this.filesDir + '/gewu-chat.jsonl')) return '模型正在清理上一条请求，请稍后重试。';
    } catch (_) { return '无法启动模型，请确认模型文件已部署。'; }
    this.busy = true;
    this.cancelled = false;
    this.answer = '';
    this.failure = '';
    this.finishReason = '';
    this.callback = callback;
    this.timer = setInterval(() => this.consumeEvents(), 80);
    return '';
  }

  cancel(): void {
    if (!this.busy) return;
    this.cancelled = true;
    probe.cancel();
  }

  close(): void {
    this.closed = true;
    this.callback = undefined;
    this.cancel();
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
  }

  private consumeEvents(): void {
    for (const line of probe.takeEvents()) {
      if (!this.busy || this.closed) continue;
      let event: NativeEvent;
      try { event = JSON.parse(line) as NativeEvent; }
      catch (_) { this.parseFailure(); continue; }
      if (!event || typeof event.event !== 'string') { this.parseFailure(); continue; }
      if (event.event === 'file_error') this.failure = '模型文件缺失或无法读取。';
      if ((event.event === 'create' || event.event === 'submit' || event.event === 'destroy') &&
        event.payload !== '0') this.failure = '模型请求失败（' + event.event + ': ' + event.payload + '），请重试。';
      if (event.event === 'abort') this.cancelled = true;
      if (event.event === 'response' && !this.cancelled && !this.failure) {
        let response: NativeResponse;
        try { response = JSON.parse(event.payload) as NativeResponse; }
        catch (_) { this.parseFailure(); continue; }
        if (!response) { this.parseFailure(); continue; }
        if (typeof response.message?.content === 'string' && response.message.content.length > 0) {
          this.answer += response.message.content;
          if (this.callback) this.callback({ kind: 'delta', text: response.message.content });
        }
        if (typeof response.finish_reason === 'string' && response.finish_reason.length > 0) {
          this.finishReason = response.finish_reason;
          probe.complete();
        }
      }
      if (event.event === 'end') this.finish();
    }
  }

  private parseFailure(): void {
    this.failure = '模型回复解析失败，请重试。';
    probe.cancel();
  }

  private finish(): void {
    if (!this.failure && !this.cancelled && (!this.answer || !this.finishReason)) {
      this.failure = this.answer ? '模型回复意外中断，请重试。' : '模型没有返回内容，请重试。';
    }
    const update: ChatUpdate = {
      kind: 'done', text: this.failure || (this.cancelled ?
        (this.answer ? this.answer + '\n\n已停止生成' : '已停止生成') : this.answer),
      finishReason: this.cancelled ? 'cancelled' : this.finishReason
    };
    if (this.failure) update.error = this.failure;
    const callback = this.callback;
    this.callback = undefined;
    this.busy = false;
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
    if (callback) callback(update);
  }
}
