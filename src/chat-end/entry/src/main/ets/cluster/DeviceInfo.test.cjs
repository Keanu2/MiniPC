// node DeviceInfo.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
const kits = { mem: { totalMem: 2000, availableMem: 800 }, cpu: 0.18, thermal: 2, battery: 421 };
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
    if (name === '../protocol/ChatProtocol') return {};
    return {};
  }
};
vm.runInNewContext(transpile(__dirname + '/DeviceInfo.ets'), context);
const { sampleMemory, formatHeat, toDeviceInfoReply, formatComputeStatus } = context.exports;
assert.equal(formatHeat(42, 2), '42℃ · 温热');
const sampled = sampleMemory();
assert.equal(sampled.thermalLevel, 2);
assert.equal(sampled.batteryTemp, 42.1);
assert.equal(sampled.cpuUsage, 18);
const reply = toDeviceInfoReply('info-1', sampled);
assert.equal(reply.peerRole, 'chat');
assert.equal(reply.cpuUsage, 18);
assert(formatComputeStatus(reply).indexOf('CPU 18%') >= 0);
console.log('PASS: chat-end thermal/battery/CPU sampling');
