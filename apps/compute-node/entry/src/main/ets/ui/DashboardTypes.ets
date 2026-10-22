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
}

export interface JobView {
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
}
