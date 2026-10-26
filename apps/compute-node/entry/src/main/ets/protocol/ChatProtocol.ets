import { util } from '@kit.ArkTS';

/** Engine-reported durations are separate from the caller's end-to-end clock. */
export interface InferenceMetrics {
  streaming: boolean;
  outputChunks?: number;
  /** Monotonic durations since native request start, never remote wall clocks. */
  firstOutputMs?: number;
  lastOutputMs?: number;
  modelLoadMs?: number;
  prefillMs?: number;
  decodeMs?: number;
  promptTokens?: number;
  completionTokens?: number;
}

export interface ChatMessage { role: string; content: string; }
/** Capability vocabulary shared by device declarations and request needs. */
export const CAPABILITY_TAGS: string[] = ['text', 'vision'];
/**
 * 图片随请求传输的裸 base64 上限（无 data: 前缀）。约束链：分片层 MAX_FRAME 64KiB、
 * 原生 NAPI 入参 64KiB——24000 字符 base64（约 18KB JPEG）加消息文本后两侧都留有余量。
 */
export const MAX_IMAGE_BASE64: number = 24000;
export interface DeviceInfoEntry {
  id?: string;
  /** Stable per-install identity. `id` remains for compatibility with older builds. */
  deviceUid?: string;
  name?: string;
  role?: string;
  memTotal?: number;
  memAvail?: number;
  memUsage?: number;
  /** System thermal gear 0–7, or -1 when unknown. */
  thermalLevel?: number;
  /** Battery temperature in Celsius, or -1 when unknown. */
  batteryTemp?: number;
  /** Whole-device CPU occupancy 0–100, or -1 when unknown. */
  cpuUsage?: number;
  model?: string;
  modelRequests?: number;
  /**
   * 部署声明的模型能力，如 ['text', 'vision']。
   * 缺省 = 老对端（v1）未声明，按纯文本处理。
   */
  capabilities?: string[];
  /**
   * 部署模型声明的最高强度档位 1-2（1 弱、2 强）；缺省 = 老对端/未部署，消费侧
   * 按 2（强档）处理。线上容忍旧构建上报的 3，消费侧归一为 2。
   * 档位是质量偏好：绝不参与 fail closed 判定。
   */
  modelTier?: number;
  ready?: boolean;
  slot?: number;
}
export interface TaskChildSnapshot {
  input?: string;
  activity?: string;
  id: string;
  title: string;
  device: string;
  phase: string;
  detail: string;
  result?: string;
  resultTruncated?: boolean;
  startedAt?: number;
  endedAt?: number;
}

/** Display-only parent/child state; never used to authorize or schedule work. */
export interface TaskSnapshot {
  input?: string;
  activity?: string;
  inputTruncated?: boolean;
  answerTruncated?: boolean;
  id: string;
  title: string;
  phase: string;
  revision: number;
  startedAt: number;
  endedAt: number;
  subtasks: TaskChildSnapshot[];
  answer: string;
}

export interface WireMessage {
  metrics?: InferenceMetrics;
  protocol?: string;
  type: string;
  taskId?: string;
  subtaskId?: string;
  task?: TaskSnapshot;
  requestId?: string;
  messages?: ChatMessage[];
  text?: string;
  finishReason?: string;
  error?: string;
  peerRole?: string;
  sched?: boolean;
  /** Public origin label preserved when a coordinator forwards a request. */
  origin?: string;
  source?: string;
  name?: string;
  memTotal?: number;
  memAvail?: number;
  memUsage?: number;
  thermalLevel?: number;
  batteryTemp?: number;
  cpuUsage?: number;
  model?: string;
  modelRequests?: number;
  capabilities?: string[];
  /** 部署模型声明的最高强度档位 1-3；仅 deviceInfo 声明携带，消费侧缺省按 2。 */
  modelTier?: number;
  /** Capabilities a request needs; routing fails closed when no device has them. */
  needs?: string[];
  /** 本次请求携带的 JPEG 图片，裸 base64（无 data: 前缀）；带图请求必须需要 vision。 */
  image?: string;
  devices?: DeviceInfoEntry[];
  slot?: number;
  /** Stable per-install identity exchanged during hello/roster sync. */
  deviceUid?: string;
  /** Inference extension versions. Absent on older peers. */
  inferenceVersions?: number[];
  version?: number;
  clientInstanceId?: string;
  agentRunId?: string;
  modelId?: string;
  modelRevision?: string;
  promptFormat?: string;
  prompt?: string;
  maxOutputTokens?: number;
  deadlineBudgetMs?: number;
  seq?: number;
  lastSeq?: number;
  outputUtf8Bytes?: number;
  outputSha256?: string;
  code?: string;
  message?: string;
  retryable?: boolean;
  state?: string;
  profiles?: InferProfile[];
  /** Cluster idle/total on infer.status; the compute hub also reports it in capabilities. */
  cluster?: ClusterInfo;
  /** Label of the device that actually runs an accepted request. */
  device?: string;
  /** Short caption of the request's purpose, e.g. a parallel sub-task. Display only. */
  label?: string;
}

