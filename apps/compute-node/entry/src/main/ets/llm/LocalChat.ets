import { hilog } from '@kit.PerformanceAnalysisKit';
import probe from 'libgewu_probe.so';
import { fileIo } from '@kit.CoreFileKit';
import { SessionPlan, SessionReuse } from './SessionReuse';
import { manifestTier, modelRequestType, selectModelDir } from './ModelRegistry';
import { classifyFromMessages, taskTextOf } from '../cluster/TaskRules';
import { sanitizeModelOutput } from './Utf8Repair';
import { InferenceMetrics } from '../protocol/ChatProtocol';
import { outputSettings } from './OutputSettings';

/**
 * 本地文本推理（GEWU probe）。档位感知选模：与 hub 侧同规则重算任务档位（消息
 * 逐字转发，两侧结果一致），用它在就绪目录里按贴近选强/弱模型；
 * 选出的目录档位低于任务档位时记 local tier fallback 日志（降档可观测）。
 * VL 通道（VlLlmTransport/QwenVlManager）v1 不感知档位——带图路径由 vision 需求
 * 独占，不在本类的选型范围内。
 *
 * 旧 GEWU 版本可能在内部替换跨块字符（见 Utf8Repair.sanitizeModelOutput），
 * 本类保留兼容清洗：响应内容在进入 answer/回调之前统一处理——本机 UI、
 * 任务卡与 wire 下游拿到的都是同一份净化文本，幂等保证下游二次清洗安全。
 */

export interface ChatMessage { role: string; content: string; }
export interface ChatUpdate {
  kind: 'delta' | 'done'; text: string; error?: string; finishReason?: string; metrics?: InferenceMetrics;
  /** Local-only time reconstructed from native monotonic duration; never put on the wire. */
  outputAt?: number;
}
/** 多模态消息分片：图片（image_url 为 data URL）或文本。 */
interface MessagePart { type: string; text?: string; image_url?: string }
/** 推理请求的消息：纯文本 content 为字符串；带图时最后一条 user 消息为分片数组。 */
interface RequestMessage { role: string; content: string | MessagePart[] }
interface ChatRequest { type: string; messages: RequestMessage[]; stream: boolean; max_tokens: number; }
export interface ChatStartOptions { maxTokens?: number; waitSeconds?: number; image?: string; stream?: boolean; }
const MAX_TOKENS = 2048;
interface NativeEvent { event: string; id?: string; payload: string; elapsedMs?: number; }
interface NativeUsage {
  model_load_latency?: number; prefill_latency?: number; decode_latency?: number;
  prompt_tokens?: number; completion_tokens?: number;
}
interface NativeResponse { message?: ChatMessage; finish_reason?: string | null; usage?: NativeUsage; }

function reportedNumber(value: number | undefined, integer: boolean = false): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 &&
    (!integer || Number.isSafeInteger(value)) ? value : undefined;
}

function stallSeconds(payload: string, prefix: string): string {
  if (payload.length <= prefix.length || payload.charAt(prefix.length) !== ':') return '';
  const raw = payload.substring(prefix.length + 1);
  const value = Number(raw);
  return Number.isInteger(value) && value > 0 ? String(value) : '';
}

const GARBAGE_PREFIX_CHARS = 24;
const LOOP_SPAN_CHARS = 160;
const LOOP_MAX_UNIT = 48;
const LOOP_MIN_REPEATS = 4;
const DEGENERATE_FAILURE = '模型输出异常（重复或无意义字符），已自动停止。请重试或切换模型。';
const ENGINE_ABORT_FAILURE = '模型推理被引擎中断，回答不完整，请重试。';

/**
 * Broken weights or NaN logits make GEWU decode token 0 ("!") forever, and greedy decoding can
 * lock into a verbatim loop. Neither ever reaches EOS, so they would stream until the 600 s cap.
 */
