import { TaskChildSnapshot, TaskSnapshot, validTaskSnapshot } from '../protocol/ChatProtocol';

export interface TaskGroupView extends TaskSnapshot {
  key: string;
  origin: string;
  executor: string;
  originEpoch: number;
}

const QUIET_GROUP_MS = 600000;

/** A session-scoped display ledger, independent of model admission and routing. */
export class TaskBoard {
  private tasks: Map<string, TaskGroupView> = new Map();
  private cleared: string[] = [];
  private touched: Map<string, number> = new Map();

  accept(task: TaskSnapshot, epoch: number, origin: string, executor: string): boolean {
    if (!validTaskSnapshot(task)) return false;
    const key = String(epoch) + ':' + task.id;
    if (this.cleared.includes(key)) return false;
    const previous = this.tasks.get(key);
    // A group that went quiet and was marked unknown may still be revived by a newer revision.
    if (previous !== undefined && ((previous.endedAt > 0 && previous.phase !== 'unknown') || task.revision <= previous.revision ||
      previous.startedAt !== task.startedAt || previous.title !== task.title ||
      (previous.subtasks.length > 0 && (previous.subtasks.length !== task.subtasks.length || previous.subtasks.some((child, index) =>
        child.id !== task.subtasks[index].id || child.title !== task.subtasks[index].title))))) return false;
    if (previous === undefined && this.tasks.size >= 64) {
      const finished = Array.from(this.tasks.values()).filter((item: TaskGroupView): boolean => item.endedAt > 0)
        .sort((a: TaskGroupView, b: TaskGroupView): number => a.endedAt - b.endedAt);
      if (finished.length === 0) return false;
      this.forget(finished[0].key);
    }
    const subtasks: TaskChildSnapshot[] = [];
    for (const child of task.subtasks) {
      const copy: TaskChildSnapshot = {
        id: child.id, title: child.title, input: child.input, activity: child.activity, device: child.device, phase: child.phase,
        detail: child.detail, result: child.result, resultTruncated: child.resultTruncated,
        startedAt: child.startedAt, endedAt: child.endedAt
      };
      subtasks.push(copy);
    }
    const view: TaskGroupView = {
      id: task.id, title: task.title, input: task.input, activity: task.activity, inputTruncated: task.inputTruncated,
      answerTruncated: task.answerTruncated, phase: task.phase, revision: task.revision,
      startedAt: task.startedAt, endedAt: task.endedAt, answer: task.answer, subtasks: subtasks,
      key: key, originEpoch: epoch, origin: origin, executor: executor
    };
    this.tasks.set(key, view);
    this.touched.set(key, Date.now());
    return true;
  }

  views(): TaskGroupView[] {
    // A group that stops receiving updates (lost link, missed final snapshot) must not run forever.
    const now = Date.now();
    for (const task of this.tasks.values()) {
      if (task.endedAt > 0 || now - (this.touched.get(task.key) ?? now) < QUIET_GROUP_MS) continue;
      task.phase = 'unknown'; task.endedAt = now;
      for (const child of task.subtasks) {
        if (child.phase === 'running' || child.phase === 'queued') { child.phase = 'cancelled'; child.detail = '长时间没有收到更新'; }
      }
    }
    return Array.from(this.tasks.values()).sort((a: TaskGroupView, b: TaskGroupView): number => b.startedAt - a.startedAt);
  }

  clearFinished(): void {
    for (const task of this.views()) if (task.endedAt > 0) this.forget(task.key);
  }

  disconnect(epoch: number): void {
    for (const task of this.tasks.values()) {
      if (task.originEpoch !== epoch || task.endedAt > 0) continue;
      task.phase = 'cancelled'; task.endedAt = Date.now(); task.revision++;
      for (const child of task.subtasks) {
        if (child.phase === 'running' || child.phase === 'queued') { child.phase = 'cancelled'; child.detail = '发起设备已断开'; }
      }
    }
  }

  private forget(key: string): void {
    this.tasks.delete(key); this.touched.delete(key); this.cleared.push(key);
    if (this.cleared.length > 128) this.cleared.shift();
  }
}
