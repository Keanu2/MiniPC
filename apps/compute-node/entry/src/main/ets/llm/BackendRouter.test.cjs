const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');
const files={};
const moduleObject={exports:{}};
const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,'BackendRouter.ets'),'utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
  require(name){
    if(name==='@kit.PerformanceAnalysisKit')return{hilog:{info(){},warn(){},error(){}}};
    if(name==='@kit.CoreFileKit')return{fileIo:{readTextSync:p=>{
      if(!(p in files))throw new Error('no such file: '+p);
      return files[p];
    }}};
    return{};
  }});
const {BackendRouter}=moduleObject.exports;
const msg=(role,content)=>({role,content});
const text=image=>({messages:[msg('user','hi')],promptChars:2,image:image||'',maxTokens:0});
const both=(localReady,cloudReady)=>({localReady,localBusy:false,cloudReady,cloudBusy:false,exclusions:[]});
const CONFIG='/files/cloud_config.json';
const setConfig=raw=>{files[CONFIG]=raw;};
delete files[CONFIG];

// config 策略（默认）：与引入路由前完全一致——云侧可用即云侧，否则端侧。
const configRouter=new BackendRouter();
assert.equal(configRouter.policy(),'config');
const check=(decision,side,reason)=>{
  assert.equal(decision.side,side);
  assert.equal(decision.reason,reason);
};
check(configRouter.route(text(),both(false,true)),'cloud','config:backend=cloud');
check(configRouter.route(text(),both(true,false)),'local','config:backend=local');
check(configRouter.route(text(),both(true,true)),'cloud','config:backend=cloud');

// cloud / local 策略强制。
assert.equal(new BackendRouter('cloud').route(text(),both(true,false)).side,'cloud');
assert.equal(new BackendRouter('local').route(text(),both(false,true)).side,'local');

// auto 启发式：带图走端侧、云侧未就绪走端侧、端侧无模型走云侧、默认云侧。
const auto=new BackendRouter('auto');
assert.equal(auto.route(text('base64'),both(true,true)).side,'local');
assert.equal(auto.route(text(),both(true,false)).side,'local');
assert.equal(auto.route(text(),both(false,true)).side,'cloud');
assert.equal(auto.route(text(),both(true,true)).side,'cloud');

// 自定义规则优先于策略；返回空串则落回策略。
const pinned=new BackendRouter('cloud');
pinned.setRule({decide:()=> 'local'});
assert.equal(pinned.route(text(),both(false,true)).side,'local');
pinned.setRule({decide:()=>''});
assert.equal(pinned.route(text(),both(false,true)).side,'cloud');
pinned.setRule(null);
assert.equal(pinned.route(text(),both(false,true)).side,'cloud');

// 策略归一化：非法取值回落 config。
const normalize=new BackendRouter('config');
normalize.setPolicy('auto');assert.equal(normalize.policy(),'auto');
normalize.setPolicy('pin1');assert.equal(normalize.policy(),'config');

// loadPolicy：文件缺失/字段缺失/非法值/坏 JSON 均回落 config；合法值透传。
assert.equal(BackendRouter.loadPolicy('/files'),'config');
setConfig('{"backend":"cloud","apiKey":"k","baseUrl":"http://x","model":"m"}');
assert.equal(BackendRouter.loadPolicy('/files'),'config');
setConfig('{"route":"auto"}');assert.equal(BackendRouter.loadPolicy('/files'),'auto');
setConfig('{"route":"cloud"}');assert.equal(BackendRouter.loadPolicy('/files'),'cloud');
setConfig('{"route":"local"}');assert.equal(BackendRouter.loadPolicy('/files'),'local');
setConfig('{"route":"pin2"}');assert.equal(BackendRouter.loadPolicy('/files'),'config');
setConfig('{not json');assert.equal(BackendRouter.loadPolicy('/files'),'config');

// xrouter 策略：决策委托注入的 RouteStrategy（异步）；未注入则回落 config 语义并告警。
(async()=>{
  assert.equal(new BackendRouter('xrouter').policy(),'xrouter');
  const stub={decideAsync:()=>Promise.resolve({side:'local',reason:'stub'})};
  const decided=await new BackendRouter('xrouter',stub).routeAsync(text(),both(false,true));
  assert.equal(decided.side,'local');
  assert.equal(decided.reason,'stub');
  // 同步 route() 对 xrouter 一律回落 config（异步策略无法同步执行）。
  check(new BackendRouter('xrouter',stub).route(text(),both(false,true)),'cloud','config:backend=cloud');
  // routeAsync 对非 xrouter 策略与 route() 等价。
  const same=await new BackendRouter('cloud').routeAsync(text(),both(true,false));
  assert.equal(same.side,'cloud');
  const noStrategy=new BackendRouter('xrouter',null);
  check(noStrategy.route(text(),both(false,true)),'cloud','config:backend=cloud');
  check(noStrategy.route(text(),both(true,false)),'local','config:backend=local');
  const fallback=await noStrategy.routeAsync(text(),both(false,true));
  assert.equal(fallback.reason,'config:backend=cloud');
  normalize.setPolicy('xrouter');assert.equal(normalize.policy(),'xrouter');
  setConfig('{"route":"xrouter"}');assert.equal(BackendRouter.loadPolicy('/files'),'xrouter');
  setConfig('{"route":"pin3"}');assert.equal(BackendRouter.loadPolicy('/files'),'config');

  console.log('PASS backend router config/cloud/local/auto/xrouter policies, sync+async routing, rule precedence, normalization and config loading');
})().catch(e=>{console.error(e);process.exit(1);});