export function degenerateOutput(text: string): boolean {
  const head = text.trimStart();
  if (head.length >= GARBAGE_PREFIX_CHARS && '-=*_#~`.'.indexOf(head.charAt(0)) < 0) {
    let same = true;
    for (let index = 1; index < GARBAGE_PREFIX_CHARS && same; index++) same = head.charAt(index) === head.charAt(0);
    if (same) return true;
  }
  for (let unit = 1; unit <= LOOP_MAX_UNIT; unit++) {
    if (text.length < unit * LOOP_MIN_REPEATS) break;
    const tail = text.substring(text.length - unit);
    if (tail.trim().length === 0) continue;
    let repeats = 1;
    let pos = text.length - unit;
    while (pos >= unit && repeats * unit < LOOP_SPAN_CHARS && text.substring(pos - unit, pos) === tail) {
      repeats++;
      pos -= unit;
    }
    if (repeats >= LOOP_MIN_REPEATS && repeats * unit >= LOOP_SPAN_CHARS) return true;
  }
  return false;
}

/** Hide Qwen3-style <think>...</think> reasoning, including an unclosed block and a split opening tag. */
export function stripThink(text: string): string {
  let out = '';
  let rest = text;
  for (;;) {
    const open = rest.indexOf('<think>');
    if (open < 0) {
      for (let keep = Math.min(6, rest.length); keep > 0; keep--) {
        if ('<think>'.startsWith(rest.substring(rest.length - keep))) return out + rest.substring(0, rest.length - keep);
      }
      return out + rest;
    }
    out += rest.substring(0, open);
    const close = rest.indexOf('</think>', open);
    if (close < 0) return out;
    rest = rest.substring(close + 8).replace(/^\n+/, '');
  }
}

/** Map native end payloads to the failure the user should see. Empty means success path. */
function endFailure(payload: string, hasAnswer: boolean, hasFinish: boolean): string {
  if (payload.indexOf('stalled_idle') === 0) {
    const seconds = stallSeconds(payload, 'stalled_idle');
    return hasAnswer ?
      (seconds ? '模型已超过' + seconds + '秒没有继续输出，已停止。' : '模型已较长时间没有继续输出，已停止。') :
      (seconds ? '超过' + seconds + '秒没有输出，已停止。' : '超过时限没有输出，已停止。');
  }
  if (payload.indexOf('stalled_limit') === 0 || payload === 'stalled') {
    const seconds = stallSeconds(payload, 'stalled_limit');
    return hasAnswer ?
      (seconds ? '生成已达' + seconds + '秒上限仍未结束，已停止。' : '生成已达时限仍未结束，已停止。') :
      (seconds ? '超过' + seconds + '秒仍未开始输出，已停止。' : '超过时限仍未开始输出，已停止。');
  }
  if (!hasAnswer) return '模型没有返回内容，请重试。';
  if (!hasFinish) return '模型会话已结束，但没有收到结束标记。';
  return '';
}

interface Job {
  requestId: string;
  nativeId: number;
  cancelled: boolean;
  answer: string;
  /** Model text before <think> blocks are removed. */
  raw: string;
  failure: string;
  finishReason: string;
  delivered: boolean;
  nativeStartedAt: number;
  metrics: InferenceMetrics;
  /** 请求原文（taskTextOf 拼接）：sanitizeModelOutput 的修复锚点来源。 */
  promptSource: string;
  callback: ((update: ChatUpdate) => void) | undefined;
  plan: SessionPlan | undefined;
}

export class LocalChat {
  private filesDir: string;
  private timer: number = -1;
  private closed: boolean = false;
  private jobs: Job[] = [];
  private reuse: SessionReuse = new SessionReuse((key: string): void => {
    try { probe.closeSession(key); } catch (_) { /* older native library: nothing cached */ }
  });

  constructor(filesDir: string) { this.filesDir = filesDir; }
  isBusy(): boolean { return this.activeCount() > 0; }

  /**
   * Session reuse is off unless <filesDir>/session-reuse.on exists, so the default path is
   * the original one-session-per-request behaviour.
   */
  private reuseEnabled(): boolean {
    try { return fileIo.accessSync(this.filesDir + '/session-reuse.on'); } catch (_) { return false; }
  }
  activeCount(): number { return this.jobs.filter((job: Job): boolean => !job.delivered).length; }

  /** Native cleanup still owns model memory after the answer has been delivered. */
  hasPendingNativeJobs(): boolean { return this.jobs.length > 0; }

  /** Switching is allowed only after native cleanup, including cached GEWU sessions. */
  resetIdleSessions(): void { this.reuse.closeAll(); }

