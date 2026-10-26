import { TaskChildSnapshot, TaskSnapshot } from '../protocol/ChatProtocol';
import { utf8Bytes } from './InferenceWire';

/** One user request owns one display lifecycle, including split attempts and fallback. */
export class TaskReporter {
  readonly id: string;
  private state: TaskSnapshot;
  private send: (task: TaskSnapshot) => void;

  constructor(id: string, input: string, startedAt: number, send: (task: TaskSnapshot) => void) {
    this.id = id;
    this.send = send;
    this.state = { id: id, title: input.substring(0, 1000) || '图片请求', input: input.substring(0, 32768),
      inputTruncated: input.length > 32768, phase: 'running', revision: 0, startedAt: startedAt,
      endedAt: 0, answer: '', subtasks: [] };
    this.publish();
  }

  update(task: TaskSnapshot): void {
    if (this.state.endedAt > 0 || task.id !== this.id) return;
    this.state = { id: this.id, title: this.state.title, input: this.state.input,
      inputTruncated: this.state.inputTruncated, startedAt: this.state.startedAt,
      revision: this.state.revision, phase: task.phase, endedAt: task.endedAt,
      activity: this.state.activity, answer: task.answer, answerTruncated: task.answerTruncated, subtasks: task.subtasks };
    this.publish();
  }

  record(kind: string, text: string, tool: string = '', input: string = ''): void {
    if (this.state.endedAt > 0) return;
    this.state.activity = ((this.state.activity || '') + '\n[' + kind + '] ' + tool +
      (input ? '\n' + input : '') + '\n' + text).slice(-2048);
    this.publish();
  }

  finish(phase: string, answer: string = ''): void {
    if (this.state.endedAt > 0) return;
    this.state.phase = phase;
    this.state.endedAt = Math.max(this.state.startedAt, Date.now());
    this.state.answer = answer.substring(0, 4096);
    this.state.answerTruncated = answer.length > 4096;
    for (const child of this.state.subtasks) {
      if (child.phase === 'running' || child.phase === 'queued') {
        child.phase = phase === 'cancelled' ? 'cancelled' : 'failed';
        child.endedAt = this.state.endedAt;
      }
    }
    this.publish();
  }

  private publish(): void {
    this.state.revision++;
    // Never mutate a snapshot already queued for asynchronous transport.
    const copy: TaskSnapshot = { id: this.id, title: this.state.title, input: this.state.input,
      inputTruncated: this.state.inputTruncated, phase: this.state.phase, revision: this.state.revision,
      startedAt: this.state.startedAt, endedAt: this.state.endedAt, answer: this.state.answer,
      activity: this.state.activity, answerTruncated: this.state.answerTruncated,
      subtasks: this.state.subtasks.map((child: TaskChildSnapshot): TaskChildSnapshot => ({
        id: child.id, title: child.title, input: child.input, activity: child.activity,
        device: child.device, phase: child.phase, detail: child.detail,
        result: child.result, resultTruncated: child.resultTruncated,
        startedAt: child.startedAt, endedAt: child.endedAt
      })) };
    // Leave room for the wire envelope and hub namespace. Oversized display data
    // is explicitly shortened; it must never prevent the terminal state arriving.
    while (utf8Bytes(JSON.stringify(copy)).length > 56000) {
      if ((copy.input || '').length > 1000) {
        copy.input = copy.input?.substring(0, Math.floor(copy.input.length / 2));
        copy.inputTruncated = true;
      } else {
        copy.answer = copy.answer.substring(0, Math.floor(copy.answer.length / 2));
        copy.answerTruncated = true;
        if (copy.activity) copy.activity = copy.activity.slice(Math.floor(copy.activity.length / 2));
        for (const child of copy.subtasks) {
          if (child.activity) child.activity = child.activity.slice(Math.floor(child.activity.length / 2));
          if (child.result) {
            child.result = child.result.substring(0, Math.floor(child.result.length / 2));
            child.resultTruncated = true;
          }
        }
      }
    }
    try { this.send(copy); } catch (_error) { /* Display cannot fail inference. */ }
  }
}
