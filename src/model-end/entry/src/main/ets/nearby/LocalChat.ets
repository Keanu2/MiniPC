import probe from 'libgewu_probe.so';
import { fileIo } from '@kit.CoreFileKit';

export interface ChatMessage { role: string; content: string; }
export interface ChatUpdate { kind: 'delta' | 'done'; text: string; error?: string; finishReason?: string; }
interface ChatRequest { type: string; messages: ChatMessage[]; stream: boolean; max_tokens: number; }
interface NativeEvent { event: string; id?: string; payload: string; }
interface NativeResponse { message?: ChatMessage; finish_reason?: string | null; }

interface Job {
  requestId: string;
  nativeId: number;
  cancelled: boolean;
  answer: string;
  failure: string;
  finishReason: string;
  callback: ((update: ChatUpdate) => void) | undefined;
}

const MAX_JOBS = 2;

export class LocalChat {
  private filesDir: string;
  private timer: number = -1;
  private closed: boolean = false;
  private jobs: Job[] = [];

  constructor(filesDir: string) { this.filesDir = filesDir; }
  isBusy(): boolean { return this.jobs.length >= MAX_JOBS; }
  activeCount(): number { return this.jobs.length; }

  // Basic readiness only: leave GEWU initialization to the actual request.
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
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

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId: string = ''): string {
    if (this.closed) return '模型服务已关闭。';
    if (this.jobs.length >= MAX_JOBS) return '已有两路推理正在进行，请稍后再发。';
    if (messages.length === 0) return '请输入问题。';
    const request: ChatRequest = { type: 'qwen2', messages: messages, stream: true, max_tokens: 256 };
    let nativeId = 0;
    try {
      nativeId = probe.start(this.filesDir + '/models/Qwen2.5-7B-Instruct-Q4_N_0', JSON.stringify(request),
        this.filesDir + '/gewu-chat.jsonl');
    } catch (_) { return '无法启动模型，请确认模型文件已部署。'; }
    if (nativeId <= 0) return '已有两路推理正在进行，请稍后再发。';
    this.jobs.push({
      requestId: requestId, nativeId: nativeId, cancelled: false, answer: '', failure: '',
      finishReason: '', callback: callback
    });
    if (this.timer === -1) this.timer = setInterval(() => this.consumeEvents(), 80);
    return '';
  }

  cancel(requestId?: string): void {
    if (this.jobs.length === 0) return;
    if (requestId === undefined || requestId.length === 0) {
      for (const job of this.jobs) job.cancelled = true;
      probe.cancel();
      return;
    }
    const job = this.jobs.find((item: Job) => item.requestId === requestId);
    if (job === undefined) return;
    job.cancelled = true;
    probe.cancel(job.nativeId);
  }

  close(): void {
    this.closed = true;
    for (const job of this.jobs) job.callback = undefined;
    this.cancel();
    if (this.timer !== -1) clearInterval(this.timer);
    this.timer = -1;
  }

  private jobByNative(nativeId: number): Job | undefined {
    return this.jobs.find((item: Job) => item.nativeId === nativeId);
  }

  private consumeEvents(): void {
    for (const line of probe.takeEvents()) {
      if (this.closed) continue;
      let event: NativeEvent;
      try { event = JSON.parse(line) as NativeEvent; }
      catch (_) { continue; }
      if (!event || typeof event.event !== 'string') continue;
      const nativeId = event.id ? Number(event.id) : 0;
      if (nativeId <= 0) continue;
      const job = this.jobByNative(nativeId);
      if (job === undefined) continue;
      if (event.event === 'file_error') job.failure = '模型文件缺失或无法读取。';
      if ((event.event === 'create' || event.event === 'submit' || event.event === 'destroy') &&
        event.payload !== '0') job.failure = '模型请求失败（' + event.event + ': ' + event.payload + '），请重试。';
      if (event.event === 'abort') job.cancelled = true;
      if (event.event === 'response' && !job.cancelled && !job.failure) {
        let response: NativeResponse;
        try { response = JSON.parse(event.payload) as NativeResponse; }
        catch (_) { this.parseFailure(job); continue; }
        if (!response) { this.parseFailure(job); continue; }
        if (typeof response.message?.content === 'string' && response.message.content.length > 0) {
          job.answer += response.message.content;
          if (job.callback) job.callback({ kind: 'delta', text: response.message.content });
        }
        if (typeof response.finish_reason === 'string' && response.finish_reason.length > 0) {
          job.finishReason = response.finish_reason;
          probe.complete(job.nativeId);
        }
      }
      if (event.event === 'end') this.finish(job);
    }
  }

  private parseFailure(job: Job): void {
    job.failure = '模型回复解析失败，请重试。';
    probe.cancel(job.nativeId);
  }

  private finish(job: Job): void {
    if (this.jobs.indexOf(job) < 0) return;
    if (!job.failure && !job.cancelled && (!job.answer || !job.finishReason)) {
      job.failure = job.answer ? '模型回复意外中断，请重试。' : '模型没有返回内容，请重试。';
    }
    const update: ChatUpdate = {
      kind: 'done', text: job.failure || (job.cancelled ?
        (job.answer ? job.answer + '\n\n已停止生成' : '已停止生成') : job.answer),
      finishReason: job.cancelled ? 'cancelled' : job.finishReason
    };
    if (job.failure) update.error = job.failure;
    const callback = job.callback;
    job.callback = undefined;
    this.jobs.splice(this.jobs.indexOf(job), 1);
    if (this.jobs.length === 0 && this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (callback) callback(update);
  }
}