  // Basic readiness only: leave GEWU initialization to the actual request.
  // 所选文字引擎必须就绪；VL 权重不能作为文字引擎使用。
  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    return selectModelDir(this.filesDir, []).length > 0 ? '' : '没有可用的文字模型，请检查模型选择和部署文件。';
  }

  /**
   * 带图请求把最后一条 user 消息编码为多模态分片（图片在前、文本在后，对齐
   * Qwen-VL 惯例）；请求类型跟随所选模型 api_config 的声明。
   *
   * 默认流式；非流式调用可显式关闭。UTF-8 跨块字节由原生桥接保留，历史引擎
   * 已丢失的替换字符继续由出口清洗兜底。是否结束取决于请求模式和结束标记。
   */
  private buildRequest(messages: ChatMessage[], image: string, type: string, maxTokens: number, stream: boolean): ChatRequest {
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
    return { type: type, messages: out, stream: stream, max_tokens: maxTokens };
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
    // 档位感知选模：与 hub 侧同规则重算（消息逐字转发，两侧结果一致）。
    const profile = classifyFromMessages(messages, image.length > 0);
    const modelDir = selectModelDir(this.filesDir, needs, profile.tier);
    if (modelDir.length === 0) {
      return image.length > 0 ? '本地模型不支持图片理解。' : '模型文件缺失或无法读取。';
    }
    const dirTier = manifestTier(this.filesDir, modelDir);
    if (dirTier < profile.tier) {
      hilog.info(0, 'NearbyChat', 'local tier fallback task=%{public}d dir=%{public}d model=%{public}s',
        profile.tier, dirTier, modelDir);
    }
    // A cached native session belongs to a specific model directory.
    const plan: SessionPlan | undefined = this.reuseEnabled() && image.length === 0 ?
      this.reuse.plan(messages, modelDir) : undefined;
    const sent = plan !== undefined ? plan.messages : messages;
    const streaming = options.stream === undefined ? outputSettings(this.filesDir).streaming : options.stream;
    const request = this.buildRequest(sent, image, modelRequestType(this.filesDir, modelDir), maxTokens, streaming);
    let nativeId = 0;
    const nativeStartedAt = Date.now();
    try {
      if (plan !== undefined && plan.key.length > 0) {
        nativeId = probe.start(this.filesDir + '/models/' + modelDir, JSON.stringify(request),
          this.filesDir + '/gewu-chat.jsonl', waitSeconds, plan.key);
      } else {
        nativeId = probe.start(this.filesDir + '/models/' + modelDir, JSON.stringify(request),
          this.filesDir + '/gewu-chat.jsonl', waitSeconds);
      }
    } catch (_) {
      if (plan !== undefined) this.reuse.finish(plan, false);
      return '无法启动模型，请确认模型文件已部署。';
    }
    if (nativeId <= 0) {
      if (plan !== undefined) this.reuse.finish(plan, false);
      return '模型繁忙，请稍后再发。';
    }
    this.jobs.push({
      requestId: requestId, nativeId: nativeId, cancelled: false, answer: '', raw: '', failure: '',
      finishReason: '', delivered: false, nativeStartedAt: nativeStartedAt, metrics: { streaming: request.stream },
      plan: plan, promptSource: taskTextOf(messages), callback: callback
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
    const job = this.jobs.find((item: Job) => item.requestId === requestId && !item.delivered);
    if (job === undefined) return;
    job.cancelled = true;
    probe.cancel(job.nativeId);
  }

  close(): void {
    this.closed = true;
    for (const job of this.jobs) job.callback = undefined;
    this.cancel();
    this.reuse.closeAll();
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
      if (event.event === 'response' && !job.delivered && !job.cancelled && !job.failure) {
        let response: NativeResponse;
        try { response = JSON.parse(event.payload) as NativeResponse; }
        catch (_) { this.parseFailure(job); continue; }
        if (!response) { this.parseFailure(job); continue; }
        if (response.usage !== null && typeof response.usage === 'object') {
          const usage = response.usage;
          job.metrics = { streaming: job.metrics.streaming,
            outputChunks: job.metrics.outputChunks, firstOutputMs: job.metrics.firstOutputMs, lastOutputMs: job.metrics.lastOutputMs,
            modelLoadMs: reportedNumber(usage.model_load_latency) ?? job.metrics.modelLoadMs,
            prefillMs: reportedNumber(usage.prefill_latency) ?? job.metrics.prefillMs,
            decodeMs: reportedNumber(usage.decode_latency) ?? job.metrics.decodeMs,
            promptTokens: reportedNumber(usage.prompt_tokens, true) ?? job.metrics.promptTokens,
            completionTokens: reportedNumber(usage.completion_tokens, true) ?? job.metrics.completionTokens };
        }
        if (typeof response.message?.content === 'string' && response.message.content.length > 0) {
          // GEWU 引擎可能在回调前就把跨块多字节字符替换成 U+FFFD：先修复后剔除，
          // answer、delta 回调与最终 done 用的都是这一份净化文本。
          const cleaned = sanitizeModelOutput(response.message.content, job.promptSource);
          job.raw += cleaned;
          const visible = stripThink(job.raw);
          const content = visible.substring(job.answer.length);
          if (content.length > 0) {
            const first = job.answer.length === 0;
            const elapsed = reportedNumber(event.elapsedMs, true);
            job.metrics = { streaming: job.metrics.streaming,
              outputChunks: (job.metrics.outputChunks ?? 0) + 1,
              firstOutputMs: first ? elapsed : job.metrics.firstOutputMs, lastOutputMs: elapsed,
              modelLoadMs: job.metrics.modelLoadMs, prefillMs: job.metrics.prefillMs, decodeMs: job.metrics.decodeMs,
              promptTokens: job.metrics.promptTokens, completionTokens: job.metrics.completionTokens };
            job.answer = visible;
            if (degenerateOutput(job.answer)) {
              hilog.warn(0, 'NearbyChat', 'degenerate output request=%{public}s chars=%{public}d',
                job.requestId, job.answer.length);
              job.failure = DEGENERATE_FAILURE;
              probe.cancel(job.nativeId);
              continue;
            }
            if (job.callback) job.callback({ kind: 'delta', text: content, metrics: first ? job.metrics : undefined,
              outputAt: elapsed === undefined ? undefined : job.nativeStartedAt + elapsed });
          }
        }
        if (typeof response.finish_reason === 'string' && response.finish_reason.length > 0) {
          job.finishReason = response.finish_reason;
          if (job.finishReason === 'abort' && !job.cancelled) job.failure = ENGINE_ABORT_FAILURE;
          probe.complete(job.nativeId);
        } else if (!job.metrics.streaming && job.answer.length > 0) {
          // stream:false has exactly one response; native already treats it as terminal.
          job.finishReason = 'stop';
          probe.complete(job.nativeId);
        }
        // A terminal response returns before native teardown. Streaming chunks
        // without a finish marker must keep the session and callback alive.
        if (job.finishReason.length > 0) { this.deliver(job); }
      }
      if (event.event === 'end') {
        if (!job.failure && !job.cancelled) {
          const mapped = endFailure(event.payload, job.answer.length > 0, job.finishReason.length > 0);
          if (mapped.length > 0) job.failure = mapped;
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
    this.deliver(job);
    if (job.plan !== undefined) {
      this.reuse.finish(job.plan, !job.failure && !job.cancelled && job.answer.length > 0);
    }
    this.jobs.splice(this.jobs.indexOf(job), 1);
    if (this.jobs.length === 0 && this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private deliver(job: Job): void {
    if (job.delivered) return;
    if (!job.failure && !job.cancelled && (!job.answer || !job.finishReason)) {
      job.failure = job.answer ? '模型会话已结束，但没有收到结束标记。' : '模型没有返回内容，请重试。';
    }
    const update: ChatUpdate = {
      kind: 'done', text: job.failure || (job.cancelled ?
        (job.answer ? job.answer + '\n\n已停止生成' : '已停止生成') : job.answer),
      finishReason: job.failure ? 'error' : job.cancelled ? 'cancelled' : job.finishReason, metrics: job.metrics
    };
    if (job.failure) update.error = job.failure;
    const callback = job.callback;
    job.callback = undefined;
    job.delivered = true;
    if (callback) callback(update);
  }
}
