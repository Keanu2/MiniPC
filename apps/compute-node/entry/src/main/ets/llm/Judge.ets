import http from '@ohos.net.http';
import { ChatMessage } from './LocalChat';

/**
 * 质量裁判（上游 judge.py 严格移植）：把已服务的回答打成一个带符号质量分
 * （[-1,1]），供 bandit store 攒档位证据。纯函数部分（prompt 构建/分数解析）
 * 逐字对齐上游；JudgeClient 为本环境传输（复制 CloudClassifier 的 HTTP 形态）。
 * 上游默认 max_tokens=64/timeout=30s——本环境 judge 与分类器同为 GLM 推理模型，
 * 思考阶段需预算，默认 2048/60s（装配期钳制见 XRouter.loadServiceConfig）。
 */

/** 上游 RUBRIC_WEIGHTS：键序即浮点求和序，勿动（改权重=新旧质量分不可比）。 */
export const RUBRIC_WEIGHTS: Record<string, number> = {
  'task_progress': 0.45,
  'correctness': 0.35,
  'grounding': 0.20
};

/** 上游 JUDGE_SYSTEM_PROMPT 逐字（judge.py:64-69）。 */
export const JUDGE_SYSTEM_PROMPT: string = `You are a strict evaluator of a single assistant turn in an agent conversation.
Score only the assistant turn from -1.0 to 1.0 for each criterion. Positive is good, zero is borderline, and negative is bad.
- task_progress: +1 makes decisive concrete progress; 0 neither advances nor hurts; -1 stalls, is off-task, or moves backward.
- correctness: +1 is correct and appropriate; 0 is partly correct or questionable; -1 is wrong or uses an invalid tool/arguments.
- grounding: +1 is fully consistent with the conversation; 0 has minor unsupported details; -1 invents facts, files, or tools.
Reply with ONLY a JSON object with task_progress, correctness, and grounding numeric fields.`;

const TRANSCRIPT_CHARS = 3000;
const RESPONSE_CHARS = 2000;
const TRUNCATION_MARK = '\n...[truncated]...\n';

/** 上游 JudgeError：裁判拿不到可用回复即抛错，绝不静默降级成 0 分入库。 */
export class JudgeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'JudgeError';
  }
}

export interface JudgeRequest {
  systemPrompt: string;
  userPrompt: string;
}

/** 裁判传输槽（上游 JudgeBackend 协议）：收成品请求、回原始输出，解析在纯函数侧。 */
export interface JudgeTransport {
  scoreAsync(request: JudgeRequest): Promise<string>;
}

export class Judge {
  /** 上游 _truncate_middle：头尾各留一半，中段以标记替换（与 boundedText 的分配法不同，勿混用）。 */
  static truncateMiddle(text: string, limit: number): string {
    if (text.length <= limit) return text;
    const half = Math.max(0, Math.floor((limit - TRUNCATION_MARK.length) / 2));
    return text.substring(0, half) + TRUNCATION_MARK + text.substring(text.length - half);
  }

  /**
   * 上游 build_judge_request（无 tool_calls/tools 分支——本 wire 协议无工具调用）：
   * transcript 逐行 [role]: text 后中段截 3000；回答 trim 非空才入块，中段截 2000。
   */
  static buildJudgeRequest(messages: ChatMessage[], responseText: string | null): JudgeRequest {
    const lines: string[] = [];
    for (const message of messages ?? []) {
      const role = (message.role ?? '') || 'user';
      lines.push('[' + role + ']: ' + `${message.content ?? ''}`);
    }
    const transcript = Judge.truncateMiddle(lines.join('\n'), TRANSCRIPT_CHARS);
    const turn: string[] = [];
    const text = `${responseText ?? ''}`.trim();
    if (text.length > 0) turn.push(Judge.truncateMiddle(text, RESPONSE_CHARS));
    const userPrompt = '<transcript>\n' + transcript + '\n</transcript>\n\n'
      + '<assistant_turn>\n' + turn.join('\n') + '\n</assistant_turn>\n\n'
      + 'Score the assistant turn. Do not continue the conversation. Output only the JSON object.';
    const request: JudgeRequest = { systemPrompt: JUDGE_SYSTEM_PROMPT, userPrompt: userPrompt };
    return request;
  }

