import http from '@ohos.net.http';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatBackend, ChatMessage, ChatStartOptions, ChatUpdate } from './LocalChat';

const CONFIG_FILE = 'cloud_config.json';
const DEFAULT_TIMEOUT_SECONDS = 120;
const MIN_TIMEOUT_SECONDS = 5;
const MAX_TIMEOUT_SECONDS = 600;
const DEFAULT_MAX_TOKENS = 2048;
const MAX_TOKEN_LIMIT = 8192;

/** filesDir/cloud_config.json 的形状；backend=cloud 时启用云侧推理。 */
interface CloudConfigJson {
  backend?: string;
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  timeoutSeconds?: number;
  /** qwen3 系思考会吃满输出预算（同 GLM 思考失控），true = 请求体带 enable_thinking:false。 */
  disableThinking?: boolean;
}

interface ChatCompletionRequest {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  max_tokens: number;
  enable_thinking?: boolean;
}

interface CompletionChoice {
  message?: ChatMessage;
  finish_reason?: string;
}

interface CompletionResponse {
  choices?: CompletionChoice[];
  error?: CloudErrorBody;
}

interface CloudErrorBody {
  message?: string;
  code?: string;
}

interface CloudJob {
  requestId: string;
  cancelled: boolean;
  finished: boolean;
  session: http.HttpRequest | null;
  callback: ((update: ChatUpdate) => void) | undefined;
}

/**
 * 云侧推理后端：OpenAI 兼容 /chat/completions，非流式一次取回。
 * 由 filesDir/cloud_config.json 启用（backend 缺省视为 cloud，显式 "local" 才走本地）；
 * 带图请求 fail closed，仍由本地多模态通道负责。配置在应用启动时读取一次，修改后需重启应用。
 */
export class CloudChat implements ChatBackend {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  /** 配置里的模型名，展示用。 */
  readonly modelName: string;
  private readonly timeoutMs: number;
  private readonly disableThinking: boolean;
  private closed: boolean = false;
  private jobs: CloudJob[] = [];

