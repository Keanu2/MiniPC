import { TaskGroupView } from './TaskBoard';
import { InferenceMetrics } from '../protocol/ChatProtocol';

export interface ModelSettingsView {
  streaming: boolean;
  selected: string;
  options: ModelChoiceView[];
  locked: boolean;
  /** Hub chat-path routing algorithm in force ('auto' | 'split' | 'pin1' | 'pin2'). */
  routeAlgorithm: string;
  routeOptions: RouteChoiceView[];
}

export interface ModelChoiceView {
  name: string;
  vision: boolean;
}

export interface RouteChoiceView {
  name: string;
  label: string;
}

export interface PageEvent {
  kind: string;
  text: string;
  error?: boolean;
  available?: boolean;
  connectLabel?: string;
  connecting?: boolean;
  pendingText?: string;
  requestId?: string;
  running?: number;
  selfLabel?: string;
  devices?: DeviceView[];
  jobs?: JobView[];
  /** Hub-observed forwarded calls, available in task details only. */
  remoteCalls?: JobView[];
  queuedCalls?: JobView[];
  flowCalls?: JobView[];
  groups?: TaskGroupView[];
  modelSettings?: ModelSettingsView;
  /** Cumulative local completions. microYuan is 1 yuan = 1_000_000. */
  usage?: UsageView;
}

export interface UsageView {
  tasks: number;
  tokens: number;
  microYuan: number;
}

export interface DeviceView {
  epoch: number;
  name: string;
  id: string;
  ready: boolean;
  jobs: number;
  role?: string;
  model?: string;
  memUsage?: number;
  thermalLevel?: number;
  batteryTemp?: number;
  cpuUsage?: number;
  modelRequests?: number;
  /** Model capabilities of this device, e.g. ['text', 'vision']; absent means text-only. */
  capabilities?: string[];
  /** Serving channel of this device's text model ('云侧'/'端侧', or '分档·档位·侧别模型' under xrouter); only the self entry carries it. */
  backend?: string;
  /** Highest model-strength tier this device's manifests declare, 1-2 (1 weak, 2 strong); absent = 2 strong. */
  modelTier?: number;
}

export interface JobView {
  kind?: string;
  phase?: string;
  phaseStartedAt?: number;
  originId?: string;
  executorId?: string;
  metrics?: InferenceMetrics;
  input?: string;
  groupKey?: string;
  subtaskId?: string;
  id: string;
  /** Stable board identity: origin epoch + wire request id. Never sent on the wire. */
  key: string;
  source: string;
  origin: string;
  local?: boolean;
  image?: string;
  question: string;
  answer: string;
  chars: number;
  startedAt: number;
  firstAt: number;
  endedAt: number;
  running: boolean;
  error: boolean;
  elapsedMs: number;
}

export interface ActiveJob {
  kind?: string;
  phase?: string;
  phaseStartedAt?: number;
  originId?: string;
  executorId?: string;
  metrics?: InferenceMetrics;
  input?: string;
  taskId?: string;
  subtaskId?: string;
  id: string;
  /** Stable board identity: origin epoch + wire request id. Never sent on the wire. */
  key: string;
  /** Origin session that asked for this job; 0 for work this device started. */
  epoch: number;
  peer: boolean;
  answer: string;
  question: string;
  startedAt: number;
  firstAt: number;
  endedAt: number;
  error: boolean;
  source: string;
  origin: string;
  workerEpoch: number;
  image: string;
  /** Experiment route that scheduled this job; empty for ordinary traffic. */
  routeMode: string;
  /** Task tier (1-2: 1 simple, 2 complex) the hub classified this job into; 0 = not classified. */
  taskTier?: number;
}
