import { LocalModel } from '../model/LocalModel';
import { ToolRegistry } from './ToolRegistry';
import { AgentEvent, AgentEventKind } from './AgentEvent';
import { ReActAgentRunner } from './ReActAgentRunner';
import { TaskEvidence, TaskGoal } from './TaskContract';
import { TaskWorker, WorkerRequest, WorkerResult } from './TaskCoordinator';
export interface WorkerSession { model: LocalModel; tools: ToolRegistry; prompt: string; maxPromptBytes: () => number; }
export type WorkerSessionFactory = (request: WorkerRequest) => Promise<WorkerSession>;
// The factory must create an isolated model/tool session for this attempt.
// A transport with one pending request must advertise only one worker/capacity.
export class ReActTaskWorker implements TaskWorker {
  private runners: Map<string, ReActAgentRunner> = new Map();
  private cancelled: Set<string> = new Set();
  private attempts: Set<string> = new Set();
  id: string;
  capacity: number;
  private factory: WorkerSessionFactory;
  private capability: (request: WorkerRequest) => boolean;
  constructor(id: string, capacity: number, factory: WorkerSessionFactory, capability: (request: WorkerRequest) => boolean) {
    this.id = id; this.capacity = capacity; this.factory = factory; this.capability = capability;
  }
  supports(request: WorkerRequest): boolean { return this.attempts.size < this.capacity && this.capability(request); }
  cancel(attemptId: string): void { if (this.attempts.has(attemptId)) { this.cancelled.add(attemptId); this.runners.get(attemptId)?.requestStop(); } }
  async execute(request: WorkerRequest): Promise<WorkerResult> {
    if (request.dependencies.some((result: WorkerResult): boolean => result.taskId !== request.taskId || result.status !== 'success' ||
      result.evidence.some((entry: TaskEvidence): boolean => !entry.callId.startsWith(result.attemptId + '/')))) { throw new Error('Dependency evidence belongs to another task/attempt'); }
    if (this.attempts.size >= this.capacity) { throw new Error('Worker session capacity exceeded'); }
    this.attempts.add(request.attemptId);
    let session: WorkerSession | undefined;
    let text = '';
    const dependencies: TaskEvidence[] = [];
    for (const result of request.dependencies) {
      for (const entry of result.evidence) {
        dependencies.push({ callId: entry.callId, tool: entry.tool, status: entry.status, output: entry.output, facts: entry.facts, input: entry.input,
          goalIds: request.goals.filter((goal: TaskGoal): boolean => goal.tools.indexOf(entry.tool) >= 0).map((goal: TaskGoal): string => goal.id) });
      }
    }
    try {
      session = await this.factory(request);
      const runner = new ReActAgentRunner(session.model, session.tools, 12, undefined, false, false, false, session.maxPromptBytes, true);
      this.runners.set(request.attemptId, runner);
      if (this.cancelled.has(request.attemptId)) { runner.requestStop(); }
      await runner.run(session.prompt, (event: AgentEvent): void => {
        if (event.kind === AgentEventKind.FINAL || event.kind === AgentEventKind.ERROR && !event.callId) { text = event.text; }
      }, undefined, { namespace: request.attemptId, goals: request.goals, evidence: dependencies });
      return { taskId: request.taskId, subtaskId: request.subtaskId, attemptId: request.attemptId, workerId: this.id,
        status: this.cancelled.has(request.attemptId) ? 'cancelled' : runner.completed() ? 'success' : 'failed', text: text,
        evidence: runner.getEvidence().filter((entry: TaskEvidence): boolean => entry.callId.startsWith(request.attemptId + '/')) };
    } finally {
      this.runners.delete(request.attemptId); this.cancelled.delete(request.attemptId);
      try { await session?.tools.close(); } finally { this.attempts.delete(request.attemptId); }
    }
  }
}