export interface ClusterInfo {
  idle: number;
  total: number;
}

export interface InferProfile {
  modelId: string;
  modelRevision: string;
  promptFormat: string;
  maxContextTokens: number;
  maxOutputTokens: number;
  maxPromptBytes: number;
  maxWireBytes: number;
  tokenBudgetMode: string;
  streaming: boolean;
  cancellation: boolean;
  ready: boolean;
  readinessReason: string;
  maxCtx: number;
  gateBPassed: boolean;
  /** Host accepts `messages` (developer + user) instead of one flattened prompt. */
  splitMessages?: boolean;
  /** Present on the compute hub: how many modelled devices exist and how many are idle. */
  cluster?: ClusterInfo;
}

/**
 * 协议号保持 v1。
 *
 * 收发两端都用精确匹配校验（`m.protocol !== PROTOCOL` 即拒收），而聊天端
 * apps/agent-client 与 legacy/* 目前都还是 v1。本次只改 apps/compute-node，
 * 若在此升到 v2，两边会互相拒收**全部**消息（不只是带图请求）。
 *
 * 多模态需要的能力/需求/图片字段都是**可选追加**，v1 对端的校验只检查已知字段、
 * 会忽略它们，因此不需要升号。等聊天端一起升级时再统一改这里。
 */
const PROTOCOL = 'nearby-chat-v1';
const MAX_FRAME = 65536;

function validOptionalString(value: string | undefined, max: number): boolean {
  return value === undefined || (typeof value === 'string' && value.length <= max);
}

function validOptionalNumber(value: number | undefined): boolean {
  return value === undefined || (typeof value === 'number' && Number.isFinite(value));
}

/**
 * 能力清单：已知标签组成的数组，长度上限 `max`。
 *
 * `undefined` 合法 = 对端未声明能力，按纯文本处理；路由侧 meetsNeeds 会因此
 * fail closed，绝不会把带图请求交给它。这样 v1 对端（不带该字段）仍能互通。
 */
function validCapabilities(value: string[] | undefined, max: number): boolean {
  if (value === undefined) return true;
  if (!Array.isArray(value) || value.length > max) return false;
  for (const tag of value) {
    if (typeof tag !== 'string' || CAPABILITY_TAGS.indexOf(tag) < 0) return false;
  }
  return true;
}

/**
 * 强度档位：undefined（老对端未声明）或整数 1-3（容忍旧构建上报的 3，消费侧归一为 2）。
 * 档位是质量偏好，只影响选点偏好，绝不构成拒收理由——这里仅拦畸形值。
 */
function validModelTier(value: number | undefined): boolean {
  return value === undefined ||
    (typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 3);
}

function validDeviceEntry(entry: DeviceInfoEntry): boolean {
  if (entry === null || typeof entry !== 'object') return false;
  return validOptionalString(entry.id, 128) && validOptionalString(entry.deviceUid, 64) &&
    validOptionalString(entry.name, 128) &&
    (entry.role === undefined || entry.role === 'chat' || entry.role === 'compute' || entry.role === 'self') &&
    validOptionalNumber(entry.memTotal) && validOptionalNumber(entry.memAvail) &&
    validOptionalNumber(entry.memUsage) && validOptionalNumber(entry.thermalLevel) &&
    validOptionalNumber(entry.batteryTemp) && validOptionalNumber(entry.cpuUsage) &&
    validOptionalString(entry.model, 128) &&
    validOptionalNumber(entry.modelRequests) &&
    validCapabilities(entry.capabilities, 8) &&
    validModelTier(entry.modelTier) &&
    (entry.ready === undefined || typeof entry.ready === 'boolean') &&
    (entry.slot === undefined || (Number.isInteger(entry.slot) && entry.slot >= 1 && entry.slot <= 64));
}

