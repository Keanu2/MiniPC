import { UIAbility, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
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
    windowStage.loadContent('pages/Index');
  }

  onForeground(): void { nearbyChannel.resume(); }
  onBackground(): void { probe.cancel(); nearbyChannel.suspend(); }
  onDestroy(): void { probe.cancel(); nearbyChannel.destroy(); }
}
