import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { nearbyBackgroundTask } from '../nearby/NearbyBackgroundTask';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onCreate');
    nearbyChannel.initialize(this.context);
    nearbyBackgroundTask.initialize(this.context);
    nearbyChannel.setActivityListener((connected: boolean): void => nearbyBackgroundTask.setWanted(connected));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onDestroy');
    nearbyChannel.destroy();
    nearbyChannel.setActivityListener(null);
    nearbyBackgroundTask.dispose();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, 'Loop', 'Failed to load content. Cause: %{public}s', JSON.stringify(error));
        return;
      }
      hilog.info(DOMAIN, 'Loop', 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onForeground');
    nearbyChannel.resume();
    nearbyBackgroundTask.retry();
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'Loop', 'EntryAbility onBackground');
    nearbyChannel.suspend();
  }
}
