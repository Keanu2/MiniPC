/**
 * Decides when a request may continue a native session instead of re-sending the whole
 * prompt. Each ReAct round re-sends the same system part and task, then appends tool
 * turns. If the system part and the task section are identical to an earlier request,
 * the session already holds them (and the model's reply), so only the new part is sent.
 *
 * Pure logic: the caller owns the native sessions and supplies `close` to drop one.
 */
export interface ReuseMessage { role: string; content: string; }

export class SessionPlan {
  /** Messages to submit: the full pair, or one user turn when the session is continued. */
  messages: ReuseMessage[] = [];
  /** Native session key; empty means "do not reuse, create and destroy as usual". */
  key: string = '';
  reused: boolean = false;
}

class Entry {
  key: string = '';
  system: string = '';
  scope: string = '';
  head: string = '';
  /** Length of the last user message sent; a continuation must be strictly longer. */
  lastLength: number = 0;
  inUse: boolean = false;
  lastUsed: number = 0;
}

const DATETIME_LINE = /(?:Current device local datetime: |当前设备本地时间：)[^\n]*\n?/;
// The task section ends where the controller starts appending tool turns / control lines.
const GROUP_START = /\n(?=(?:Control:|Action:|Execution:|Observation|Rejected response|Call \S+ tool=|Plan:|For:))/;

export function stableSystem(system: string): string {
  return system.replace(DATETIME_LINE, '').trim();
}

/** The part of the user message that every round of one run shares: "User task:\n<task>". */
export function taskHead(user: string): string {
  const first = user.indexOf('\n');
  if (first < 0) return user.trim();
  const rest = user.substring(first);
  const match = GROUP_START.exec(rest);
  // Blank lines between the task and the first appended group differ from round to round.
  return (match === null ? user : user.substring(0, first + match.index)).trim();
}

export class SessionReuse {
  private entries: Entry[] = [];
  private seq: number = 0;
  private limit: number;
  private close: (key: string) => void;
  private now: () => number;

  constructor(close: (key: string) => void, limit: number = 3, now: () => number = (): number => Date.now()) {
    this.close = close;
    this.limit = limit;
    this.now = now;
  }

  plan(messages: ReuseMessage[], scope: string = ''): SessionPlan {
    const plan = new SessionPlan();
    plan.messages = messages;
    if (messages.length !== 2 || messages[0].role !== 'developer' || messages[1].role !== 'user') {
      return plan;
    }
    const system = stableSystem(messages[0].content);
    const user = messages[1].content;
    const head = taskHead(user);
    if (system.length === 0 || head.length === 0) return plan;
    for (const entry of this.entries) {
      if (entry.scope !== scope || entry.system !== system || entry.head !== head) continue;
      if (entry.inUse) return plan;
      const delta = user.substring(head.length).trim();
      if (delta.length > 0 && user.length > entry.lastLength) {
        entry.inUse = true;
        entry.lastLength = user.length;
        entry.lastUsed = this.now();
        plan.messages = [{ role: 'user', content: delta }];
        plan.key = entry.key;
        plan.reused = true;
        return plan;
      }
      // Not an extension (a retry, or a new run with the same task): the session holds other turns. Start over.
      this.drop(entry);
      break;
    }
    const entry = new Entry();
    this.seq++;
    entry.key = 's' + this.seq.toString();
    entry.system = system;
    entry.scope = scope;
    entry.head = head;
    entry.lastLength = user.length;
    entry.inUse = true;
    entry.lastUsed = this.now();
    this.entries.push(entry);
    this.evict();
    plan.key = entry.key;
    return plan;
  }

  /** ok=false (error, cancel, empty reply) discards the session: its history is unreliable. */
  finish(plan: SessionPlan, ok: boolean): void {
    if (plan.key.length === 0) return;
    const entry = this.entries.find((item: Entry): boolean => item.key === plan.key);
    if (entry === undefined) return;
    entry.inUse = false;
    entry.lastUsed = this.now();
    if (!ok) this.drop(entry);
  }

  closeAll(): void {
    for (const entry of this.entries.slice()) this.drop(entry);
  }

  size(): number { return this.entries.length; }

  private drop(entry: Entry): void {
    const index = this.entries.indexOf(entry);
    if (index >= 0) this.entries.splice(index, 1);
    this.close(entry.key);
  }

  private evict(): void {
    while (this.entries.length > this.limit) {
      let oldest: Entry | undefined = undefined;
      for (const entry of this.entries) {
        if (entry.inUse) continue;
        if (oldest === undefined || entry.lastUsed < oldest.lastUsed) oldest = entry;
      }
      if (oldest === undefined) return;
      this.drop(oldest);
    }
  }
}
