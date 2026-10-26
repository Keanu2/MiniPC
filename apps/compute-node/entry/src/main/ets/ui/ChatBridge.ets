export class ChatBridge {
  private onSend: (text: string) => string;
  private onStop: () => void;
  private onConnect: () => void;
  private onPrepare: () => void;
  private onPick: () => void;
  private onClear: () => void;
  private onClearImage: () => void;
  private onSelectModel: (model: string) => string;
  private onModels: () => string;
  private onSetOutputMode: (mode: string) => string;
  constructor(send: (text: string) => string, stop: () => void, connect: () => void, prepare: () => void,
    pick: () => void, clear: () => void = (): void => {}, clearImage: () => void = (): void => {},
    selectModel: (model: string) => string = (): string => '当前设备不支持切换模型。',
    models: () => string = (): string => 'null',
    setOutputMode: (mode: string) => string = (): string => '当前设备不支持切换输出方式。') {
    this.onSend = send; this.onStop = stop; this.onConnect = connect; this.onPrepare = prepare; this.onPick = pick;
    this.onClear = clear;
    this.onClearImage = clearImage;
    this.onSelectModel = selectModel;
    this.onModels = models;
    this.onSetOutputMode = setOutputMode;
  }
  send(text: string): string { return this.onSend(text); }
  stop(): void { this.onStop(); }
  connect(): void { this.onConnect(); }
  prepare(): void { this.onPrepare(); }
  pickImage(): void { this.onPick(); }
  clear(): void { this.onClear(); }
  clearImage(): void { this.onClearImage(); }
  selectModel(model: string): string { return this.onSelectModel(model); }
  models(): string { return this.onModels(); }
  setOutputMode(mode: string): string { return this.onSetOutputMode(mode); }
}
