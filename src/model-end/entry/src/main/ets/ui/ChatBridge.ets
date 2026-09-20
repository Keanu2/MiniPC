export class ChatBridge {
  private onSend: (text: string) => string;
  private onStop: () => void;
  private onConnect: () => void;
  private onPrepare: () => void;
  private onPick: () => void;
  constructor(send: (text: string) => string, stop: () => void, connect: () => void, prepare: () => void,
    pick: () => void) {
    this.onSend = send; this.onStop = stop; this.onConnect = connect; this.onPrepare = prepare; this.onPick = pick;
  }
  send(text: string): string { return this.onSend(text); }
  stop(): void { this.onStop(); }
  connect(): void { this.onConnect(); }
  prepare(): void { this.onPrepare(); }
  pickImage(): void { this.onPick(); }
}
