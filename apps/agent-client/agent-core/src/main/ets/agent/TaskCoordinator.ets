import { TaskGoal, TaskEvidence, checkTaskAnswer, parseTaskGoals } from './TaskContract';
import { ToolMetadata } from './AgentTool';

export interface TaskNode { id: string; goalIds: string[]; dependsOn: string[]; }
export interface TaskGraph { goals: TaskGoal[]; nodes: TaskNode[]; }
export type WorkerStatus = 'success' | 'failed' | 'cancelled' | 'blocked';
export interface WorkerRequest {
  taskId: string; subtaskId: string; attemptId: string;
  goals: TaskGoal[]; dependencies: WorkerResult[];
}
export interface WorkerResult {
  taskId: string; subtaskId: string; attemptId: string; workerId: string;
  status: WorkerStatus; text: string; evidence: TaskEvidence[];
}
export interface TaskWorker {
  id: string; capacity: number;
  supports(request: WorkerRequest): boolean;
  execute(request: WorkerRequest): Promise<WorkerResult>;
  cancel(attemptId: string): void;
}
export interface TaskAggregator {
  // Return the same generic Final answers JSON used by a single-device worker.
  complete(taskId: string, graph: TaskGraph, results: WorkerResult[], evidence: TaskEvidence[]): Promise<string>;
  cancel(taskId: string): void;
}
export interface CoordinatorResult {
  taskId: string; status: 'success' | 'partial' | 'cancelled'; answer: string; results: WorkerResult[];
}
interface ActiveJob { worker: TaskWorker; request: WorkerRequest; settle: (result: WorkerResult) => void; }
interface AggregateOutcome { text: string; error: string; }
export function graphNodeMayParallel(node: TaskNode, goals: TaskGoal[], metadata: (name: string) => ToolMetadata): boolean {
  try {
    return node.goalIds.every((id: string): boolean => {
      const goal = goals.find((item: TaskGoal): boolean => item.id === id);
      return goal !== undefined && goal.tools.every((name: string): boolean => {
        const declared = metadata(name); return declared.readOnly === true && declared.risk === 'low';
      });
    });
  } catch (_error) { return false; }
}

export function validateTaskGraph(graph: TaskGraph): string[] {
  if (!graph || !Array.isArray(graph.goals) || !graph.goals.length || !Array.isArray(graph.nodes) || !graph.nodes.length || graph.nodes.length > 32) { return ['Invalid/empty task graph']; }
  if (parseTaskGoals(graph.goals, (_name: string): boolean => true).error.length > 0) { return ['Invalid goal declarations']; }
  const ids: string[] = [], assigned: string[] = [];
  for (const node of graph.nodes) {
    if (!node || Object.keys(node).some((key: string): boolean => ['id', 'goalIds', 'dependsOn'].indexOf(key) < 0) || typeof node.id !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(node.id) || ids.indexOf(node.id) >= 0 ||
      !Array.isArray(node.goalIds) || !node.goalIds.length || !Array.isArray(node.dependsOn)) { return ['Invalid/duplicate subtask']; }
    ids.push(node.id);
    for (const goal of node.goalIds) { if (!graph.goals.some((entry: TaskGoal): boolean => entry.id === goal) || assigned.indexOf(goal) >= 0) { return ['Unknown/duplicate assigned goal']; } assigned.push(goal); }
  }
  if (graph.goals.some((goal: TaskGoal): boolean => assigned.indexOf(goal.id) < 0)) { return ['Every goal must belong to exactly one subtask']; }
  const done: string[] = [];
  for (const node of graph.nodes) {
    if (node.dependsOn.some((dep: string, index: number): boolean => dep === node.id || ids.indexOf(dep) < 0 || node.dependsOn.indexOf(dep) !== index)) { return ['Invalid dependency']; }
  }
  for (let count = 0; count < graph.nodes.length; count++) {
    const next = graph.nodes.find((node: TaskNode): boolean => done.indexOf(node.id) < 0 && node.dependsOn.every((dep: string): boolean => done.indexOf(dep) >= 0));
    if (next === undefined) { return ['Cyclic task dependencies']; }
    done.push(next.id);
  }
  return [];
}

