const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');
const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,'RouteMemory.ets'),'utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
const moduleObject={exports:{}};
vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console},{filename:'RouteMemory.ets'});
const {RouteMemory}=moduleObject.exports;

(async()=>{
  // 未知键返回空视图。
  let t=0;
  const clock=()=>t;
  const mem=new RouteMemory(300_000,1024,clock);
  let v=mem.snapshot('k');
  assert.equal(v.sampleCount,0);
  assert.equal(v.affinity,'');
  assert.equal(v.exclusions.length,0);

  // ok → 亲和 + 计数；snapshot 返回副本（外部改写不影响内部）。
  mem.report('k','modelA','ok');
  v=mem.snapshot('k');
  assert.equal(v.sampleCount,1);
  assert.equal(v.affinity,'modelA');
  assert.equal(v.exclusions.length,0);
  v.exclusions.push('hacked');
  v.sampleCount=99;
  assert.equal(mem.snapshot('k').exclusions.length,0);
  assert.equal(mem.snapshot('k').sampleCount,1);

  // unavailable/overflow → 排除（去重）；排除只增不删——ok 不回收。
  mem.report('k','modelB','unavailable');
  mem.report('k','modelB','overflow');
  v=mem.snapshot('k');
  assert.deepEqual([...v.exclusions],['modelB']);
  mem.report('k','modelA','ok');
  v=mem.snapshot('k');
  assert.equal(v.affinity,'modelA');
  assert.deepEqual([...v.exclusions],['modelB']);
  assert.equal(v.sampleCount,4);

  // rejected → 只计数，不改亲和也不排除。
  mem.report('k','modelC','rejected');
  v=mem.snapshot('k');
  assert.equal(v.sampleCount,5);
  assert.equal(v.affinity,'modelA');
  assert.deepEqual([...v.exclusions],['modelB']);

  // TTL：每次上报刷新；过期整条清零重来。
  t=299_999;
  mem.report('k','modelA','ok');
  t=599_998;
  assert.ok(mem.snapshot('k').sampleCount>0);
  t=599_999;
  assert.equal(mem.snapshot('k').sampleCount,0);
  assert.equal(mem.snapshot('k').affinity,'');

  // 容量上限：满员后新键淘汰最旧键（FIFO 近似上游的容量上限策略）。
  const small=new RouteMemory(300_000,2,clock);
  small.report('a','m','ok');
  small.report('b','m','ok');
  small.report('c','m','ok');
  assert.equal(small.snapshot('a').sampleCount,0);
  assert.equal(small.snapshot('b').sampleCount,1);
  assert.equal(small.snapshot('c').sampleCount,1);

  console.log('PASS route memory outcomes (ok/overflow/unavailable/rejected), snapshot copy, ttl refresh, expiry reset, capacity eviction');
})().catch(e=>{console.error(e);process.exit(1);});
