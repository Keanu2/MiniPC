import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** A continuous-task lease owned by live near-field connections, not the page's visibility. */
export class NearbyBackgroundTask {
  private context: common.UIAbilityContext | null = null;
  private activeContext: common.UIAbilityContext | null = null;
  private wanted: boolean = false;
  private queue: Promise<void> = Promise.resolve();

  initialize(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setWanted(wanted: boolean): void {
    if (wanted === this.wanted) return;
    this.wanted = wanted;
    this.sync();
  }

  retry(): void { this.sync(); }

  dispose(): void {
    this.wanted = false;
    this.context = null;
    this.sync();
  }

  settled(): Promise<void> { return this.queue; }

  private sync(): void {
    this.queue = this.queue.then(async (): Promise<void> => {
      if (this.activeContext !== null &&
        (!this.wanted || this.activeContext !== this.context)) {
        await backgroundTaskManager.stopBackgroundRunning(this.activeContext);
        this.activeContext = null;
        hilog.info(0, 'NearbyChat', 'near-field background task stopped');
      }
      const context = this.context;
      if (!this.wanted || context === null || this.activeContext !== null) return;
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'com.jiuwen.registrychatui', abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 91,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      // A disconnect/destroy while creating the notification must not acquire a stale lease.
      if (!this.wanted || context !== this.context) return;
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION, agent);
      this.activeContext = context;
      hilog.info(0, 'NearbyChat', 'near-field background task started');
    }).catch((error: Error): void => {
      hilog.warn(0, 'NearbyChat', 'near-field background task failed: %{public}s', error.message);
    });
  }
}

export const nearbyBackgroundTask: NearbyBackgroundTask = new NearbyBackgroundTask();