  private constructor(apiKey: string, baseUrl: string, model: string, timeoutMs: number, disableThinking: boolean) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
    this.modelName = model;
    this.timeoutMs = timeoutMs;
    this.disableThinking = disableThinking;
  }

  /** 配置文件存在且字段齐全时返回实例（backend 缺省视为 cloud）；文件缺失、解析失败、字段不齐或显式 local 均返回 null（走本地）。 */
  static create(filesDir: string): CloudChat | null {
    let text: string;
    try {
      text = fileIo.readTextSync(filesDir + '/' + CONFIG_FILE);
    } catch (_) {
      return null;
    }
    let json: CloudConfigJson;
    try {
      json = JSON.parse(text) as CloudConfigJson;
    } catch (_) {
      hilog.warn(0, 'NearbyChat', 'cloud config parse failed');
      return null;
    }
    // backend 缺省视为 cloud：配置文件存在且字段齐全即走云侧，只有显式 "local" 才回端侧。
    if (((json.backend ?? '').trim() || 'cloud') !== 'cloud') {
      return null;
    }
    const apiKey = (json.apiKey ?? '').trim();
    const baseUrl = (json.baseUrl ?? '').trim();
    const model = (json.model ?? '').trim();
    if (apiKey.length === 0 || baseUrl.length === 0 || model.length === 0) {
      hilog.warn(0, 'NearbyChat', 'cloud config incomplete');
      return null;
    }
    let seconds = DEFAULT_TIMEOUT_SECONDS;
    if (typeof json.timeoutSeconds === 'number' && Number.isFinite(json.timeoutSeconds)) {
      seconds = Math.min(MAX_TIMEOUT_SECONDS, Math.max(MIN_TIMEOUT_SECONDS, Math.floor(json.timeoutSeconds)));
    }
    return new CloudChat(apiKey, baseUrl, model, seconds * 1000, json.disableThinking === true);
  }

  isBusy(): boolean { return this.jobs.length > 0; }
  activeCount(): number { return this.jobs.length; }

  readinessError(): string {
    if (this.closed) return '模型服务已关闭。';
    return '';
  }

  private endpoint(): string {
    if (this.baseUrl.endsWith('/chat/completions')) return this.baseUrl;
    if (this.baseUrl.endsWith('/v1')) return this.baseUrl + '/chat/completions';
    return this.baseUrl + '/v1/chat/completions';
  }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, requestId: string = '',
    options: ChatStartOptions = {}): string {
    if (this.closed) return '模型服务已关闭。';
    if (messages.length === 0) return '请输入问题。';
    if ((options.image ?? '').length > 0) return '云端模型暂不支持图片理解。';
    const maxTokens = Number.isInteger(options.maxTokens) && (options.maxTokens as number) > 0 ?
      Math.min(MAX_TOKEN_LIMIT, options.maxTokens as number) : DEFAULT_MAX_TOKENS;
    const job: CloudJob = { requestId, cancelled: false, finished: false, session: null, callback };
    this.jobs.push(job);
    const session = http.createHttp();
    job.session = session;
    // 近场协议的系统提示用 developer 角色（GEWU 原生语义，本地路径不变）；
    // OpenAI 兼容端点只认 system/assistant/user/tool/function——旧 vLLM 端点宽松、
    // DashScope 系严格（HTTP 400），出云前归一化。
    const outbound: ChatMessage[] = [];
    for (const message of messages) {
      if (message.role === 'developer') {
        const mapped: ChatMessage = { role: 'system', content: message.content };
        outbound.push(mapped);
      } else {
        outbound.push(message);
      }
    }
    const body: ChatCompletionRequest = {
      model: this.modelName, messages: outbound, stream: false, max_tokens: maxTokens
    };
    if (this.disableThinking) {
      body.enable_thinking = false;
    }
    session.request(this.endpoint(), {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + this.apiKey
      },
      extraData: JSON.stringify(body),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: this.timeoutMs,
      readTimeout: this.timeoutMs,
      usingCache: false
    }).then((response: http.HttpResponse): void => {
      this.onResponse(job, response);
    }).catch((_error: Error): void => {
      // cancel() 主动 destroy 也会走到这里，按取消收尾。
      if (job.cancelled) {
        this.finish(job, { kind: 'done', text: '已停止生成', finishReason: 'cancelled' });
      } else {
        this.finish(job, { kind: 'done', text: '', error: '云端模型请求失败，请检查网络后重试。', finishReason: 'error' });
      }
    });
    return '';
  }

  private onResponse(job: CloudJob, response: http.HttpResponse): void {
    if (job.finished) return;
    const code = response.responseCode;
    const raw = typeof response.result === 'string' ? response.result : '';
    if (code < 200 || code >= 300) {
      this.finish(job, { kind: 'done', text: '', error: this.httpError(code, raw), finishReason: 'error' });
      return;
    }
    let parsed: CompletionResponse;
    try {
      parsed = JSON.parse(raw) as CompletionResponse;
    } catch (_) {
      this.finish(job, { kind: 'done', text: '', error: '云端模型回复解析失败，请重试。', finishReason: 'error' });
      return;
    }
    const choice = parsed.choices !== undefined ? parsed.choices[0] : undefined;
    const content = choice?.message?.content ?? '';
    let finishReason = 'stop';
    if (job.cancelled) {
      finishReason = 'cancelled';
    } else if (choice !== undefined && typeof choice.finish_reason === 'string' && choice.finish_reason.length > 0) {
      finishReason = choice.finish_reason;
    }
    // finish_reason=length 表示输出被 max_tokens 截断：思考占满预算时 content 为空，
    // 思考+正文超预算时留下残缺正文。两者都按上游 Outcome.OVERFLOW 细分上报，
    // RouterChat 据此排除该模型并降级重试，不把截断残句当答案交付或写入历史。
    if (finishReason === 'length') {
      this.finish(job, {
        kind: 'done',
        text: '',
        error: '云端模型输出预算耗尽（生成被截断），请简化问题或稍后重试。',
        finishReason: 'error',
        failureKind: 'overflow'
      });
      return;
    }
    if (content.length > 0 && !job.cancelled && job.callback !== undefined) {
      job.callback({ kind: 'delta', text: content });
    }
    this.finish(job, {
      kind: 'done',
      text: job.cancelled && content.length > 0 ? content + '\n\n已停止生成' : content,
      finishReason: finishReason
    });
  }

  private httpError(code: number, body: string): string {
    let detail = '';
    if (body.length > 0) {
      try {
        const parsed = JSON.parse(body) as CompletionResponse;
        if (parsed.error !== undefined && parsed.error.message !== undefined) detail = parsed.error.message;
      } catch (_) {
        // 非 JSON 错误体，忽略明细。
      }
    }
    return '云端模型请求失败（HTTP ' + code + (detail.length > 0 ? '：' + detail : '') + '）。';
  }

  cancel(requestId?: string): void {
    for (const job of this.jobs) {
      if (requestId === undefined || requestId.length === 0 || job.requestId === requestId) {
        job.cancelled = true;
        if (job.session !== null) job.session.destroy();
      }
    }
  }

  close(): void {
    this.closed = true;
    this.cancel();
  }

  private finish(job: CloudJob, update: ChatUpdate): void {
    if (job.finished) return;
    job.finished = true;
    const index = this.jobs.indexOf(job);
    if (index >= 0) this.jobs.splice(index, 1);
    if (job.session !== null) {
      job.session.destroy();
      job.session = null;
    }
    const callback = job.callback;
    job.callback = undefined;
    if (callback !== undefined) callback(update);
  }
}
