// node DeviceInfo.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
const kits = {
  mem: { totalMem: 2000, availableMem: 800 },
  cpu: 0.18,
  thermal: 2,
  battery: 421
};
const context = {
  exports: {}, Error, Map, Math, Number, Date,
  require(name) {
    if (name === '@kit.PerformanceAnalysisKit') {
      return {
        hidebug: {
          getSystemMemInfo() { return kits.mem; },
          getSystemCpuUsage() { return kits.cpu; }
        }
      };
    }
    if (name === '@kit.BasicServicesKit') {
      return {
        batteryInfo: { get batteryTemperature() { return kits.battery; } },
        thermal: { getLevel() { return kits.thermal; } }
      };
    }
    if (name === '@kit.CoreFileKit') {
      return { fileIo: { OpenMode: { READ_ONLY: 0 }, openSync() { throw new Error('missing'); } } };
    }
    if (name === '../protocol/ChatProtocol') return {};
    return {};
  }
};
vm.runInNewContext(transpile(__dirname + '/DeviceInfo.ets'), context);
const { DEVICE_INFO_POLL_MS, sampleMemory, formatHeat, thermalLabel, toDeviceInfoReply, formatComputeStatus } = context.exports;
assert.equal(DEVICE_INFO_POLL_MS, 2000);
assert.equal(thermalLabel(0), '清凉');
assert.equal(thermalLabel(2), '温热');
assert.equal(thermalLabel(7), '逃生');
assert.equal(thermalLabel(-1), '');
assert.equal(formatHeat(42, 2), '42℃ · 温热');
assert.equal(formatHeat(-1, 1), '正常');
assert.equal(formatHeat(38, -1), '38℃');
const sampled = sampleMemory();
assert.equal(sampled.memUsage, 60);
assert.equal(sampled.thermalLevel, 2);
assert.equal(sampled.batteryTemp, 42.1);
assert.equal(sampled.cpuUsage, 18);
const reply = toDeviceInfoReply('info-1', {
  name: '算力', memTotal: 2000, memAvail: 800, memUsage: 60,
  thermalLevel: 2, batteryTemp: 42.1, cpuUsage: 18, model: 'Qwen', modelRequests: 1
});
assert.equal(reply.thermalLevel, 2);
assert.equal(reply.batteryTemp, 42.1);
assert.equal(reply.cpuUsage, 18);
assert.equal(formatComputeStatus(reply), 'Qwen · 内存 60% · 42.1℃ · 温热 · CPU 18% · 推理 1');
console.log('PASS: thermal/battery/CPU sampling, heat label, deviceInfo reply fields');
