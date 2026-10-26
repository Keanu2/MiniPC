import { TaskChildSnapshot, TaskSnapshot, WireMessage } from '../protocol/ChatProtocol';
import { TaskGroupView } from './TaskBoard';

interface DisplayTarget { epoch: number; signature: string; pending: boolean; failures: number; retry: number; }
const SEND_TIMEOUT_MS = 8000;
const RETRY_MS = 2000;
const MAX_FAILURES = 8;
interface DisplayRoute {
  id: string;
  revision: number;
  signature: string;
  targets: DisplayTarget[];
  published: boolean;
  message?: WireMessage;
}

/** Display state follows a task only to devices that actually received its calls. */
export class TaskDisplayRelay {
  private serial: number = 0;
  private routes: Map<string, DisplayRoute> = new Map();
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private readyEpochs: number[] = [];
  /** Optional diagnostics sink; display delivery never affects inference. */
  log: (text: string) => void = (_text: string): void => {};

  constructor(sender: (message: WireMessage, epoch: number) => Promise<boolean>) { this.sender = sender; }

  bind(key: string, childId: string, request: WireMessage, workerEpoch: number): void {
    let route = this.routes.get(key);
    if (route === undefined) {
      if (this.routes.size >= 64) return;
      route = { id: 'd' + Date.now().toString(36) + (++this.serial).toString(36), revision: 0,
        signature: '', targets: [], published: false };
      this.routes.set(key, route);
    }
    if (!route.targets.some((target: DisplayTarget): boolean => target.epoch === workerEpoch)) {
      route.targets.push({ epoch: workerEpoch, signature: '', pending: false, failures: 0, retry: -1 });
    }
    // The worker sees the hub's session, so namespace otherwise identical chat IDs.
    request.taskId = route.id;
    request.subtaskId = childId;
  }

  publish(groups: TaskGroupView[], readyWorkers: number[], retainedKeys: string[]): void {
    this.readyEpochs = readyWorkers;
    for (const entry of this.routes) {
      const route = entry[1];
      const group = groups.find((item: TaskGroupView): boolean => item.key === entry[0]);
      if (group === undefined) {
        if (route.published || !retainedKeys.includes(entry[0])) this.routes.delete(entry[0]);
        continue;
      }
      route.published = true;
      const signature = JSON.stringify(group);
      if (route.signature !== signature) { route.signature = signature; route.revision++; }
      const task: TaskSnapshot = { id: route.id, title: group.title, input: group.input, activity: group.activity, inputTruncated: group.inputTruncated,
        answerTruncated: group.answerTruncated, phase: group.phase, revision: route.revision,
        startedAt: group.startedAt, endedAt: group.endedAt, answer: group.answer,
        subtasks: group.subtasks.map((child: TaskChildSnapshot): TaskChildSnapshot => ({ id: child.id, title: child.title, input: child.input, activity: child.activity, device: child.device,
          phase: child.phase, detail: child.detail, result: child.result, resultTruncated: child.resultTruncated,
          startedAt: child.startedAt, endedAt: child.endedAt })) };
      const message: WireMessage = { type: 'infer.task', version: 2, requestId: task.id,
        task: task, origin: group.origin, source: group.executor };
      route.message = message;
      for (const target of route.targets) {
        if (!readyWorkers.includes(target.epoch) || target.pending || target.signature === signature) continue;
        this.deliver(route, target, message, signature);
      }
    }
  }

  /**
   * One snapshot at a time per worker. A send that fails, throws or never settles must not
   * stall the display: the timeout frees the slot and a retry timer re-sends the newest state
   * even if no later dashboard event arrives (the final snapshot has none after it).
   */
  private async deliver(route: DisplayRoute, target: DisplayTarget, message: WireMessage, signature: string): Promise<void> {
    target.pending = true;
    let sent = false;
    try {
      sent = await Promise.race([this.sender(message, target.epoch),
        new Promise<boolean>((resolve: (value: boolean) => void): void => { setTimeout((): void => resolve(false), SEND_TIMEOUT_MS); })]);
    } catch (_error) { sent = false; }
    target.pending = false;
    if (sent) {
      target.signature = signature;
      target.failures = 0;
    } else {
      target.failures++;
      this.log('task display send failed epoch=' + target.epoch.toString() + ' revision=' + route.revision.toString() +
        ' failures=' + target.failures.toString());
    }
    if (!Array.from(this.routes.values()).includes(route) || route.message === undefined) return;
    // A newer state may have arrived while the previous snapshot was sending.
    if (route.signature !== signature) {
      this.deliver(route, target, route.message, route.signature);
      return;
    }
    if (!sent && target.failures < MAX_FAILURES) this.scheduleRetry(route, target);
  }

  private scheduleRetry(route: DisplayRoute, target: DisplayTarget): void {
    if (target.retry >= 0) return;
    target.retry = setTimeout((): void => {
      target.retry = -1;
      if (target.pending || route.message === undefined || target.signature === route.signature) return;
      if (!this.readyEpochs.includes(target.epoch) || !Array.from(this.routes.values()).includes(route)) return;
      this.deliver(route, target, route.message, route.signature);
    }, RETRY_MS) as number;
  }
}
