import { hidebug } from '@kit.PerformanceAnalysisKit';
import { batteryInfo, thermal } from '@kit.BasicServicesKit';
import { DeviceInfoEntry, WireMessage } from '../protocol/ChatProtocol';

export const MODEL_DIR: string = 'Qwen2.5-7B-Instruct-Q4_N_0';
const LOAD_CACHE_MS: number = 1500;

class LoadCache {
  at: number = 0;
  thermalLevel: number = -1;
  batteryTemp: number = -1;
  cpuUsage: number = -1;
}

const loadCache: LoadCache = new LoadCache();

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
  const load = sampleLoad();
  entry.thermalLevel = load.thermalLevel;
  entry.batteryTemp = load.batteryTemp;
  entry.cpuUsage = load.cpuUsage;
  return entry;
}

function sampleLoad(): LoadCache {
  const now = Date.now();
  if (loadCache.at > 0 && now - loadCache.at < LOAD_CACHE_MS) return loadCache;
  loadCache.at = now;
  try {
    loadCache.thermalLevel = thermal.getLevel();
  } catch (_) {
    loadCache.thermalLevel = -1;
  }
  try {
    loadCache.batteryTemp = Math.round(batteryInfo.batteryTemperature) / 10;
  } catch (_) {
    loadCache.batteryTemp = -1;
  }
  try {
    const usage = hidebug.getSystemCpuUsage();
    loadCache.cpuUsage = usage >= 0 ? Math.round(usage * 100) : -1;
  } catch (_) {
    loadCache.cpuUsage = -1;
  }
  return loadCache;
}

export function thermalLabel(level: number): string {
  if (level === 0) return '清凉';
  if (level === 1) return '正常';
  if (level === 2) return '温热';
  if (level === 3) return '发热';
  if (level === 4) return '过热';
  if (level === 5) return '警告';
  if (level === 6) return '紧急';
  if (level === 7) return '逃生';
  return '';
}

export function formatHeat(batteryTemp: number, thermalLevel: number): string {
  const parts: string[] = [];
  if (batteryTemp >= 0) parts.push(String(batteryTemp) + '℃');
  const label = thermalLabel(thermalLevel);
  if (label.length > 0) parts.push(label);
  return parts.join(' · ');
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
    thermalLevel: mem.thermalLevel,
    batteryTemp: mem.batteryTemp,
    cpuUsage: mem.cpuUsage,
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
    thermalLevel: entry.thermalLevel === undefined ? -1 : entry.thermalLevel,
    batteryTemp: entry.batteryTemp === undefined ? -1 : entry.batteryTemp,
    cpuUsage: entry.cpuUsage === undefined ? -1 : entry.cpuUsage,
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
  const heat = formatHeat(entry.batteryTemp === undefined ? -1 : entry.batteryTemp,
    entry.thermalLevel === undefined ? -1 : entry.thermalLevel);
  if (heat.length > 0) parts.push(heat);
  if (entry.cpuUsage !== undefined && entry.cpuUsage >= 0) parts.push('CPU ' + String(entry.cpuUsage) + '%');
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
    thermalLevel: message.thermalLevel,
    batteryTemp: message.batteryTemp,
    cpuUsage: message.cpuUsage,
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
