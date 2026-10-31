import { DeviceInfoEntry, RoutingCall, WireMessage } from '../protocol/ChatProtocol';

interface RouteDevice {
  id: string; name: string; role: string; ready: boolean; jobs: number;
  model?: string; memUsage?: number; capabilities?: string[];
}
interface FlowNotice {
  key: string; revision: number; kind: string; phase: string; source: string; origin: string;
  originId?: string; executorId?: string; elapsed: number; executionBackend?: string; executionModel?: string;
}
interface FlowEntry { notice: FlowNotice; receivedAt: number; }
interface RouteJob {
  executorId?: string; executionBackend?: string; executionModel?: string;
  id: string; key: string; source: string; origin: string; originId: string;
  question: string; kind: string; image: string; phase: string; running: boolean;
  startedAt: number; phaseStartedAt: number;
}
interface RoutingEvent { devices: RouteDevice[]; jobs: RouteJob[]; queuedCalls: RouteJob[]; flowCalls: RouteJob[]; }

function mergeDevice(previous: DeviceInfoEntry | undefined, next: DeviceInfoEntry): DeviceInfoEntry {
  return {
    id: next.id ?? previous?.id, deviceUid: next.deviceUid ?? previous?.deviceUid,
    name: next.name || previous?.name, role: next.role ?? previous?.role, slot: next.slot ?? previous?.slot,
    ready: next.ready ?? previous?.ready, model: next.model ?? previous?.model,
    memTotal: next.memTotal ?? previous?.memTotal, memAvail: next.memAvail ?? previous?.memAvail,
    memUsage: next.memUsage ?? previous?.memUsage, thermalLevel: next.thermalLevel ?? previous?.thermalLevel,
    batteryTemp: next.batteryTemp ?? previous?.batteryTemp, cpuUsage: next.cpuUsage ?? previous?.cpuUsage,
    modelRequests: next.modelRequests ?? previous?.modelRequests,
    capabilities: next.capabilities !== undefined && next.capabilities.length > 0 ? next.capabilities :
      (previous?.capabilities ?? next.capabilities)
  };
}

