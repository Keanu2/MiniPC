/**
 * Measured inference speed per compute device, learned from finished requests.
 * Nothing is configured per device: a slower or busier device simply ends up with a higher
 * cost and receives work only when faster devices are busy. Cost is milliseconds per
 * 1000 characters of prompt plus answer, smoothed so one odd request does not flip placement.
 */

const ALPHA = 0.3;
/** Samples too short to say anything about speed (fixed overheads dominate). */
const MIN_CHARS = 400;
const MIN_MS = 1000;

export class DeviceSpeed {
  private costs: Map<number, number> = new Map();

  /** Records one finished request; failed or tiny ones are ignored. */
  record(epoch: number, elapsedMs: number, chars: number, failed: boolean): void {
    if (failed || chars < MIN_CHARS || elapsedMs < MIN_MS) return;
    const sample = elapsedMs * 1000 / chars;
    const old = this.costs.get(epoch);
    this.costs.set(epoch, old === undefined ? sample : old + ALPHA * (sample - old));
  }

  /** Smoothed ms per 1000 chars, or -1 when this device has not been measured yet. */
  cost(epoch: number): number {
    const value = this.costs.get(epoch);
    return value === undefined ? -1 : value;
  }
}
