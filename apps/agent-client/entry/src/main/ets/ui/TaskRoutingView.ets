import { webview } from '@kit.ArkWeb';

@Component
export struct TaskRoutingView {
  @Prop @Watch('refresh') eventJson: string = '{}';
  private controller: webview.WebviewController = new webview.WebviewController();
  private loaded: boolean = false;
  private refresh(): void {
    if (!this.loaded) { return; }
    this.controller.runJavaScript('window.onNativeEvent(' + this.eventJson + ')').catch((_error: Error): void => {});
  }
  aboutToDisappear(): void { this.loaded = false; }
  build() {
    Web({ src: $rawfile('task-routing.html'), controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(false)
      .onPageEnd(() => { this.loaded = true; this.refresh(); })
      .width('100%').height('100%')
  }
}
