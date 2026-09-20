export interface NamedPeer {
  epoch: number;
  name: string;
}

export function computeLabel(workerEpoch: number, peers: NamedPeer[]): string {
  if (workerEpoch <= 0) return '算力设备1';
  for (const info of peers) {
    if (info.epoch === workerEpoch) return info.name || '算力设备';
  }
  return '算力设备';
}

export function chatLabel(epoch: number, peers: NamedPeer[]): string {
  for (const info of peers) {
    if (info.epoch === epoch) return info.name;
  }
  return '聊天设备';
}

export function workerTail(workerEpoch: number, peers: NamedPeer[]): string {
  return '由' + computeLabel(workerEpoch, peers) + '推理';
}
