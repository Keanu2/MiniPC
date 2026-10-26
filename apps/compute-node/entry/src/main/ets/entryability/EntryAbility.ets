import { UIAbility, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import probe from 'libgewu_probe.so';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { nearbyBackgroundTask } from '../nearby/NearbyBackgroundTask';
import { USE_LINK_ENHANCE } from '../nearby/NearbyConfig';
import { CollaborationWindow, collaborationScreen } from '../ui/CollaborationScreen';

class NativeCollaborationWindow implements CollaborationWindow {
  private target: window.Window;
  constructor(target: window.Window) { this.target = target; }
  setWindowKeepScreenOn(enabled: boolean): Promise<void> {
    return this.target.setWindowKeepScreenOn(enabled).then((): void => {
      hilog.info(0, 'CollabScreen', 'window keepScreenOn applied=%{public}s', String(enabled));
      try { hilog.info(0, 'CollabScreen', 'window keepScreenOn actual=%{public}s', String(this.target.getWindowProperties().isKeepScreenOn)); } catch (_) {}
    }).catch((error: Error): void => {
      hilog.warn(0, 'CollabScreen', 'window keepScreenOn failed=%{public}s', error.message);
      throw error;
    });
  }
}

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    nearbyChannel.initialize(this.context);
    nearbyBackgroundTask.initialize(this.context);
    nearbyChannel.setActivityListener((connected: boolean): void => nearbyBackgroundTask.setWanted(connected));
  }

  onCollaborate(wantParam: Record<string, Object>): AbilityConstant.CollaborateResult {
    hilog.info(0, 'NearbyChat', 'onCollaborate entered');
    if (USE_LINK_ENHANCE) {
      hilog.info(0, 'NearbyChat', 'onCollaborate ignored for linkEnhance');
      return AbilityConstant.CollaborateResult.REJECT;
    }
    nearbyChannel.initialize(this.context);
    const parameters = wantParam['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object>;
    hilog.info(0, 'NearbyChat', 'collaborate payload present=%{public}s', String(!!parameters));
    return parameters && nearbyChannel.accept(parameters) ?
      AbilityConstant.CollaborateResult.ACCEPT : AbilityConstant.CollaborateResult.REJECT;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      hilog.info(0, 'CollabScreen', 'window content code=%{public}d', err?.code ?? 0);
      if (err && err.code !== 0) return;
      try {
        const win = windowStage.getMainWindowSync();
        collaborationScreen.bind(new NativeCollaborationWindow(win));
        if (deviceInfo.deviceType !== '2in1') return;
        win.setWindowLimits({ minWidth: 960, minHeight: 640 }).catch(() => {});
        win.resize(1280, 800).catch(() => {});
      } catch (_) {}
    });
  }

  onForeground(): void {
    hilog.info(0, 'CollabScreen', 'foreground');
    collaborationScreen.setForeground(true);
    nearbyChannel.resume();
    nearbyBackgroundTask.retry();
  }
  onBackground(): void {
    hilog.info(0, 'NearbyChat', 'ability background: preserving inference and near-field links');
    collaborationScreen.setForeground(false);
    nearbyChannel.suspend();
  }
  onDestroy(): void {
    collaborationScreen.clear();
    probe.cancel();
    nearbyChannel.destroy();
    nearbyChannel.setActivityListener(null);
    nearbyBackgroundTask.dispose();
  }
}
