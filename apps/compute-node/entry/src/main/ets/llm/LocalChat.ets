import probe from 'libgewu_probe.so';
import { modelRequestType, readyModelDirs, selectModelDir } from './ModelRegistry';

export interface ChatMessage { role: string; content: string; }
export interface ChatUpdate {
  kind: 'delta' | 'done';
  text: string;
  error?: string;
  finishReason?: string;
  /** 上游 Outcome 细分：后端失败时标注 'overflow'（撞输出上限）/'unavailable'，缺省按 unavailable 处理。 */
  failureKind?: string;
}
/** 多模态消息分片：图片（image_url 为 data URL）或文本。 */
interface MessagePart { type: string; text?: string; image_url?: string }
/** 推理请求的消息：纯文本 content 为字符串；带图时最后一条 user 消息为分片数组。 */
interface RequestMessage { role: string; content: string | MessagePart[] }
interface ChatRequest { type: string; messages: RequestMessage[]; stream: boolean; max_tokens: number; }
export interface ChatStartOptions { maxTokens?: number; waitSeconds?: number; image?: string; }
/** 推理后端公共面：InferenceHost 等上层只依赖本接口，不感知本地 GEWU 还是云端 API。 */
export interface ChatBackend {
  isBusy(): boolean;
  activeCount(): number;
  readinessError(): string;
  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void,
    requestId: string, options: ChatStartOptions): string;
  cancel(requestId?: string): void;
  close(): void;
}
const MAX_TOKENS = 2048;
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

export class LocalChat implements ChatBackend {
  private filesDir: string;
  private timer: number = -1;
  private closed: boolean = false;
  private jobs: Job[] = [];

  constructor(filesDir: string) { this.filesDir = filesDir; }
  isBusy(): boolean { return this.jobs.length > 0; }
  activeCount(): number { return this.jobs.length; }

  // Basic readiness only: leave GEWU initialization to the actual request.
  // 任意一个就绪模型即视为可用；具体目录在请求时按需求选择。
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    return readyModelDirs(this.filesDir).length > 0 ? '' : '模型文件缺失或无法读取。';
  }

  /**
   * 带图请求把最后一条 user 消息编码为多模态分片（图片在前、文本在后，对齐
   * Qwen-VL 惯例）；请求类型跟随所选模型 api_config 的声明。
   *
   * stream 固定为 false：流式回调会把跨块的字符切成 U+FFFD，一次完整响应才能
   * 让这些字节留在同一个块里被正确解码。
   */
  private buildRequest(messages: ChatMessage[], image: string, type: string, maxTokens: number): ChatRequest {
    const out: RequestMessage[] = [];
    for (let index = 0; index < messages.length; index++) {
      const message = messages[index];
      if (image.length > 0 && index === messages.length - 1 && message.role === 'user') {
        const parts: MessagePart[] = [
          { type: 'image_url', image_url: 'data:image/jpeg;base64,' + image },
          { type: 'text', text: message.content }
        ];
        out.push({ role: message.role, content: parts });
      } else {
        out.push({ role: message.role, content: message.content });
      }
    }
    return { type: type, messages: out, stream: false, max_tokens: maxTokens };
  }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId: string = '',
    options: ChatStartOptions = {}): string {
    if (this.closed) return '模型服务已关闭。';
    if (messages.length === 0) return '请输入问题。';
    const image: string = options.image === undefined ? '' : options.image;
    const maxTokens = Number.isInteger(options.maxTokens) && (options.maxTokens as number) > 0 ?
      Math.min(MAX_TOKENS, options.maxTokens as number) : MAX_TOKENS;
    const waitSeconds = Number.isInteger(options.waitSeconds) && (options.waitSeconds as number) > 0 ?
      options.waitSeconds as number : 0;
    // 图片即 vision 需求：选不出覆盖该需求的模型目录时 fail closed，绝不送给纯文本模型。
    const needs: string[] = image.length > 0 ? ['vision'] : [];
    const modelDir = selectModelDir(this.filesDir, needs);
    if (modelDir.length === 0) {
      return image.length > 0 ? '本地模型不支持图片理解。' : '模型文件缺失或无法读取。';
    }
    const request = this.buildRequest(messages, image, modelRequestType(this.filesDir, modelDir), maxTokens);
    let nativeId = 0;
    try {
      nativeId = probe.start(this.filesDir + '/models/' + modelDir, JSON.stringify(request),
        this.filesDir + '/gewu-chat.jsonl', waitSeconds);
    } catch (_) { return '无法启动模型，请确认模型文件已部署。'; }
    if (nativeId <= 0) return '模型繁忙，请稍后再发。';
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
        } else if (job.answer.length > 0) {
          // stream:false has exactly one response; native already treats it as terminal.
          job.finishReason = 'stop';
        }
      }
      if (event.event === 'end') {
        if (event.payload === 'stalled' && job.answer.length === 0 && job.failure.length === 0) {
          job.failure = '算力端没有在时限内返回，请再试一次。';
        }
        this.finish(job);
      }
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
