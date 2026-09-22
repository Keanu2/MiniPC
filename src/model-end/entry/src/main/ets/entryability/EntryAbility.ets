import { UIAbility, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import probe from 'libgewu_probe.so';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { USE_LINK_ENHANCE } from '../nearby/NearbyConfig';

export default class EntryAbility extends UIAbility {
  onCreate(): void { nearbyChannel.initialize(this.context); }

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
      if (err || deviceInfo.deviceType !== '2in1') return;
      try {
        const win = windowStage.getMainWindowSync();
        win.setWindowLimits({ minWidth: 720, minHeight: 520 }).catch(() => {});
        win.resize(1180, 760).catch(() => {});
      } catch (_) {}
    });
  }

  onForeground(): void { nearbyChannel.resume(); }
  onBackground(): void {
    hilog.info(0, 'NearbyChat', 'ability background: cancelling inference and near-field link');
    probe.cancel();
    nearbyChannel.suspend();
  }
  onDestroy(): void { probe.cancel(); nearbyChannel.destroy(); }
}
