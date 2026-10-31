import { ConversationContext } from '@loop/agent-core';

interface TaskTurn { id: number; input: string; answer: string | null; settled: boolean; }
/** Complete pairs are kept in submission order, even if task 2 finishes before task 1. */
export class TaskConversationLedger {
  private base: ConversationContext;
  private turns: TaskTurn[] = [];
  constructor(base: ConversationContext) { this.base = ConversationContext.fromMessages(base.toChatMessages()); }
  reserve(id: number, input: string): void {
    if (!this.turns.some((turn: TaskTurn): boolean => turn.id === id)) { this.turns.push({ id: id, input: input, answer: null, settled: false }); }
  }
  finish(id: number, answer: string | null): ConversationContext {
    const turn = this.turns.find((item: TaskTurn): boolean => item.id === id);
    if (turn !== undefined && !turn.settled) { turn.answer = answer; turn.settled = true; }
    const conversation = this.snapshot();
    if (this.turns.every((item: TaskTurn): boolean => item.settled)) { this.base = conversation; this.turns = []; }
    return conversation;
  }
  snapshot(): ConversationContext {
    const conversation = ConversationContext.fromMessages(this.base.toChatMessages());
    for (const turn of this.turns) {
      if (turn.settled && turn.answer !== null) { conversation.addUser(turn.input); conversation.addAssistant(turn.answer); }
    }
    return conversation;
  }
}