// Transport-independent scheduler. Each worker owns its own model/tool session.
// Model declarations cannot grant parallelism; the caller supplies trusted policy.
export class TaskCoordinator {
  private running: boolean = false;
  private cancelled: boolean = false;
  private runSerial: number = 0;
  private active: Map<string, ActiveJob> = new Map();
  private cancelAggregate: (() => void) | null = null;
  private maxParallel: number;
  private deadlineMs: number;
  constructor(maxParallel: number = 1, deadlineMs: number = 60000) {
    if (!Number.isInteger(maxParallel) || maxParallel < 1 || maxParallel > 8 || !Number.isInteger(deadlineMs) || deadlineMs < 1 || deadlineMs > 300000) { throw new Error('Invalid coordinator limits'); }
    this.maxParallel = maxParallel; this.deadlineMs = deadlineMs;
  }
  requestStop(): void {
    this.cancelled = true;
    for (const job of Array.from(this.active.values())) {
      job.settle(this.failure(job.request, job.worker.id, 'cancelled', '任务已停止'));
      try { job.worker.cancel(job.request.attemptId); } catch (_error) {}
    }
    this.cancelAggregate?.();
  }
  private failure(request: WorkerRequest, workerId: string, status: WorkerStatus, text: string): WorkerResult {
    return { taskId: request.taskId, subtaskId: request.subtaskId, attemptId: request.attemptId, workerId: workerId, status: status, text: text, evidence: [] };
  }
  private invoke(worker: TaskWorker, request: WorkerRequest): Promise<WorkerResult> {
    return new Promise<WorkerResult>((resolve: (value: WorkerResult) => void): void => {
      let settled = false, timer = -1;
      const settle = (result: WorkerResult): void => { if (settled) { return; } settled = true; clearTimeout(timer); this.active.delete(request.attemptId); resolve(result); };
      this.active.set(request.attemptId, { worker: worker, request: request, settle: settle });
      timer = setTimeout((): void => {
        settle(this.failure(request, worker.id, 'failed', 'Worker 超时；没有自动重放可能产生副作用的操作。'));
        try { worker.cancel(request.attemptId); } catch (_error) {}
      }, this.deadlineMs);
      Promise.resolve().then((): Promise<WorkerResult> => {
        if (settled) { return Promise.reject(new Error('Already stopped')); }
        return worker.execute(JSON.parse(JSON.stringify(request)) as WorkerRequest);
      }).then((result: WorkerResult): void => {
        if (settled) { return; }
        if (!result || result.taskId !== request.taskId || result.subtaskId !== request.subtaskId || result.attemptId !== request.attemptId || result.workerId !== worker.id ||
          ['success', 'failed', 'cancelled', 'blocked'].indexOf(result.status) < 0 || typeof result.text !== 'string' || !Array.isArray(result.evidence)) {
          settle(this.failure(request, worker.id, 'failed', 'Worker 返回的任务身份或结果无效')); return;
        }
        const ids: string[] = [], allowed = request.goals.reduce((all: string[], goal: TaskGoal): string[] => all.concat(goal.tools), []);
        for (const item of result.evidence) {
          if (!item || typeof item.callId !== 'string' || !item.callId.startsWith(request.attemptId + '/') || ids.indexOf(item.callId) >= 0 ||
            allowed.indexOf(item.tool) < 0 || ['success', 'failed', 'empty', 'unavailable'].indexOf(item.status) < 0 || typeof item.output !== 'string' || item.output.length > 32768 ||
            item.facts !== undefined && typeof item.facts !== 'string' || item.source !== undefined && item.source !== 'tool' ||
            item.goalIds !== undefined && (!Array.isArray(item.goalIds) || item.goalIds.some((id: string): boolean => !request.goals.some((goal: TaskGoal): boolean => goal.id === id)))) {
            settle(this.failure(request, worker.id, 'failed', 'Worker 证据越界或重复')); return;
          }
          ids.push(item.callId);
        }
        try { settle(JSON.parse(JSON.stringify(result)) as WorkerResult); }
        catch (_error) { settle(this.failure(request, worker.id, 'failed', 'Worker 结果不可序列化')); }
      }, (error: Error): void => settle(this.failure(request, worker.id, 'failed', error instanceof Error ? error.message : String(error))));
    });
  }
  private aggregate(taskId: string, graph: TaskGraph, results: WorkerResult[], evidence: TaskEvidence[], aggregator: TaskAggregator): Promise<AggregateOutcome> {
    return new Promise<AggregateOutcome>((resolve: (value: AggregateOutcome) => void): void => {
      let settled = false, timer = -1;
      const finish = (text: string, error: string): void => { if (settled) { return; } settled = true; clearTimeout(timer); this.cancelAggregate = null; resolve({ text: text, error: error }); };
      this.cancelAggregate = (): void => { finish('', '综合已停止'); try { aggregator.cancel(taskId); } catch (_error) {} };
      timer = setTimeout((): void => { finish('', '综合超时'); try { aggregator.cancel(taskId); } catch (_error) {} }, this.deadlineMs);
      Promise.resolve().then((): Promise<string> => aggregator.complete(taskId, JSON.parse(JSON.stringify(graph)) as TaskGraph, JSON.parse(JSON.stringify(results)) as WorkerResult[], JSON.parse(JSON.stringify(evidence)) as TaskEvidence[]))
        .then((text: string): void => finish(text, ''), (error: Error): void => finish('', error instanceof Error ? error.message : String(error)));
    });
  }
  async run(taskId: string, graph: TaskGraph, workers: TaskWorker[], parallelSafe: (node: TaskNode) => boolean, aggregator: TaskAggregator): Promise<CoordinatorResult> {
    if (this.running) { throw new Error('Coordinator already running'); }
    const errors = validateTaskGraph(graph);
    if (!taskId.length || errors.length) { throw new Error(errors.join('; ') || 'Missing taskId'); }
    graph = JSON.parse(JSON.stringify(graph)) as TaskGraph;
    const workerIds: string[] = [];
    for (const worker of workers) {
      if (!worker.id || workerIds.indexOf(worker.id) >= 0 || !Number.isInteger(worker.capacity) || worker.capacity < 1 || worker.capacity > 8) { throw new Error('Invalid worker capacity/identity'); }
      workerIds.push(worker.id);
    }
    this.running = true; this.cancelled = false;
    const pending: Map<string, TaskNode> = new Map(), outcomes: Map<string, WorkerResult> = new Map(), busy: Map<string, number> = new Map(), jobs: Map<string, Promise<void>> = new Map(), safe: Map<string, boolean> = new Map();
    for (const node of graph.nodes) { pending.set(node.id, node); try { safe.set(node.id, parallelSafe(node) === true); } catch (_error) { safe.set(node.id, false); } }
    const generation = ++this.runSerial;
    let sequence = 0;
    const requestFor = (node: TaskNode): WorkerRequest => ({ taskId: taskId, subtaskId: node.id, attemptId: taskId + '/' + node.id + '/' + generation.toString() + '-' + (++sequence).toString(),
      goals: graph.goals.filter((goal: TaskGoal): boolean => node.goalIds.indexOf(goal.id) >= 0), dependencies: node.dependsOn.map((id: string): WorkerResult => outcomes.get(id) as WorkerResult) });
    try {
      while (pending.size > 0 || jobs.size > 0) {
        if (this.cancelled) {
          for (const node of pending.values()) { outcomes.set(node.id, this.failure(requestFor(node), '', 'cancelled', '任务已停止')); }
          pending.clear(); if (jobs.size) { await Promise.all(Array.from(jobs.values())); } break;
        }
        let changed = false;
        for (const node of Array.from(pending.values())) {
          if (node.dependsOn.some((id: string): boolean => outcomes.has(id) && outcomes.get(id)?.status !== 'success')) {
            outcomes.set(node.id, this.failure(requestFor(node), '', 'blocked', '依赖子任务未成功')); pending.delete(node.id); changed = true; continue;
          }
          if (!node.dependsOn.every((id: string): boolean => outcomes.has(id)) || jobs.size >= this.maxParallel ||
            jobs.size > 0 && (!safe.get(node.id) || Array.from(jobs.keys()).some((id: string): boolean => !safe.get(id)))) { continue; }
          const request = requestFor(node);
          const worker = workers.find((candidate: TaskWorker): boolean => {
            try { return (busy.get(candidate.id) ?? 0) < candidate.capacity && candidate.supports(JSON.parse(JSON.stringify(request)) as WorkerRequest); } catch (_error) { return false; }
          });
          if (worker === undefined) { continue; }
          pending.delete(node.id); changed = true; busy.set(worker.id, (busy.get(worker.id) ?? 0) + 1);
          const promise = this.invoke(worker, request).then((result: WorkerResult): void => { outcomes.set(node.id, result); busy.set(worker.id, (busy.get(worker.id) ?? 1) - 1); jobs.delete(node.id); });
          jobs.set(node.id, promise);
        }
        if (jobs.size > 0) { await Promise.race(Array.from(jobs.values())); }
        else if (!changed && pending.size > 0) {
          for (const node of Array.from(pending.values()).filter((entry: TaskNode): boolean => entry.dependsOn.every((id: string): boolean => outcomes.has(id)))) {
            outcomes.set(node.id, this.failure(requestFor(node), '', 'failed', '没有具备能力的可用 Worker')); pending.delete(node.id);
          }
        }
      }
      const results = graph.nodes.map((node: TaskNode): WorkerResult => outcomes.get(node.id) as WorkerResult);
      if (this.cancelled) { return { taskId: taskId, status: 'cancelled', answer: '已停止任务', results: results }; }
      const evidence: TaskEvidence[] = [];
      for (const result of results) {
        const node = graph.nodes.find((item: TaskNode): boolean => item.id === result.subtaskId) as TaskNode;
        for (const item of result.evidence) {
          const accessible: string[] = node.goalIds.slice(), seen: string[] = [node.id];
          for (let pass = 0; pass < graph.nodes.length; pass++) {
            for (const dependent of graph.nodes) {
              if (seen.indexOf(dependent.id) < 0 && dependent.dependsOn.some((id: string): boolean => seen.indexOf(id) >= 0)) { seen.push(dependent.id); accessible.push(...dependent.goalIds); }
            }
          }
          evidence.push({ callId: item.callId, tool: item.tool, status: item.status, output: item.output, facts: item.facts, input: item.input,
            goalIds: graph.goals.filter((goal: TaskGoal): boolean => accessible.indexOf(goal.id) >= 0 && goal.tools.indexOf(item.tool) >= 0).map((goal: TaskGoal): string => goal.id) });
        }
        if (result.status !== 'success') {
          const node = graph.nodes.find((item: TaskNode): boolean => item.id === result.subtaskId) as TaskNode;
          evidence.push({ callId: result.attemptId + '/control', tool: '', status: 'unavailable', output: result.text, source: 'worker', goalIds: node.goalIds });
        }
      }
      const combined = await this.aggregate(taskId, graph, results, evidence, aggregator);
      if (this.cancelled) { return { taskId: taskId, status: 'cancelled', answer: '已停止任务', results: results }; }
      const checked = checkTaskAnswer(graph.goals, combined.text, evidence);
      const incomplete = combined.error.length > 0 || checked.issues.length > 0;
      const answer = incomplete ? '综合未完成：' + (combined.error || checked.issues.join('；')) + '\n\n' + results.map((result: WorkerResult): string => result.subtaskId + ' [' + result.status + ']：' + result.text).join('\n\n') : checked.text;
      return { taskId: taskId, status: !incomplete && checked.complete === true && results.every((result: WorkerResult): boolean => result.status === 'success') ? 'success' : 'partial', answer: answer, results: results };
    } finally { this.running = false; }
  }
}