/** Projection of received roster and owned inference calls. Never invent device slots or assignments. */
export class TaskRoutingStore {
  private roster: DeviceInfoEntry[] = [];
  private flows: Map<string, FlowEntry> = new Map();
  private revisions: Map<string, number> = new Map();
  private epoch: number = -1;
  receive(message: WireMessage, epoch: number, connectedHub: DeviceInfoEntry | null = null): void {
    if (message.type !== 'deviceInfoSync' && message.type !== 'deviceInfo') { return; }
    if (this.epoch >= 0 && this.epoch !== epoch) { this.clear(); }
    if (message.type === 'deviceInfoSync') {
      if (!Array.isArray(message.devices)) { return; }
      const previous = this.roster;
      this.epoch = epoch;
      // A compact roster is authoritative about membership, not absent telemetry.
      this.roster = message.devices.slice(0, 16).map((device: DeviceInfoEntry): DeviceInfoEntry => {
        const id = device.deviceUid || device.id;
        const prior = id === undefined ? undefined : previous.find((item: DeviceInfoEntry): boolean =>
          (item.deviceUid || item.id) === id);
        return mergeDevice(prior, device);
      });
      return;
    }
    // Empty deviceInfo frames are polls, not new telemetry. Do not clear known values.
    if (connectedHub === null || (message.model === undefined && message.memUsage === undefined &&
      message.memTotal === undefined && message.memAvail === undefined && message.cpuUsage === undefined &&
      message.thermalLevel === undefined && message.batteryTemp === undefined && message.modelRequests === undefined &&
      (message.capabilities === undefined || message.capabilities.length === 0))) { return; }
    this.epoch = epoch;
    const hubId = connectedHub.deviceUid || connectedHub.id;
    const prior = this.roster.find((item: DeviceInfoEntry): boolean => (item.deviceUid || item.id) === hubId);
    const update: DeviceInfoEntry = {
      id: hubId, deviceUid: connectedHub.deviceUid, name: prior?.name || connectedHub.name || message.name,
      role: 'compute', ready: true, slot: prior?.slot ?? connectedHub.slot,
      model: message.model, memUsage: message.memUsage, memTotal: message.memTotal, memAvail: message.memAvail,
      cpuUsage: message.cpuUsage, thermalLevel: message.thermalLevel, batteryTemp: message.batteryTemp,
      modelRequests: message.modelRequests, capabilities: message.capabilities
    };
    const merged = mergeDevice(prior, update);
    this.roster = this.roster.filter((item: DeviceInfoEntry): boolean => (item.deviceUid || item.id) !== hubId);
    this.roster = [merged, ...this.roster].slice(0, 16);
  }
  receiveFlow(message: WireMessage): void {
    let notice: FlowNotice;
    try { notice = JSON.parse(message.text || '') as FlowNotice; } catch (_error) { return; }
    if (notice === null || typeof notice !== 'object' || typeof notice.key !== 'string' || notice.key.length > 256 ||
      !Number.isSafeInteger(notice.revision) || notice.revision < 1 ||
      !['text', 'image'].includes(notice.kind) || !['sending', 'queued', 'running', 'cleared'].includes(notice.phase) ||
      typeof notice.source !== 'string' || notice.source.length > 128 || typeof notice.origin !== 'string' || notice.origin.length > 128 ||
      (notice.originId !== undefined && (typeof notice.originId !== 'string' || notice.originId.length > 128)) ||
      (notice.executorId !== undefined && (typeof notice.executorId !== 'string' || notice.executorId.length > 128)) ||
      (notice.executionBackend !== undefined && !['local', 'cloud'].includes(notice.executionBackend)) ||
      (notice.executionModel !== undefined && (typeof notice.executionModel !== 'string' || notice.executionModel.length > 256)) ||
      !Number.isFinite(notice.elapsed) || notice.elapsed < 0 || notice.elapsed > 86400000 ||
      notice.revision <= (this.revisions.get(notice.key) || 0)) { return; }
    this.revisions.set(notice.key, notice.revision);
    while (this.revisions.size > 256) { this.revisions.delete(Array.from(this.revisions.keys())[0]); }
    if (notice.phase === 'cleared') { this.flows.delete(notice.key); return; }
    if (this.flows.size < 128 || this.flows.has(notice.key)) {
      this.flows.set(notice.key, { notice: notice, receivedAt: Date.now() });
    }
  }
  clear(): void { this.roster = []; this.epoch = -1; this.flows.clear(); this.revisions.clear(); }
  snapshot(calls: RoutingCall[], selfLabel: string, selfUid: string, connected: boolean, readyEpoch: number, connectedHub: DeviceInfoEntry | null = null): string {
    if (!connected || (this.epoch >= 0 && this.epoch !== readyEpoch)) { this.clear(); }
    const devices: RouteDevice[] = this.roster.map((device: DeviceInfoEntry, index: number): RouteDevice => ({
      id: device.deviceUid || device.id || 'roster-' + index, name: device.name || (device.role === 'chat' ? '聊天设备' : '算力设备') + (device.slot || ''),
      role: device.role === 'chat' ? 'chat' : 'compute', ready: device.ready !== false,
      jobs: device.modelRequests ?? 0, model: device.model, memUsage: device.memUsage,
      capabilities: device.capabilities
    }));
    // A completed handshake is enough to show the connected hub. Older compute builds
    // do not broadcast rosters to chat peers, and newer rosters can arrive later.
    if (connected && connectedHub !== null && !devices.some((device: RouteDevice): boolean => device.role === 'compute')) {
      devices.push({ id: connectedHub.deviceUid || connectedHub.id || 'connected:' + readyEpoch,
        name: connectedHub.name || '算力设备', role: 'compute', ready: true, jobs: 0 });
    }
    if (!devices.some((device: RouteDevice): boolean => device.id === selfUid)) {
      devices.push({ id: selfUid, name: selfLabel, role: 'chat', ready: true, jobs: 0 });
    }
    const jobs: RouteJob[] = [];
    const queued: RouteJob[] = [];
    for (const call of calls) {
      if (!connected) { break; }
      if (connectedHub !== null && call.device === '算力设备1') {
        const hubId = connectedHub.deviceUid || connectedHub.id || 'connected:' + readyEpoch;
        const hub = devices.find((device: RouteDevice): boolean => device.id === hubId);
        if (hub !== undefined && hub.name === '算力设备') { hub.name = call.device; }
      }
      // An accepted public device label is evidence even before the first roster arrives.
      if (call.device.length > 0 && !devices.some((device: RouteDevice): boolean => device.name === call.device)) {
        devices.push({ id: 'accepted:' + call.device, name: call.device, role: 'compute', ready: true, jobs: 1 });
      }
      const job: RouteJob = { id: call.id, key: 'client:' + call.id,
        source: call.device || (call.phase === 'sending' && connectedHub !== null ? connectedHub.name || '算力设备' : ''),
        origin: selfLabel, originId: selfUid, question: call.question, kind: call.image.length > 0 ? 'image' : 'text',
        image: call.image.length > 0 ? 'data:image/jpeg;base64,' + call.image : '', phase: call.phase,
        running: call.phase !== 'queued', startedAt: call.startedAt, phaseStartedAt: call.startedAt };
      const evidence = Array.from(this.flows.values()).find((entry: FlowEntry): boolean =>
        (entry.notice.originId === selfUid || (!entry.notice.originId && entry.notice.origin === selfLabel)) &&
        entry.notice.key.includes(':' + call.id + ':'));
      if (evidence !== undefined) {
        job.executionBackend = evidence.notice.executionBackend;
        job.executionModel = evidence.notice.executionModel;
        job.executorId = evidence.notice.executorId;
      }
      if (call.phase === 'queued') { queued.push(job); } else { jobs.push(job); }
    }
    const mirrors: RouteJob[] = [];
    for (const entry of this.flows.values()) {
      const notice = entry.notice;
      if (Date.now() - entry.receivedAt > 600000 || notice.originId === selfUid ||
        (!notice.originId && notice.origin === selfLabel)) { continue; }
      mirrors.push({ id: notice.key, key: 'mirror:' + notice.key, source: notice.source,
        origin: notice.origin, originId: notice.originId || '', executorId: notice.executorId,
        executionBackend: notice.executionBackend, executionModel: notice.executionModel,
        question: '', kind: notice.kind, image: '', phase: notice.phase, running: true,
        startedAt: entry.receivedAt - notice.elapsed, phaseStartedAt: entry.receivedAt - notice.elapsed });
    }
    const event: RoutingEvent = { devices: devices, jobs: jobs, queuedCalls: queued, flowCalls: mirrors };
    return JSON.stringify(event);
  }
}
