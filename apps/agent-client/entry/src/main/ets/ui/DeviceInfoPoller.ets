import { WireMessage } from '../protocol/ChatProtocol';

/** Read-only device queries use the existing compute endpoint. No extra timer or unbounded sends. */
export class DeviceInfoPoller {
  private epoch: number = -1;
  private pendingId: string = '';
  private deadlineAt: number = 0;
  private nextAt: number = 0;
  private serial: number = 0;
  private send: (message: WireMessage, epoch: number) => Promise<boolean>;
  constructor(send: (message: WireMessage, epoch: number) => Promise<boolean>) { this.send = send; }
  clear(): void { this.epoch = -1; this.pendingId = ''; this.nextAt = 0; this.deadlineAt = 0; }
  acknowledge(message: WireMessage, epoch: number): void {
    if (message.type === 'deviceInfo' && epoch === this.epoch && message.requestId === this.pendingId) {
      this.pendingId = '';
    }
  }
  poll(epoch: number, now: number = Date.now()): void {
    if (epoch < 0) { this.clear(); return; }
    if (epoch !== this.epoch) { this.clear(); this.epoch = epoch; }
    if (now < this.nextAt || (this.pendingId.length > 0 && now < this.deadlineAt)) { return; }
    const id = 'tablet-info-' + epoch + '-' + (++this.serial);
    this.pendingId = id; this.nextAt = now + 5000; this.deadlineAt = now + 4000;
    try {
      this.send({ type: 'deviceInfo', requestId: id, capabilities: [] }, epoch).then((sent: boolean): void => {
        if (!sent && this.epoch === epoch && this.pendingId === id) { this.pendingId = ''; }
      }).catch((_error: Error): void => {
        if (this.epoch === epoch && this.pendingId === id) { this.pendingId = ''; }
      });
    } catch (_error) { if (this.pendingId === id) { this.pendingId = ''; } }
  }
}
