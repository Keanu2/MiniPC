const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || 'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../../../..');
const apps = ['apps/agent-client', 'apps/compute-node'];
const deferred = () => {let resolve; const promise = new Promise(done => {resolve = done;});return {promise, resolve};};
const drain = async () => {for (let i = 0; i < 10; i++) await Promise.resolve();};
function fixture(app, options = {}) {
  const starts = [], stops = [], agents = [], errors = [];
  const imports = {
    '@kit.AbilityKit': {wantAgent: {OperationType: {START_ABILITY: 1}, WantAgentFlags: {UPDATE_PRESENT_FLAG: 4},
      getWantAgent: async info => {agents.push(info);if (options.agent) await options.agent.promise;return {agent: 1};}}},
    '@kit.BackgroundTasksKit': {backgroundTaskManager: {BackgroundMode: {MULTI_DEVICE_CONNECTION: 6},
      startBackgroundRunning: async (context, mode, agent) => {
        starts.push({context, mode, agent});
        if (options.failStart && starts.length === 1) throw new Error('denied');
        if (options.start) await options.start.promise;
      },
      stopBackgroundRunning: async context => {stops.push(context);if (options.stop) await options.stop.promise;}}},
    '@kit.PerformanceAnalysisKit': {hilog: {info() {}, warn(...args) {errors.push(args);}}}
  };
  const filename = path.join(root, app, 'entry/src/main/ets/nearby/NearbyBackgroundTask.ets');
  const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {fileName: 'NearbyBackgroundTask.ts', reportDiagnostics: true,
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}});
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const box = {exports: {}, require: name => {assert.ok(imports[name], name);return imports[name];}};
  vm.runInNewContext(compiled.outputText, box);
  const lease = new box.exports.NearbyBackgroundTask();
  const context = {ability: 'main'};lease.initialize(context);
  return {lease, context, starts, stops, agents, errors};
}
for (const app of apps) {
  test(app + ': connected lease survives foreground/background, releases on last disconnect', async () => {
    const h=fixture(app);h.lease.setWanted(false);await h.lease.settled();assert.equal(h.starts.length,0);
    h.lease.setWanted(true);h.lease.setWanted(true);await h.lease.settled();h.lease.retry();await h.lease.settled();
    assert.equal(h.starts.length,1);assert.equal(h.starts[0].mode,6);assert.equal(h.starts[0].context,h.context);
    assert.equal(h.agents[0].wants[0].abilityName,'EntryAbility');
    h.lease.setWanted(false);await h.lease.settled();assert.deepEqual(h.stops,[h.context]);
  });
  test(app + ': disconnect during notification creation never starts a stale lease', async () => {
    const agent=deferred(),h=fixture(app,{agent});h.lease.setWanted(true);await drain();
    h.lease.setWanted(false);agent.resolve();await h.lease.settled();assert.equal(h.starts.length,0);assert.equal(h.stops.length,0);
  });
  test(app + ': destruction during startup stops the late successful lease', async () => {
    const start=deferred(),h=fixture(app,{start});h.lease.setWanted(true);await drain();assert.equal(h.starts.length,1);
    h.lease.dispose();start.resolve();await h.lease.settled();assert.deepEqual(h.stops,[h.context]);
    assert.equal(h.lease.activeContext,null);
  });
  test(app + ': reconnect waits for release before acquiring again', async () => {
    const stop=deferred(),h=fixture(app,{stop});h.lease.setWanted(true);await h.lease.settled();
    h.lease.setWanted(false);await drain();h.lease.setWanted(true);await drain();assert.equal(h.starts.length,1);
    stop.resolve();await h.lease.settled();assert.equal(h.starts.length,2);
  });
  test(app + ': denied startup is logged and can retry on foreground without claiming success', async () => {
    const h=fixture(app,{failStart:true});h.lease.setWanted(true);await h.lease.settled();
    assert.equal(h.lease.activeContext,null);assert.equal(h.errors.length,1);
    h.lease.retry();await h.lease.settled();assert.equal(h.starts.length,2);assert.equal(h.lease.activeContext,h.context);
    h.lease.dispose();await h.lease.settled();assert.deepEqual(h.stops,[h.context]);
  });
  test(app + ': declares the matching system permission and background mode', () => {
    const manifest=JSON.parse(fs.readFileSync(path.join(root,app,'entry/src/main/module.json5'),'utf8')).module;
    assert.ok(manifest.requestPermissions.some(p=>p.name==='ohos.permission.KEEP_BACKGROUND_RUNNING'));
    assert.ok(manifest.abilities.find(a=>a.name==='EntryAbility').backgroundModes.includes('multiDeviceConnection'));
  });
  test(app + ': actual ability lifecycle keeps the connected lease in background and releases on destruction',async()=>{
    const h=fixture(app),calls=[];let listener=null;
    h.context.getApplicationContext=()=>({setColorMode(){}});
    const channel={initialize(){},setActivityListener(fn){listener=fn;},resume(){calls.push('foreground');},
      suspend(){calls.push('background');},destroy(){calls.push('destroy');listener?.(false);}};
    const imports={
      '@kit.AbilityKit':{UIAbility:class{constructor(){this.context=h.context;}},
        ConfigurationConstant:{ColorMode:{COLOR_MODE_NOT_SET:0}},AbilityConstant:{}},
      '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
      '@kit.BasicServicesKit':{deviceInfo:{deviceType:'phone'}},
      '../nearby/LinkEnhanceChannel':{nearbyChannel:channel},
      '../nearby/NearbyBackgroundTask':{nearbyBackgroundTask:h.lease},
      '../ui/CollaborationScreen':{collaborationScreen:{setForeground(){},clear(){}}},
      'libgewu_probe.so':{default:{cancel(){calls.push('cancel');}}}
    };
    const filename=path.join(root,app,'entry/src/main/ets/entryability/EntryAbility.ets');
    const js=ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
    const box={exports:{},require:name=>imports[name]||{}};vm.runInNewContext(js,box);
    const ability=new box.exports.default();ability.onCreate();listener(true);await h.lease.settled();
    ability.onBackground();await h.lease.settled();assert.equal(h.starts.length,1);assert.equal(h.stops.length,0);
    assert(!calls.includes('cancel'));assert(!calls.includes('destroy'));assert(calls.includes('background'));
    ability.onForeground();await h.lease.settled();assert.equal(h.starts.length,1);
    ability.onDestroy();await h.lease.settled();assert.equal(h.stops.length,1);assert(calls.includes('destroy'));assert.equal(listener,null);
  });
}
