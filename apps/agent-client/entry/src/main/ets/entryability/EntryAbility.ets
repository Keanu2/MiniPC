import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { nearbyBackgroundTask } from '../nearby/NearbyBackgroundTask';
import { fitDefaultWindow, tabletSizePx } from '../model/TabletDisplay';

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
      this.configureDefaultWindow(windowStage).catch((error: Error): void => {
        hilog.warn(DOMAIN, 'Loop', 'default tablet window failed=%{public}s', error.message);
      });
    });
  }

  private async configureDefaultWindow(windowStage: window.WindowStage): Promise<void> {
    if (deviceInfo.deviceType !== '2in1') { return; }
    const win = windowStage.getMainWindowSync();
    const screen = display.getDefaultDisplaySync();
    const availableWidth = screen.availableWidth > 0 ? screen.availableWidth : screen.width;
    const availableHeight = screen.availableHeight > 0 ? screen.availableHeight : screen.height;
    const size = fitDefaultWindow(tabletSizePx(screen.width, screen.height), availableWidth, availableHeight);
    const scale = Number.isFinite(screen.densityPixels) && screen.densityPixels > 0 ? screen.densityPixels : 1;
    // Limits are in physical px; logical density is used ONLY for minimum usable UI space.
    // Keep min and max independent so the user can freely resize or maximize the window.
    const limits = await win.setWindowLimits({
      minWidth: Math.min(size.width, Math.round(400 * scale)), maxWidth: availableWidth,
      minHeight: Math.min(size.height, Math.round(560 * scale)), maxHeight: availableHeight
    });
    const width = Math.max(limits.minWidth || 1, Math.min(size.width, limits.maxWidth || availableWidth));
    const height = Math.max(limits.minHeight || 1, Math.min(size.height, limits.maxHeight || availableHeight));
    await win.resize(width, height);
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
