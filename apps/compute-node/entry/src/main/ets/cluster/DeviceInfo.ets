import { hidebug } from '@kit.PerformanceAnalysisKit';
import { batteryInfo, thermal } from '@kit.BasicServicesKit';
import { DeviceInfoEntry, WireMessage } from '../protocol/ChatProtocol';
import { activeModelDirs, deviceCapabilities, deviceTier } from '../llm/ModelRegistry';

// Lightweight status requests run often; multi-frame rosters are gated
// separately by topology changes and a 30-second refresh interval.
export const DEVICE_INFO_POLL_MS: number = 2000;
const LOAD_CACHE_MS: number = 1500;

export class LocalModelStatus {
  name: string = '';
  requests: number = -1;
}

class LoadCache {
  at: number = 0;
  thermalLevel: number = -1;
  batteryTemp: number = -1;
  cpuUsage: number = -1;
}

const loadCache: LoadCache = new LoadCache();

/** Show every active model instead of mistaking the first deployed directory for the executing model. */
export function deployedModelName(filesDir: string): string {
  const names = activeModelDirs(filesDir).join(' / ');
  // The wire model field is a display label capped at 128 characters.
  return names.length > 128 ? names.substring(0, 127) + '…' : names;
}

/** 设备级能力跟随当前模型选择；无启用模型 → []。 */
export function deployedCapabilities(filesDir: string): string[] {
  return deviceCapabilities(filesDir);
}

/** 对齐 modelshare：hidebug 采内存，失败则未采样。 */
export function sampleMemory(): DeviceInfoEntry {
  const entry: DeviceInfoEntry = { memTotal: 0, memAvail: 0, memUsage: -1, capabilities: [] };
  try {
    const mem = hidebug.getSystemMemInfo();
    const totalKB = Number(mem.totalMem);
    const availKB = Number(mem.availableMem);
    entry.memTotal = totalKB;
    entry.memAvail = availKB;
    entry.memUsage = totalKB > 0 ? Math.round((totalKB - availKB) * 100 / totalKB) : -1;
  } catch (_) {}
  copyLoad(entry, sampleLoad());
  return entry;
}

/**
 * Thermal gear, battery Celsius and whole-device CPU. Cached so streaming
 * tokens do not call getSystemCpuUsage on every dashboard paint; keep this
 * shorter than DEVICE_INFO_POLL_MS so each status round gets a fresh sample.
 */
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

function copyLoad(entry: DeviceInfoEntry, load: LoadCache): void {
  entry.thermalLevel = load.thermalLevel;
  entry.batteryTemp = load.batteryTemp;
  entry.cpuUsage = load.cpuUsage;
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

/** "42℃ · 温热" — battery number plus system thermal gear. */
export function formatHeat(batteryTemp: number, thermalLevel: number): string {
  const parts: string[] = [];
  if (batteryTemp >= 0) parts.push(String(batteryTemp) + '℃');
  const label = thermalLabel(thermalLevel);
  if (label.length > 0) parts.push(label);
  return parts.join(' · ');
}

export function buildSelfEntry(filesDir: string, running: number, deviceName: string, deviceId: string): DeviceInfoEntry {
  const mem = sampleMemory();
  const model = deployedModelName(filesDir);
  const entry: DeviceInfoEntry = {
    id: deviceId.length > 0 ? deviceId : 'self',
    name: deviceName.length > 0 ? deviceName : '本机',
    role: 'self',
    memTotal: mem.memTotal,
    memAvail: mem.memAvail,
    memUsage: mem.memUsage,
    thermalLevel: mem.thermalLevel,
    batteryTemp: mem.batteryTemp,
    cpuUsage: mem.cpuUsage,
    model: model,
    modelRequests: running,
    capabilities: deployedCapabilities(filesDir),
    ready: true
  };
  // 无就绪模型 → 0 → 省略字段（wire 缺省 = 老对端语义，消费侧按 2 处理）。
  const tier = deviceTier(filesDir);
  if (tier >= 1) entry.modelTier = tier;
  return entry;
}

export function toDeviceInfoReply(requestId: string, entry: DeviceInfoEntry): WireMessage {
  const reply: WireMessage = {
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
    capabilities: entry.capabilities || [],
    peerRole: 'compute'
  };
  if (entry.modelTier !== undefined) reply.modelTier = entry.modelTier;
  return reply;
}

export function applyDeviceInfo(target: DeviceInfoEntry, message: WireMessage): void {
  if (typeof message.name === 'string' && message.name.length > 0) target.name = message.name;
  if (typeof message.memTotal === 'number') target.memTotal = message.memTotal;
  if (typeof message.memAvail === 'number') target.memAvail = message.memAvail;
  if (typeof message.memUsage === 'number') target.memUsage = message.memUsage;
  if (typeof message.thermalLevel === 'number') target.thermalLevel = message.thermalLevel;
  if (typeof message.batteryTemp === 'number') target.batteryTemp = message.batteryTemp;
  if (typeof message.cpuUsage === 'number') target.cpuUsage = message.cpuUsage;
  if (typeof message.model === 'string') target.model = message.model;
  if (typeof message.modelRequests === 'number') target.modelRequests = message.modelRequests;
  if (Array.isArray(message.capabilities)) target.capabilities = message.capabilities;
  // 新旧混布容忍：旧构建可能上报 3 档，消费侧一律归一成 2（强档）。
  if (typeof message.modelTier === 'number' && Number.isInteger(message.modelTier) &&
    message.modelTier >= 1 && message.modelTier <= 3) {
    target.modelTier = message.modelTier === 1 ? 1 : 2;
  }
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
