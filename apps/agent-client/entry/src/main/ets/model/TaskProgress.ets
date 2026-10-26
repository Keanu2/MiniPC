export type TaskProgressPhase = 'preparing' | 'running' | 'done' | 'partial' | 'failed' | 'cancelled';

export interface TaskProgress {
  kind: string;
  phase: TaskProgressPhase;
  startedAt: number;
  endedAt: number;
}

export function taskProgressActive(phase: TaskProgressPhase): boolean {
  return phase === 'preparing' || phase === 'running';
}

export function taskProgressLabel(phase: TaskProgressPhase): string {
  switch (phase) {
    case 'preparing': return '正在准备发送';
    case 'running': return '执行中';
    case 'done': return '已完成';
    case 'partial': return '部分完成';
    case 'failed': return '执行失败';
    case 'cancelled': return '已停止';
  }
}

export function formatTaskElapsed(startedAt: number, now: number): string {
  const seconds = Math.floor(Math.max(0, now - startedAt) / 1000);
  const minutes = Math.floor(seconds / 60);
  const tail = (seconds % 60).toString().padStart(2, '0');
  if (minutes < 60) { return minutes.toString().padStart(2, '0') + ':' + tail; }
  return Math.floor(minutes / 60).toString().padStart(2, '0') + ':' +
    (minutes % 60).toString().padStart(2, '0') + ':' + tail;
}
