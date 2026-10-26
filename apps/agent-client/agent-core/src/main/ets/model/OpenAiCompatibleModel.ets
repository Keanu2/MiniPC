import http from '@ohos.net.http';
import util from '@ohos.util';
import { ChatMessage, ConversationContext } from '../agent/ConversationContext';
import { aiLogInfo } from '../aiphone/runtime/AiphoneLogger';
import { buildSkillsSection, SkillSnapshot } from '../skill/SkillSnapshot';
import { LocalModel } from './LocalModel';
import { LlmProvider } from './LlmProvider';
import { parseTextCompletion } from './TextCompletionResponse';

const MODEL_CONNECT_TIMEOUT_MS = 20000;
const MODEL_READ_TIMEOUT_MS = 40000;
const MODEL_MAX_ATTEMPTS = 2;

interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  stream: boolean;
}

export class OpenAiCompatibleModel implements LocalModel {
  private provider: LlmProvider;
  private skillSnapshot: SkillSnapshot | null;

  constructor(provider: LlmProvider, skillSnapshot?: SkillSnapshot) {
    this.provider = provider;
    this.skillSnapshot = skillSnapshot ?? null;
  }

  async complete(prompt: string, conversation?: ConversationContext): Promise<string> {
    if (!this.provider.isConfigured()) {
      throw new Error('LLM provider is not configured.');
    }

    let lastMessage = '';
    for (let attempt = 0; attempt < MODEL_MAX_ATTEMPTS; attempt++) {
      try {
        return await this.completeOnce(prompt, conversation);
      } catch (error) {
        lastMessage = this.describeThrown(error);
        if (attempt + 1 >= MODEL_MAX_ATTEMPTS || !this.isRetryableTransportError(lastMessage)) {
          throw new Error(`LLM request failed: ${lastMessage}`);
        }
      }
    }
    throw new Error(`LLM request failed: ${lastMessage}`);
  }

  private async completeOnce(prompt: string, conversation?: ConversationContext): Promise<string> {
    const httpRequest = http.createHttp();
    const decoder = util.TextDecoder.create('utf-8');
    const requestStartMs = Date.now();
    let rawResponse = '';
    let chunkSequence = 0;
    let streamEndResolve: () => void = () => {};
    const streamEnd = new Promise<void>((resolve: () => void) => {
      streamEndResolve = resolve;
    });
    httpRequest.on('dataReceive', (data: ArrayBuffer) => {
      chunkSequence++;
      const chunk = decoder.decodeToString(new Uint8Array(data), { stream: true });
      rawResponse += chunk;
      const preview = chunk.replace(/\r/g, '\\r').replace(/\n/g, '\\n');
      aiLogInfo(
        '[AIPhone][ModelResponseChunk] seq=' + chunkSequence.toString() +
        ' bytes=' + data.byteLength.toString() +
        ' chars=' + chunk.length.toString() +
        ' elapsedMs=' + (Date.now() - requestStartMs).toString() +
        ' data=' + preview
      );
    });
    httpRequest.on('dataEnd', () => {
      streamEndResolve();
    });
    try {
      const endpoint = this.provider.chatCompletionsUrl();
      aiLogInfo(
        '[AIPhone][ModelRequestStart] model=' + this.provider.model +
        ' endpoint=' + endpoint +
        ' stream=true'
      );
      const statusCode = await httpRequest.requestInStream(endpoint, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${this.provider.apiKey}`,
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'text/event-stream'
        },
        extraData: this.buildRequestJson(prompt, conversation),
        connectTimeout: MODEL_CONNECT_TIMEOUT_MS,
        readTimeout: MODEL_READ_TIMEOUT_MS
      });
      let endTimedOut = false;
      const endTimer = setTimeout((): void => {
        endTimedOut = true;
        streamEndResolve();
      }, MODEL_READ_TIMEOUT_MS);
      try {
        await streamEnd;
      } finally {
        clearTimeout(endTimer);
      }
      if (endTimedOut) throw new Error('Truncated LLM stream: missing dataEnd.');
      rawResponse += decoder.decodeToString(new Uint8Array(0), { stream: false });

      if (statusCode < 200 || statusCode >= 300) {
        throw new Error(`LLM request failed with HTTP ${statusCode}: ${rawResponse}`);
      }

      return this.parseContent(rawResponse);
    } catch (error) {
      throw new Error(this.describeThrown(error));
    } finally {
      httpRequest.destroy();
    }
  }

  private describeThrown(error: Error | Object | string | number | boolean | null | undefined): string {
    if (error instanceof Error) {
      return error.message;
    }
    if (error === undefined || error === null) {
      return `${error}`;
    }
    try {
      const json = JSON.stringify(error);
      if (json !== undefined && json.length > 0 && json !== '{}') {
        return json;
      }
    } catch (_jsonError) {
    }
    return `${error}`;
  }

  private isRetryableTransportError(message: string): boolean {
    const lower = message.toLowerCase();
    if (lower.indexOf('http 4') >= 0 || lower.indexOf('http 5') >= 0) {
      return false;
    }
    return lower.indexOf('[object object]') >= 0 ||
      lower.indexOf('2300') >= 0 ||
      lower.indexOf('timeout') >= 0 ||
      lower.indexOf('failed to receive') >= 0 ||
      lower.indexOf('connection') >= 0 ||
      lower.indexOf('network') >= 0;
  }

  private buildRequest(prompt: string, conversation?: ConversationContext): ChatRequest {
    const messages: ChatMessage[] = [
      {
        role: 'system',
        content: this.systemPrompt()
      }
    ];

    // ReActAgentRunner already embeds the conversation in the flat prompt.
    // Do not add it again as structured messages: duplicating history makes
    // old tool results look like part of the current task.
    messages.push({
      role: 'user',
      content: prompt
    });

    return {
      model: this.provider.model,
      messages,
      temperature: 0.2,
      stream: true
    };
  }

  private systemPrompt(): string {
    let content = 'You are Loop, a concise ReAct agent on HarmonyOS. Do not output Thought, reasoning, or analysis. Reply directly with either Final Answer (in Chinese): answer, or Execution: serial | parallel followed by one or more Action: tool[input] lines. Use parallel only for independent tools. Use only listed tools and follow the tool-routing rules in the prompt exactly.';
    const skills = buildSkillsSection(this.skillSnapshot);
    if (skills.length > 0) {
      content += `\n\n${skills}`;
    }
    return content;
  }

  private buildRequestJson(prompt: string, conversation?: ConversationContext): string {
    const baseJson = JSON.stringify(this.buildRequest(prompt, conversation));
    const customJson = this.provider.customParametersJson.trim();
    if (customJson.length === 0) {
      return baseJson;
    }
    try {
      const parsed = JSON.parse(customJson) as Object;
      if (parsed === undefined || parsed === null || Array.isArray(parsed)) {
        return baseJson;
      }
      if (customJson.search(/"model"\s*:/) >= 0 || customJson.search(/"messages"\s*:/) >= 0) {
        return baseJson;
      }
      const normalizedCustomJson = JSON.stringify(parsed);
      if (normalizedCustomJson.length <= 2) {
        return baseJson;
      }
      return baseJson.substring(0, baseJson.length - 1) + ',' + normalizedCustomJson.substring(1);
    } catch (_error) {
      return baseJson;
    }
  }

  private parseContent(body: string): string {
    return parseTextCompletion(body);
  }
}
