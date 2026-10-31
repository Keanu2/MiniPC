import { common } from '@kit.AbilityKit';
import {
  AgentEvent, AgentEventKind, ConversationContext, createConfiguredLoopToolRegistry, createSkillSnapshot,
  LocalModel, PARTIAL_FINAL_STATUS, ParallelDeps, ParallelObserver, ParallelTaskRunner, ParallelTaskSnapshot,
  ReActAgentRunner, SkillSnapshot, SubtaskModelHooks, SubtaskView, ToolRegistry
} from '@loop/agent-core';
import { inferenceClient, InferHooks, INFERENCE_STOPPED } from './InferenceClient';
import { RemoteComputeModel } from './RemoteComputeModel';
import { TaskReporter } from './TaskReporter';
import { TaskProgressPhase } from './TaskProgress';
import { TaskSnapshot } from '../protocol/ChatProtocol';
import { ChatMode } from './ChatModeStore';
import { buildPlainChatPrompt } from './PlainChat';

export interface ChatTaskInput {
  id: string; task: string; display: string; imagePayload: string; mode: ChatMode;
  context: common.UIAbilityContext; conversation: ConversationContext;
}
export interface ChatTaskUpdate {
  phase: TaskProgressPhase; status: string; answer: string; process: string; device: string;
  startedAt: number; endedAt: number;
}
/** Every submission owns its model hooks, tools, cancellation and output state. */
export class ConcurrentChatTask {
  private input: ChatTaskInput;
  private ready: () => Promise<boolean>;
  private observe: (state: ChatTaskUpdate) => void;
  private cancelled: boolean = false;
  private finished: boolean = false;
  private started: boolean = false;
  private stopWake: () => void = (): void => {};
  private stopped: Promise<void>;
  private owners: Set<string> = new Set<string>();
  private runner: ReActAgentRunner | null = null;
  private parallel: ParallelTaskRunner | null = null;
  private tools: ToolRegistry | null = null;
  private reporter: TaskReporter | null = null;
  private views: SubtaskView[] = [];
  private state: ChatTaskUpdate = { phase: 'preparing', status: '正在准备发送', answer: '', process: '', device: '', startedAt: 0, endedAt: 0 };
  constructor(input: ChatTaskInput, ready: () => Promise<boolean>, observe: (state: ChatTaskUpdate) => void) {
    this.input = input; this.ready = ready; this.observe = observe;
    this.stopped = new Promise<void>((resolve: () => void): void => { this.stopWake = resolve; });
  }
  private active(): boolean { return !this.cancelled && !this.finished; }
  private publish(): void {
    const copy: ChatTaskUpdate = { phase: this.state.phase, status: this.state.status, answer: this.state.answer,
      process: this.state.process, device: this.state.device, startedAt: this.state.startedAt, endedAt: this.state.endedAt };
    try { this.observe(copy); } catch (_error) { /* UI observers cannot fail execution. */ }
  }
  private finish(phase: TaskProgressPhase, answer: string): void {
    if (this.finished) { return; }
    this.finished = true; this.state.phase = phase; this.state.answer = answer;
    this.state.endedAt = Date.now();
    if (this.state.startedAt === 0) { this.state.startedAt = this.state.endedAt; }
    this.reporter?.finish(phase, answer); this.publish();
  }
  cancel(): void {
    if (this.finished) { return; }
    this.cancelled = true;
    this.runner?.requestStop(); this.parallel?.requestStop();
    for (const owner of this.owners) { inferenceClient.cancelOwner(owner); }
    this.finish('cancelled', this.state.answer.length > 0 ? this.state.answer + '\n\n' + INFERENCE_STOPPED : INFERENCE_STOPPED);
    this.stopWake();
  }
  private async wait<T>(promise: Promise<T>): Promise<T> {
    if (this.cancelled) { throw new Error(INFERENCE_STOPPED); }
    return await Promise.race([promise, this.stopped.then((): T => { throw new Error(INFERENCE_STOPPED); })]);
  }
  private owner(name: string): string {
    const value = this.input.id + ':' + name; this.owners.add(value); return value;
  }
  private hooks(name: string, label: string, subtaskId: string): InferHooks {
    return {
      owner: this.owner(name), taskId: this.input.id, subtaskId: subtaskId, label: label,
      onAccepted: (device: string): void => { if (this.active()) { this.state.device = device; this.publish(); } },
      onStart: (): void => { if (this.active()) { this.state.status = '正在生成…'; this.publish(); } },
      onPhase: (phase: string): void => {
        if (!this.active()) { return; }
        this.state.status = phase === 'queued' ? '排队中…' : phase === 'prefill' ? '正在理解问题…' : '正在生成…'; this.publish();
      },
      onDelta: (text: string): void => { if (this.active()) { this.state.answer = text; this.publish(); } }
    };
  }
  private process(event: AgentEvent): void {
    if (!this.active()) { return; }
    if (event.kind === AgentEventKind.ACTION || event.kind === AgentEventKind.OBSERVATION) {
      this.reporter?.record(event.kind, event.text, event.toolName, event.input);
    }
    this.state.process = (this.state.process + '\n' + (event.toolName ? event.toolName + ': ' : '') + event.text).slice(-8192);
    this.state.status = event.kind === AgentEventKind.ACTION ? '正在调用工具：' + (event.toolName || '工具') :
      event.kind === AgentEventKind.OBSERVATION ? '正在整理工具结果…' : this.state.status;
    this.publish();
  }
  private createParallel(tools: ToolRegistry, skills: SkillSnapshot): ParallelTaskRunner {
    const deps: ParallelDeps = {
      modelFor: (id: string, hooks: SubtaskModelHooks): LocalModel => new RemoteComputeModel({
        owner: this.owner('child:' + id), taskId: hooks.taskId, subtaskId: hooks.subtaskId,
        label: hooks.label, onAccepted: hooks.onAccepted }),
      splitModel: (taskId?: string): LocalModel => new RemoteComputeModel({ owner: this.owner('split'), label: '任务拆分', taskId: taskId, subtaskId: 'plan' }),
      mergeModel: (taskId?: string): LocalModel => new RemoteComputeModel({ owner: this.owner('merge'), label: '合并结果', taskId: taskId, subtaskId: 'merge' }),
      tools: tools, skills: skills, maxSteps: 10, maxPromptBytes: (): number => inferenceClient.promptBudgetBytes(),
      load: () => inferenceClient.clusterLoad()
    };
    return new ParallelTaskRunner(deps);
  }
  private parallelObserver(): ParallelObserver {
    return {
      onTask: (task: ParallelTaskSnapshot): void => {
        if (this.active()) { this.reporter?.update({ id: task.id, title: task.title, phase: task.phase,
          revision: task.revision, startedAt: task.startedAt, endedAt: task.endedAt, answer: task.answer,
          answerTruncated: task.answerTruncated, subtasks: task.subtasks }); }
      },
      onPhase: (text: string): void => { if (this.active()) { this.state.status = text; this.publish(); } },
      onPlan: (views: SubtaskView[]): void => { if (this.active()) { this.views = views; this.renderParallel(); } },
      onUpdate: (view: SubtaskView): void => {
        if (this.active()) { this.views = this.views.map((item: SubtaskView): SubtaskView => item.id === view.id ? view : item); this.renderParallel(); }
      },
      onProcess: (event: AgentEvent): void => this.process(event)
    };
  }
  private renderParallel(): void {
    this.state.process = this.views.map((view: SubtaskView): string => view.title + ' · ' + view.device + ' · ' + view.detail).join('\n');
    this.publish();
  }
  async run(): Promise<void> {
    if (this.started || this.finished) { return; }
    this.started = true; this.state.startedAt = Date.now(); this.publish();
    try {
      if (!await this.wait(this.ready())) { throw new Error('算力未就绪，请检查连接后重试'); }
      if (!this.active()) { return; }
      this.reporter = new TaskReporter(this.input.id, this.input.task, this.state.startedAt,
        (snapshot: TaskSnapshot): void => inferenceClient.publishTask(snapshot));
      this.state.phase = 'running'; this.state.status = '正在生成…'; this.publish();
      if (this.input.mode === 'chat') {
        const prompt = buildPlainChatPrompt(this.input.task, inferenceClient.promptBudgetBytes());
        const answer = await this.wait(inferenceClient.complete(prompt, this.hooks('main', this.input.display.substring(0, 64), 'main'), null, this.input.imagePayload));
        if (!this.active()) { return; }
        if (answer.trim().length === 0) { throw new Error('算力未返回回答，请重试'); }
        this.finish('done', answer); return;
      }
      const skills = await this.wait(createSkillSnapshot(this.input.context));
      if (!this.active()) { return; }
      const pendingTools = createConfiguredLoopToolRegistry(this.input.context, skills);
      pendingTools.then((tools: ToolRegistry): void => {
        if (!this.active()) { tools.close().catch((_error: Error): void => {}); }
      }).catch((_error: Error): void => {});
      this.tools = await this.wait(pendingTools);
      if (!this.active()) { return; }
      const model = new RemoteComputeModel(this.hooks('main', this.input.display.substring(0, 64), 'main'));
      if (this.input.imagePayload.length > 0) { model.setImage(this.input.imagePayload); }
      this.runner = new ReActAgentRunner(model, this.tools, 10, skills, true, false, true,
        (): number => inferenceClient.promptBudgetBytes(), false, true);
      let finalAnswer: string | null = null, partial = false, failure = '';
      const listener = (event: AgentEvent): void => {
        if (!this.active()) { return; }
        if (event.kind === AgentEventKind.FINAL) {
          if (finalAnswer === null) { finalAnswer = event.text; partial = event.status === PARTIAL_FINAL_STATUS; this.state.answer = event.text; this.publish(); }
        } else if (event.kind === AgentEventKind.ERROR) { failure = event.text; this.process(event); }
        else { this.process(event); }
      };
      let handled = false;
      if (this.input.mode === 'agent_split' && this.input.imagePayload.length === 0) {
        this.parallel = this.createParallel(this.tools, skills);
        handled = await this.wait(this.parallel.tryRun(this.input.task, this.input.conversation, this.parallelObserver(), listener,
          this.state.startedAt + 300000, this.input.id));
      }
      if (!handled && this.active()) {
        await this.wait(this.runner.run(this.input.task, listener, this.input.conversation,
          { namespace: this.input.id, goals: [], evidence: [], deadlineAt: this.state.startedAt + 300000 }));
      }
      if (this.active()) {
        if (finalAnswer === null) { throw new Error(failure || '任务未返回完整回答'); }
        this.finish(partial ? 'partial' : 'done', finalAnswer);
      }
    } catch (error) {
      if (!this.finished) { this.finish(this.cancelled ? 'cancelled' : 'failed', error instanceof Error ? error.message : '任务执行失败'); }
    } finally {
      if (this.tools !== null) { await this.tools.close().catch((_error: Error): void => {}); this.tools = null; }
    }
  }
}
