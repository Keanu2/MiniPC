import { ActiveJob } from './DashboardTypes';
import { TaskGroupView } from './TaskBoard';
import { TaskChildSnapshot } from '../protocol/ChatProtocol';
import { inferenceTaskText } from './InferencePresentation';

interface PlanItem { title?: string; task: string; }
interface ObservedRun {
  id: string;
  key: string;
  epoch: number;
  title: string;
  origin: string;
  executor: string;
  startedAt: number;
  items: PlanItem[];
  /** Children already proven by an exact task match; later ReAct rounds carry the same caption. */
  linked: boolean[];
  returned: boolean[];
  updatedAt: number;
  group?: TaskGroupView;
}
interface ObservedCall { run: ObservedRun; stage: string; index: number; }

/** A chat-side subtask times out after 4 minutes; a silent group well past that has lost its run. */
const STALE_GROUP_MS = 600000;

/** Compatibility display for chat clients that send purpose labels but no infer.task snapshots.
 * A group is created only from a real, valid split response, never from unrelated concurrent calls.
 * Model routing, prompts, retries and the chat-side execution flow are not changed.
 */
export class InferenceTaskObserver {
  private serial: number = 0;
  private runs: Map<number, ObservedRun> = new Map();
  private calls: Map<string, ObservedCall> = new Map();
  private groups: Map<string, TaskGroupView> = new Map();
  private authoritative: string[] = [];
  private declared: string[] = [];

  /**
   * A run whose parent id came from the chat request belongs to a client that sends its own
   * snapshots. Its observed group only bridges the gap locally: it carries this device's start
   * time and parsed title, so publishing it would lock other devices onto a parent the chat's
   * snapshot can never update.
   */
  provisional(key: string): boolean {
    return this.declared.includes(key);
  }

  /** Once structured state is available, the compatibility view must never resurface. */
  suppress(key: string): void {
    if (!this.authoritative.includes(key)) this.authoritative.push(key);
    if (this.authoritative.length > 128) this.authoritative.shift();
    this.declared = this.declared.filter((item: string): boolean => item !== key);
    this.groups.delete(key);
    for (const entry of this.runs) if (entry[1].key === key) this.runs.delete(entry[0]);
    for (const entry of this.calls) if (entry[1].run.key === key) this.calls.delete(entry[0]);
  }

  begin(job: ActiveJob, label: string, executor: string): void {
    if (job.taskId !== undefined && this.authoritative.includes(String(job.epoch) + ':' + job.taskId)) return;
    const input = job.input || '';
    const task = inferenceTaskText(input);
    if (label === '任务拆分') {
      if (task.length === 0) return;
      const previous = this.runs.get(job.epoch);
      if (previous?.group !== undefined && previous.group.endedAt === 0) {
        previous.group.phase = 'unknown'; previous.group.endedAt = Date.now();
      }
      const id = job.taskId || 'observed_' + Date.now().toString(36) + (++this.serial).toString(36);
      const key = String(job.epoch) + ':' + id;
      if (job.taskId !== undefined && !this.declared.includes(key)) {
        this.declared.push(key);
        if (this.declared.length > 128) this.declared.shift();
      }
      const run: ObservedRun = { id: id, key: key, epoch: job.epoch,
        title: task, origin: job.origin, executor: executor, startedAt: job.startedAt, items: [],
        linked: [], returned: [], updatedAt: Date.now() };
      this.runs.set(job.epoch, run);
      this.link(job, run, 'plan', -1);
      return;
    }
    const run = this.runs.get(job.epoch);
    if (run === undefined || run.group === undefined || run.group.endedAt > 0 ||
      (job.taskId !== undefined && job.taskId !== run.id)) return;
    const child = /^子任务\s+(\d+)\/(\d+)$/.exec(label);
    if (child !== null) {
      const index = Number(child[1]) - 1;
      if (Number(child[2]) !== run.items.length || index < 0 || index >= run.items.length) return;
      const exact = task.replace(/\s+/g, ' ').trim() === run.items[index].task.replace(/\s+/g, ' ').trim();
      const declared = job.taskId === run.id && job.subtaskId === 's' + String(index + 1);
      if (!exact && !declared && run.linked[index] !== true) return;
      run.linked[index] = true;
      const view = run.group.subtasks[index];
      view.device = job.source; view.phase = 'running'; view.detail = '推理中';
      if (view.startedAt === undefined) { view.startedAt = job.startedAt; }
      this.link(job, run, 'child', index);
    } else if (label === '合并结果' && (task === run.title || run.linked.some((value: boolean): boolean => value))) {
      // Unparsed sections leave child phases to be settled from returned calls at merge end.
      this.readReturnedResults(run, input);
      run.group.phase = 'merging';
      this.link(job, run, 'merge', -1);
    }
  }

