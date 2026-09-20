import { hidebug } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { DeviceInfoEntry, WireMessage } from '../protocol/ChatProtocol';

export const MODEL_DIR: string = 'Qwen2.5-7B-Instruct-Q4_N_0';
export const DEVICE_INFO_POLL_MS: number = 3000;

export class LocalModelStatus {
  name: string = '';
  requests: number = -1;
}

/** filesDir/models 下首个通过就绪检查的目录；没有则空串。 */
export function deployedModelName(filesDir: string): string {
  if (filesDir.length === 0) return '';
  const err = readinessOf(filesDir + '/models/' + MODEL_DIR);
  return err === '' ? MODEL_DIR : '';
}

export function readinessOf(modelDir: string): string {
  for (const name of ['api_config.json', 'params', 'tokenizer.json']) {
    try {
      const file = fileIo.openSync(modelDir + '/' + name, fileIo.OpenMode.READ_ONLY);
      try {
        if (fileIo.readSync(file.fd, new ArrayBuffer(1)) !== 1) return '模型文件为空：' + name;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_) { return '模型文件缺失或无法读取：' + name; }
  }
  return '';
}

/** 对齐 modelshare：hidebug 采内存，失败则未采样。 */
export function sampleMemory(): DeviceInfoEntry {
  const entry: DeviceInfoEntry = { memTotal: 0, memAvail: 0, memUsage: -1 };
  try {
    const mem = hidebug.getSystemMemInfo();
    const totalKB = Number(mem.totalMem);
    const availKB = Number(mem.availableMem);
    entry.memTotal = totalKB;
    entry.memAvail = availKB;
    entry.memUsage = totalKB > 0 ? Math.round((totalKB - availKB) * 100 / totalKB) : -1;
  } catch (_) {}
  return entry;
}

export function buildSelfEntry(filesDir: string, running: number, deviceName: string, deviceId: string): DeviceInfoEntry {
  const mem = sampleMemory();
  const model = deployedModelName(filesDir);
  return {
    id: deviceId.length > 0 ? deviceId : 'self',
    name: deviceName.length > 0 ? deviceName : '本机',
    role: 'self',
    memTotal: mem.memTotal,
    memAvail: mem.memAvail,
    memUsage: mem.memUsage,
    model: model,
    modelRequests: running,
    ready: true
  };
}

export function toDeviceInfoReply(requestId: string, entry: DeviceInfoEntry): WireMessage {
  return {
    type: 'deviceInfo',
    requestId: requestId,
    name: entry.name || '',
    memTotal: entry.memTotal || 0,
    memAvail: entry.memAvail || 0,
    memUsage: entry.memUsage === undefined ? -1 : entry.memUsage,
    model: entry.model || '',
    modelRequests: entry.modelRequests === undefined ? -1 : entry.modelRequests,
    peerRole: 'compute'
  };
}

export function applyDeviceInfo(target: DeviceInfoEntry, message: WireMessage): void {
  if (typeof message.name === 'string' && message.name.length > 0) target.name = message.name;
  if (typeof message.memTotal === 'number') target.memTotal = message.memTotal;
  if (typeof message.memAvail === 'number') target.memAvail = message.memAvail;
  if (typeof message.memUsage === 'number') target.memUsage = message.memUsage;
  if (typeof message.model === 'string') target.model = message.model;
  if (typeof message.modelRequests === 'number') target.modelRequests = message.modelRequests;
}

export function formatComputeStatus(entry: DeviceInfoEntry | undefined): string {
  if (entry === undefined) return '';
  const model = entry.model && entry.model.length > 0 ? entry.model : '无模型';
  const parts: string[] = [model];
  if (entry.memUsage !== undefined && entry.memUsage >= 0) parts.push('内存 ' + String(entry.memUsage) + '%');
  if (entry.modelRequests !== undefined && entry.modelRequests >= 0) parts.push('推理 ' + String(entry.modelRequests));
  return parts.join(' · ');
}
