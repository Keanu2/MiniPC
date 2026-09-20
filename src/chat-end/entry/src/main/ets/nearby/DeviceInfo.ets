import { hidebug } from '@kit.PerformanceAnalysisKit';
import { DeviceInfoEntry, WireMessage } from './ChatProtocol';

export const MODEL_DIR: string = 'Qwen2.5-7B-Instruct-Q4_N_0';

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

export function buildSelfEntry(hasModel: boolean, running: number, deviceName: string, deviceId: string): DeviceInfoEntry {
  const mem = sampleMemory();
  return {
    id: deviceId.length > 0 ? deviceId : 'self',
    name: deviceName.length > 0 ? deviceName : '本机',
    role: 'chat',
    memTotal: mem.memTotal,
    memAvail: mem.memAvail,
    memUsage: mem.memUsage,
    model: hasModel ? MODEL_DIR : '',
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
    peerRole: 'chat'
  };
}

export function formatComputeStatus(entry: DeviceInfoEntry | undefined): string {
  if (entry === undefined) return '';
  const model = entry.model && entry.model.length > 0 ? entry.model : '无模型';
  const parts: string[] = [model];
  if (entry.memUsage !== undefined && entry.memUsage >= 0) parts.push('内存 ' + String(entry.memUsage) + '%');
  if (entry.modelRequests !== undefined && entry.modelRequests >= 0) parts.push('推理 ' + String(entry.modelRequests));
  return parts.join(' · ');
}

export function fromDeviceInfoMessage(message: DeviceInfoEntry): DeviceInfoEntry {
  return {
    id: message.id || '',
    name: message.name || '',
    role: message.role || 'compute',
    memTotal: message.memTotal,
    memAvail: message.memAvail,
    memUsage: message.memUsage,
    model: message.model || '',
    modelRequests: message.modelRequests,
    ready: true
  };
}

export function peerDisplayName(entry: DeviceInfoEntry): string {
  if (entry.role === 'self' || entry.name === '本机') return '算力';
  if (entry.name && entry.name.length > 0) return entry.name;
  return entry.role === 'chat' ? '聊天设备' : '算力';
}
