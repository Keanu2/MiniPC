import http from '@ohos.net.http';
import { ChatMessage } from './LocalChat';
import { ComplexityBackend } from './XRouter';

interface ClassifierCompletionRequest {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  max_tokens: number;
  temperature: number;
}

interface ClassifierChoice {
  message?: ChatMessage;
}

interface ClassifierResponse {
  choices?: ClassifierChoice[];
}

/**
 * 云端复杂度分类器（上游 ComplexityBackend 的 judge kind="api" 形状）：
 * OpenAI 兼容 /chat/completions 单轮问答，temperature=0。
 * max_tokens 需覆盖推理模型的思考阶段（GLM-5.3 等 reasoning 模型先输出
 * reasoning_content 再给 content，预算过小会把配额耗在思考上导致 content 为空），
 * 默认 2048、可经 classifier.maxTokens 配置。
 * 只收成品 prompt、只回原始输出——严格单标签解析在 XRouter 侧。
 * 调用失败以 reject 上抛，由 XRouter 落 heuristic_fallback（no failure escalates）。
 */
export class CloudClassifier implements ComplexityBackend {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly model: string;
  private readonly timeoutMs: number;
  private readonly maxTokens: number;

  constructor(apiKey: string, baseUrl: string, model: string, timeoutSeconds: number, maxTokens: number = 2048) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
    this.model = model;
    this.timeoutMs = timeoutSeconds * 1000;
    this.maxTokens = maxTokens;
  }

  private endpoint(): string {
    if (this.baseUrl.endsWith('/chat/completions')) return this.baseUrl;
    if (this.baseUrl.endsWith('/v1')) return this.baseUrl + '/chat/completions';
    return this.baseUrl + '/v1/chat/completions';
  }

  classifyAsync(prompt: string): Promise<string> {
    const session = http.createHttp();
    const body: ClassifierCompletionRequest = {
      model: this.model,
      messages: [{ role: 'user', content: prompt }],
      stream: false,
      max_tokens: this.maxTokens,
      temperature: 0
    };
    return session.request(this.endpoint(), {
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
    }).then((response: http.HttpResponse): string => {
      session.destroy();
      const code = response.responseCode;
      const raw = typeof response.result === 'string' ? response.result : '';
      if (code < 200 || code >= 300) {
        throw new Error('classifier HTTP ' + code);
      }
      const parsed = JSON.parse(raw) as ClassifierResponse;
      const choice = parsed.choices !== undefined ? parsed.choices[0] : undefined;
      return choice?.message?.content ?? '';
    }).catch((error: Error): Promise<string> => {
      session.destroy();
      return Promise.reject(error);
    });
  }
}