function validDeviceInfo(m: WireMessage): boolean {
  return validOptionalString(m.name, 128) && validOptionalString(m.model, 128) &&
    validOptionalNumber(m.memTotal) && validOptionalNumber(m.memAvail) &&
    validOptionalNumber(m.memUsage) && validOptionalNumber(m.thermalLevel) &&
    validOptionalNumber(m.batteryTemp) && validOptionalNumber(m.cpuUsage) &&
    validOptionalNumber(m.modelRequests) && validCapabilities(m.capabilities, 8) &&
    validModelTier(m.modelTier) &&
    (m.peerRole === undefined || m.peerRole === 'compute' || m.peerRole === 'chat');
}

function validDeviceInfoSync(m: WireMessage): boolean {
  if (!Array.isArray(m.devices) || m.devices.length > 16) return false;
  for (const entry of m.devices) {
    if (!validDeviceEntry(entry)) return false;
  }
  return true;
}

function metricNumber(value: number | undefined, integer: boolean = false): boolean {
  return value === undefined || (typeof value === 'number' && Number.isFinite(value) && value >= 0 &&
    (!integer || Number.isSafeInteger(value)));
}

function validInferenceMetrics(metrics: InferenceMetrics | undefined): boolean {
  return metrics === undefined || (metrics !== null && typeof metrics === 'object' &&
    typeof metrics.streaming === 'boolean' && metricNumber(metrics.modelLoadMs) &&
    metricNumber(metrics.outputChunks, true) && metricNumber(metrics.firstOutputMs) &&
    metricNumber(metrics.lastOutputMs) &&
    metricNumber(metrics.outputChunks, true) && metricNumber(metrics.firstOutputMs) &&
    metricNumber(metrics.lastOutputMs) &&
    metricNumber(metrics.prefillMs) && metricNumber(metrics.decodeMs) &&
    metricNumber(metrics.promptTokens, true) && metricNumber(metrics.completionTokens, true));
}

