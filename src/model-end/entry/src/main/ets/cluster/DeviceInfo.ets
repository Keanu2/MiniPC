import { hidebug } from '@kit.PerformanceAnalysisKit';
import { batteryInfo, thermal } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { DeviceInfoEntry, WireMessage } from '../protocol/ChatProtocol';

export const MODEL_DIR: string = 'Qwen2.5-7B-Instruct-Q4_N_0';
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
  return {
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
    peerRole: 'compute'
  };
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