  /**
   * 上游 parse_judge_score：取首个带 rubric 字段的 JSON 对象，按在场字段加权
   * 重归一（越界字段忽略不钳制）；无 JSON 则兜底取最后一个裸数字；两者皆无
   * 或越界 → 抛错（上游 ValueError，此处统一 JudgeError——宿主只计数）。
   */
  static parseJudgeScore(raw: string | null): number {
    const text = `${raw ?? ''}`.trim();
    const objectRe = /\{[^{}]*\}/g;
    for (let match = objectRe.exec(text); match !== null; match = objectRe.exec(text)) {
      let payload: Object | null = null;
      try {
        payload = JSON.parse(match[0]) as Object;
      } catch (_) {
        continue;
      }
      if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) continue;
      const record = payload as Record<string, Object>;
      const values: Map<string, number> = new Map<string, number>();
      for (const key of Object.keys(RUBRIC_WEIGHTS)) {
        const value = record[key];
        // JS typeof 天然排除 bool（上游需显式排除 isinstance(True,int)）；NaN 过不了范围检查。
        if (typeof value === 'number' && value >= -1.0 && value <= 1.0) {
          values.set(key, value);
        }
      }
      if (values.size > 0) {
        let total = 0;
        let acc = 0;
        values.forEach((value: number, key: string): void => {
          total += RUBRIC_WEIGHTS[key];
          acc += RUBRIC_WEIGHTS[key] * value;
        });
        return acc / total;
      }
    }
    const numberRe = /[-+]?(?:\d+(?:\.\d*)?|\.\d+)/g;
    const numbers = text.match(numberRe);
    if (numbers === null || numbers.length === 0) {
      throw new JudgeError('judge output must contain rubric JSON or a signed score');
    }
    const score = Number(numbers[numbers.length - 1]);
    if (!(score >= -1.0 && score <= 1.0)) {
      throw new JudgeError('judge score must be within [-1, 1]');
    }
    return score;
  }
}

interface JudgeCompletionRequest {
  model: string;
  messages: ChatMessage[];
  stream: boolean;
  max_tokens: number;
  temperature: number;
  enable_thinking?: boolean;
}

interface JudgeChoice {
  message?: ChatMessage;
}

interface JudgeResponse {
  choices?: JudgeChoice[];
}

/** 上游 ApiJudgeBackend 的本环境形态：OpenAI 兼容单轮，system+user 双消息，temperature=0。 */
export class JudgeClient implements JudgeTransport {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly model: string;
  private readonly timeoutMs: number;
  private readonly maxTokens: number;
  private readonly disableThinking: boolean;

  constructor(apiKey: string, baseUrl: string, model: string, timeoutSeconds: number, maxTokens: number = 2048,
    disableThinking: boolean = false) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
    this.model = model;
    this.timeoutMs = timeoutSeconds * 1000;
    this.maxTokens = maxTokens;
    this.disableThinking = disableThinking;
  }

  private endpoint(): string {
    if (this.baseUrl.endsWith('/chat/completions')) return this.baseUrl;
    if (this.baseUrl.endsWith('/v1')) return this.baseUrl + '/chat/completions';
    return this.baseUrl + '/v1/chat/completions';
  }

  scoreAsync(request: JudgeRequest): Promise<string> {
    const session = http.createHttp();
    const body: JudgeCompletionRequest = {
      model: this.model,
      messages: [
        { role: 'system', content: request.systemPrompt },
        { role: 'user', content: request.userPrompt }
      ],
      stream: false,
      max_tokens: this.maxTokens,
      temperature: 0
    };
    if (this.disableThinking) {
      body.enable_thinking = false;
    }
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
        throw new Error('judge HTTP ' + code);
      }
      const parsed = JSON.parse(raw) as JudgeResponse;
      const choice = parsed.choices !== undefined ? parsed.choices[0] : undefined;
      return choice?.message?.content ?? '';
    }).catch((error: Error): Promise<string> => {
      session.destroy();
      return Promise.reject(error);
    });
  }
}