// Validate before forwarding anything to the model or UI.
export function validMessage(m: WireMessage): boolean {
  if (m === null || typeof m !== 'object' || m.protocol !== PROTOCOL || typeof m.type !== 'string') return false;
  if (!validInferenceMetrics(m.metrics)) return false;
  if (['hello', 'hello_ack'].includes(m.type)) {
    if (m.peerRole !== undefined && m.peerRole !== 'compute' && m.peerRole !== 'chat') return false;
    if (!validOptionalString(m.name, 128)) return false;
    if (!validOptionalString(m.deviceUid, 64)) return false;
    if (m.slot !== undefined && (!Number.isInteger(m.slot) || m.slot < 1 || m.slot > 64)) return false;
    return true;
  }
  if (typeof m.requestId !== 'string' || m.requestId.length === 0 || m.requestId.length > 128) return false;
  if (m.type === 'cancel' || m.type === 'prepare') return true;
  if (m.type === 'prepared') return m.error === undefined ||
    (typeof m.error === 'string' && m.error.length <= 2048);
  if (m.type === 'delta') return typeof m.text === 'string' && m.text.length <= 16000;
  if (m.type === 'done') {
    return (m.finishReason === undefined || (typeof m.finishReason === 'string' && m.finishReason.length <= 128)) &&
      (m.source === undefined || (typeof m.source === 'string' && m.source.length <= 256));
  }
  if (m.type === 'error') return typeof m.error === 'string' && m.error.length <= 2048;
  if (m.type === 'deviceInfo') return validDeviceInfo(m);
  if (m.type === 'deviceInfoSync') return validDeviceInfoSync(m);
  if (m.type === 'gate') return typeof m.text === 'string' && m.text.length > 0 && m.text.length <= 40000;
  if (m.type.indexOf('infer.') === 0) return validInference(m);
  if (m.type !== 'request' || !Array.isArray(m.messages) || m.messages.length === 0 || m.messages.length > 7) return false;
  if (m.sched !== undefined && m.sched !== true && m.sched !== false) return false;
  if (!validCapabilities(m.needs, 4)) return false;
  // 带图请求必须声明 vision 需求：保证能力路由永远不把图片交给纯文本设备。
  if (m.image !== undefined) {
    if (typeof m.image !== 'string' || m.image.length === 0 || m.image.length > MAX_IMAGE_BASE64 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(m.image)) return false;
    if (m.needs === undefined || m.needs.indexOf('vision') < 0) return false;
  }
  if (!validOptionalString(m.origin, 128)) return false;
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
// Only NEW fragments renew the idle budget. Keep an absolute bound against drip feeds.
const FRAGMENT_TIMEOUT = 15000;
const FRAGMENT_MAX_DURATION = 120000;
interface Fragment { version: number; id: string; index: number; count: number; data: string; }
class PendingMessage {
  created: number = Date.now();
  progressed: number = this.created;
  count: number;
  bytes: number = 0;
  parts: Map<number, Uint8Array> = new Map();
  constructor(count: number) { this.count = count; }
}

export function validTaskSnapshot(task: TaskSnapshot): boolean {
  if (task === null || typeof task !== 'object' || !/^[A-Za-z0-9_-]{1,64}$/.test(task.id) ||
    typeof task.id !== 'string' || typeof task.title !== 'string' || task.title.length === 0 || task.title.length > 1000 ||
    !['running', 'merging', 'done', 'partial', 'failed', 'cancelled'].includes(task.phase) ||
    !Number.isSafeInteger(task.revision) || task.revision < 1 ||
    !Number.isSafeInteger(task.startedAt) || task.startedAt < 1 || !Number.isSafeInteger(task.endedAt) || task.endedAt < 0 ||
    typeof task.answer !== 'string' || task.answer.length > 4096 ||
    !validOptionalString(task.input, 32768) || !validOptionalString(task.activity, 2048) ||
    (task.inputTruncated !== undefined && typeof task.inputTruncated !== 'boolean') ||
    (task.answerTruncated !== undefined && typeof task.answerTruncated !== 'boolean') ||
    !Array.isArray(task.subtasks) || task.subtasks.length === 1 || task.subtasks.length > 4) return false;
  const terminal = ['done', 'partial', 'failed', 'cancelled'].includes(task.phase);
  if (terminal ? task.endedAt < task.startedAt : task.endedAt !== 0) return false;
  const ids: string[] = [];
  for (const child of task.subtasks) {
    if (child === null || typeof child !== 'object' || typeof child.id !== 'string' ||
      !/^[A-Za-z0-9_-]{1,64}$/.test(child.id) || ids.includes(child.id) ||
      typeof child.title !== 'string' || child.title.length === 0 || child.title.length > 160 ||
      typeof child.device !== 'string' || (child.device !== '' && !/^算力设备[1-9][0-9]*$/.test(child.device)) ||
      !['queued', 'running', 'done', 'partial', 'failed', 'cancelled'].includes(child.phase) ||
      typeof child.detail !== 'string' || child.detail.length > 256 ||
      !validOptionalString(child.input, 500) || !validOptionalString(child.activity, 1024) || !validOptionalString(child.result, 2048) ||
      (child.resultTruncated !== undefined && typeof child.resultTruncated !== 'boolean') ||
      (child.startedAt !== undefined && (!Number.isSafeInteger(child.startedAt) || child.startedAt < 0)) ||
      (child.endedAt !== undefined && (!Number.isSafeInteger(child.endedAt) || child.endedAt < 0))) return false;
    ids.push(child.id);
  }
  return task.phase !== 'done' || task.subtasks.every((child: TaskChildSnapshot): boolean => child.phase === 'done');
}

function validInference(m: WireMessage): boolean {
  if (m.version !== undefined && m.version !== 2) return false;
  if (!validOptionalString(m.origin, 64)) return false;
  if ((m.taskId === undefined) !== (m.subtaskId === undefined)) return false;
  if (m.taskId !== undefined && (typeof m.taskId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(m.taskId) ||
    typeof m.subtaskId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(m.subtaskId))) return false;
  if (m.type === 'infer.task') return m.version === 2 && validTaskSnapshot(m.task as TaskSnapshot) && m.requestId === m.task?.id;
  if (m.task !== undefined) return false;
  if (typeof m.requestId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(m.requestId)) return false;
  if (m.prompt !== undefined && (typeof m.prompt !== 'string' ||
    new util.TextEncoder().encodeInto(m.prompt).length > 32768)) return false;
  // infer 通道的可选附图：与 nearby-chat request 同一条约束（裸 base64、无 data: 前缀、
  // 受 MAX_IMAGE_BASE64 限制）。缺这道校验，畸形/超长图片会绕过协议层直达 VL 引擎。
  if (m.image !== undefined) {
    if (typeof m.image !== 'string' || m.image.length === 0 || m.image.length > MAX_IMAGE_BASE64 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(m.image)) return false;
  }
  if (m.text !== undefined && (typeof m.text !== 'string' ||
    new util.TextEncoder().encodeInto(m.text).length > 1024)) return false;
  if (m.message !== undefined && (typeof m.message !== 'string' || m.message.length > 1024)) return false;
  if (m.device !== undefined && (typeof m.device !== 'string' || m.device.length > 128)) return false;
  if (m.label !== undefined && (typeof m.label !== 'string' || m.label.length > 64)) return false;
  if (m.cluster !== undefined && !validCluster(m.cluster)) return false;
  return m.messages === undefined || validInferenceMessages(m.messages);
}

export function validCluster(value: ClusterInfo): boolean {
  return value !== null && typeof value === 'object' && Number.isInteger(value.idle) && Number.isInteger(value.total) &&
    value.idle >= 0 && value.total >= 0 && value.total <= 64 && value.idle <= value.total;
}

/** loop-react-split-v1: optional developer turn, then exactly one non-empty user turn. */
export function validInferenceMessages(messages: ChatMessage[]): boolean {
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > 2) return false;
  let bytes = 0;
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    if (message === null || typeof message !== 'object' || typeof message.content !== 'string') return false;
    const last = index === messages.length - 1;
    if (last ? message.role !== 'user' : message.role !== 'developer') return false;
    bytes += new util.TextEncoder().encodeInto(message.content).length;
  }
  return bytes <= 32768 && messages[messages.length - 1].content.trim().length > 0;
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