  end(job: ActiveJob): void {
    const call = this.calls.get(job.key);
    if (call === undefined) return;
    this.calls.delete(job.key);
    const run = call.run;
    run.updatedAt = Date.now();
    if (call.stage === 'plan') {
      if (job.error || this.runs.get(job.epoch) !== run) return;
      const items = this.readPlan(job.answer, run.title);
      if (items === null) return;
      run.items = items;
      const children: TaskChildSnapshot[] = items.map((item: PlanItem, index: number): TaskChildSnapshot => ({
        id: 's' + String(index + 1), title: (item.title || item.task).substring(0, 80),
        device: '', phase: 'queued', detail: '等待分配' }));
      const group: TaskGroupView = { id: run.id, key: run.key, title: run.title, phase: 'running', revision: 1,
        startedAt: run.startedAt, endedAt: 0, subtasks: children, answer: '',
        origin: run.origin, executor: run.executor, originEpoch: run.epoch };
      run.group = group;
      this.groups.set(group.key, group);
      this.trim();
    } else if (run.group !== undefined && run.group.endedAt === 0) {
      run.group.revision++;
      if (call.stage === 'child') {
        if (!job.error) run.returned[call.index] = true;
        if (job.endedAt > 0) { run.group.subtasks[call.index].endedAt = job.endedAt; }
        run.group.subtasks[call.index].detail = job.error ? '本次推理失败，等待后续状态' : '推理已返回，等待后续步骤';
      } else if (call.stage === 'merge') {
        // The chat merges only after every child settled, so an unparsed child is final now.
        run.group.subtasks.forEach((child: TaskChildSnapshot, index: number): void => {
          if (child.phase !== 'queued' && child.phase !== 'running') return;
          child.phase = run.returned[index] === true ? 'done' : 'failed';
          child.detail = run.returned[index] === true ? '已返回' : '未取得结果';
        });
        run.group.phase = job.error ? 'partial' : (run.group.subtasks.every((child: TaskChildSnapshot): boolean => child.phase === 'done') ? 'done' : 'partial');
        run.group.endedAt = job.endedAt;
        run.group.answer = job.error ? '' : job.answer.substring(0, 4096);
      }
    }
  }

  views(): TaskGroupView[] {
    const now = Date.now();
    for (const run of this.runs.values()) {
      const group = run.group;
      if (group === undefined || group.endedAt > 0 || now - run.updatedAt < STALE_GROUP_MS) continue;
      if (Array.from(this.calls.values()).some((call: ObservedCall): boolean => call.run === run)) continue;
      group.phase = 'unknown'; group.endedAt = now;
    }
    return Array.from(this.groups.values());
  }

  disconnect(epoch: number): void {
    for (const group of this.groups.values()) {
      if (group.originEpoch !== epoch || group.endedAt > 0) continue;
      group.phase = 'cancelled'; group.endedAt = Date.now();
      for (const child of group.subtasks) if (child.phase === 'running' || child.phase === 'queued') child.phase = 'cancelled';
    }
    this.runs.delete(epoch);
    for (const entry of this.calls) if (entry[1].run.epoch === epoch) this.calls.delete(entry[0]);
  }

  clearFinished(): void {
    for (const group of this.groups.values()) if (group.endedAt > 0) this.groups.delete(group.key);
    for (const entry of this.runs) if (entry[1].group !== undefined && entry[1].group?.endedAt !== 0) this.runs.delete(entry[0]);
  }

  private link(job: ActiveJob, run: ObservedRun, stage: string, index: number): void {
    job.taskId = run.id; job.subtaskId = index >= 0 ? 's' + String(index + 1) : stage;
    run.updatedAt = Date.now();
    this.calls.set(job.key, { run: run, stage: stage, index: index });
  }

  private readPlan(text: string, original: string): PlanItem[] | null {
    const first = text.indexOf('['), last = text.lastIndexOf(']');
    if (first < 0 || last <= first) return null;
    let items: PlanItem[];
    try { items = JSON.parse(text.substring(first, last + 1)) as PlanItem[]; } catch (_error) { return null; }
    if (!Array.isArray(items) || items.length < 2 || items.length > 4) return null;
    const seen: string[] = [];
    for (const item of items) {
      if (item === null || typeof item !== 'object' || typeof item.task !== 'string') return null;
      const task = item.task.trim();
      if (task.length === 0 || task.length > 500 || task === original || seen.includes(task) ||
        /上一步|上一个任务|上述|以上结果|前一个任务|根据(?:子)?任务|第[一二三四1234]个(?:子)?任务|子任务\s*\d|结果(?:再|来)/.test(task)) return null;
      seen.push(task); item.task = task;
      item.title = typeof item.title === 'string' ? item.title.trim().substring(0, 20) : '';
    }
    return items;
  }

  private readReturnedResults(run: ObservedRun, input: string): boolean {
    if (run.group === undefined) return false;
    // Current prompts use English markdown sections; older chat builds sent bracketed Chinese headings.
    let pattern = /^### Subtask (\d+): (.+) \[(completed|partial|unfinished)\]\n/gm;
    let matches: RegExpExecArray[] = [];
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(input)) !== null) matches.push(match);
    if (matches.length === 0) {
      pattern = /【子任务(\d+)：([^｜\n]+)｜(已完成|部分完成|未完成)】\n/g;
      while ((match = pattern.exec(input)) !== null) matches.push(match);
    }
    if (matches.length !== run.items.length) return false;
    for (let index = 0; index < matches.length; index++) {
      const title = run.items[index].title || '子任务' + String(index + 1);
      if (Number(matches[index][1]) !== index + 1 || matches[index][2] !== title) return false;
    }
    for (let index = 0; index < matches.length; index++) {
      const start = matches[index].index + matches[index][0].length;
      const result = input.substring(start, index + 1 < matches.length ? matches[index + 1].index : input.length).trim();
      const child = run.group.subtasks[index];
      const label = matches[index][3];
      child.phase = label === 'completed' || label === '已完成' ? 'done' : (label === 'partial' || label === '部分完成' ? 'partial' : 'failed');
      child.result = result.substring(0, 2048); child.resultTruncated = result.length > 2048;
    }
    return true;
  }

  private trim(): void {
    const finished = this.views().filter((group: TaskGroupView): boolean => group.endedAt > 0)
      .sort((a: TaskGroupView, b: TaskGroupView): number => a.endedAt - b.endedAt);
    while (this.groups.size > 40 && finished.length > 0) { const group = finished.shift(); if (group !== undefined) this.groups.delete(group.key); }
  }
}
