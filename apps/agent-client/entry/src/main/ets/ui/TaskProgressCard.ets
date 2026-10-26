import { formatTaskElapsed, TaskProgress, taskProgressActive, taskProgressLabel } from '../model/TaskProgress';

@Component
export struct TaskProgressCard {
  @Prop @Watch('syncTimer') progress: TaskProgress = {
    kind: '文本', phase: 'preparing', startedAt: 0, endedAt: 0
  };
  @State elapsed: string = '00:00';
  private timerId: number = -1;
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.syncTimer();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private updateElapsed(): void {
    this.elapsed = formatTaskElapsed(this.progress.startedAt,
      taskProgressActive(this.progress.phase) ? Date.now() : this.progress.endedAt);
  }

  private syncTimer(): void {
    this.clearTimer();
    this.updateElapsed();
    if (this.visible && taskProgressActive(this.progress.phase)) {
      this.timerId = setInterval((): void => this.updateElapsed(), 1000);
    }
  }

  private statusColor(): string {
    if (this.progress.phase === 'failed') { return '#B6382D'; }
    if (this.progress.phase === 'partial') { return '#8A590F'; }
    if (this.progress.phase === 'cancelled') { return '#526861'; }
    return '#0B7562';
  }

  build() {
    if (taskProgressActive(this.progress.phase)) {
      Row({ space: 16 }) {
        Row({ space: 12 }) {
          Image(this.progress.kind === '图像' ? $r('app.media.task_image') : $r('app.media.task_text'))
            .width(44)
            .height(44)
            .padding(10)
            .backgroundColor('#E8F5ED')
            .borderRadius(13)
            .accessibilityLevel('no')
          Text(this.progress.kind + '任务' + (this.progress.phase === 'running' ? '已发送' : ''))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#16332C')
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)
        Column({ space: 12 }) {
          Row({ space: 6 }) {
            LoadingProgress()
              .width(10)
              .height(10)
              .color('#0B7562')
              .accessibilityLevel('no')
            Text(taskProgressLabel(this.progress.phase))
              .fontSize(12)
              .fontColor(this.statusColor())
          }
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor('#EAF5EE')
          .borderRadius(20)
          Text(this.elapsed)
            .fontSize(this.elapsed.length > 5 ? 24 : 29)
            .fontWeight(FontWeight.Medium)
            .fontFamily('monospace')
            .fontColor('#16332C')
            .accessibilityText('用时 ' + this.elapsed)
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 18, right: 18, top: 16, bottom: 14 })
      .backgroundColor(Color.White)
      .border({ width: 1, color: '#C9E1D4' })
      .borderRadius(18)
    } else {
      Row({ space: 8 }) {
        Text(this.progress.phase === 'done' ? '✓' : (this.progress.phase === 'failed' ? '!' : '−'))
          .fontSize(12)
          .fontColor(this.statusColor())
          .width(18)
          .height(18)
          .textAlign(TextAlign.Center)
          .backgroundColor('#E0F1E7')
          .borderRadius(9)
          .accessibilityLevel('no')
        Text(this.progress.kind + '任务 · ' + taskProgressLabel(this.progress.phase) + ' · 总用时 ' + this.elapsed)
          .fontSize(13)
          .fontColor(this.statusColor())
          .flexShrink(1)
      }
      .constraintSize({ maxWidth: '100%' })
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
      .backgroundColor('#F8FCFA')
      .border({ width: 1, color: '#D6E7DF' })
      .borderRadius(14)
    }
  }
}