/** Metadata only: never expose fragment bytes or inference input to diagnostics. */
export interface FragmentReceipt {
  id: string; index: number; count: number; received: number; bytes: number;
  elapsedMs: number; gapMs: number;
}

export class MessageAssembler {
  private fragmentObserver: ((receipt: FragmentReceipt) => void) | null = null;

  setFragmentObserver(observer: (receipt: FragmentReceipt) => void): void { this.fragmentObserver = observer; }

  private pending: Map<string, PendingMessage> = new Map();
  // Session-local replay window; clear on disconnect. No timers apply to inference.
  private completed: string[] = [];

  clear(): void { this.pending.clear(); this.completed = []; }

  checkExpiry(): void {
    for (const entry of this.pending) {
      const pending = entry[1];
      const age = Date.now() - pending.created;
      const idle = Date.now() - pending.progressed;
      if (idle >= FRAGMENT_TIMEOUT || age >= FRAGMENT_MAX_DURATION) {
        const reason = 'Incomplete chat fragments timed out id=' + entry[0] +
          ' received=' + pending.parts.size.toString() + '/' + pending.count.toString() +
          ' bytes=' + pending.bytes.toString() + ' ageMs=' + age.toString() + ' idleMs=' + idle.toString();
        this.clear();
        throw new Error(reason);
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
    const gap = Date.now() - pending.progressed;
    pending.parts.set(fragment.index, bytes);
    pending.progressed = Date.now();
    pending.bytes += bytes.length;
    try {
      this.fragmentObserver?.({ id: fragment.id, index: fragment.index, count: fragment.count,
        received: pending.parts.size, bytes: pending.bytes, elapsedMs: Date.now() - pending.created, gapMs: gap });
    } catch (_) { /* Diagnostics must never interrupt delivery. */ }
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
