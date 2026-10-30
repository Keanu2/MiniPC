const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

const arkTs={util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}};
const transpile=(file,stubs)=>{
  const moduleObject={exports:{}};
  const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,file),'utf8'),
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
    require:name=>(stubs||{})[name]||({})},{filename:file});
  return moduleObject;
};
const inferenceWire=transpile('InferenceWire.ets',{'@kit.ArkTS':arkTs});
const backendRouter=transpile('BackendRouter.ets',{
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
  '@kit.CoreFileKit':{fileIo:{readTextSync(){throw new Error('no file');}}}
});
const banditModule=transpile('Bandit.ets',{'./BackendRouter':backendRouter.exports});
const storeModule=transpile('BanditStore.ets',{
  './InferenceWire':inferenceWire.exports,
  './BackendRouter':backendRouter.exports,
  './Bandit':banditModule.exports
});
const {BanditStore,defaultStoreParams,fnv1a}=storeModule.exports;
const {chooseTier,BANDIT_OVERRIDE,defaultBanditParams}=banditModule.exports;

const params=over=>Object.assign(defaultStoreParams(),over||{});
const nonzeros=v=>{const nz=[];for(let i=0;i<v.length;i++)if(v[i]!==0)nz.push(i);return nz;};

(async()=>{
  // —— FNV-1a 金标准（上游 _fnv1a 逐字节核对，桶=hash%4096）——
  const GOLD={'abc':2315,'bcd':1826,'a':2348,'ab':1482,'你':3806,'好':518,'你好':3491};
  for(const [gram,bucket] of Object.entries(GOLD)){
    assert.equal(fnv1a(gram)%4096,bucket,gram);
  }

  // —— encode ——
  let st=new BanditStore(params(),()=>0);
  let v=st.encode('abc');
  assert.equal(v.length,4096);
  assert.deepEqual(nonzeros(v),[2315]);
  assert.ok(Math.abs(v[2315]-1)<1e-6);
  v=st.encode('abcd');
  assert.ok(Math.abs(v[2315]-Math.SQRT1_2)<1e-6);
  assert.ok(Math.abs(v[1826]-Math.SQRT1_2)<1e-6);
  v=st.encode('你好');
  assert.deepEqual(nonzeros(v),[3491]);
  // 确定性（两次独立实例）。
  const first=st.encode('hello world');
  const again=new BanditStore(params(),()=>0).encode('hello world');
  for(let i=0;i<4096;i++)assert.equal(first[i],again[i]);
  // 空白折叠等价。
  const w1=st.encode('  A\nb  C '),w2=st.encode('a b c');
  for(let i=0;i<4096;i++)assert.equal(w1[i],w2[i]);
  // 纯空白 → 零向量。
  assert.deepEqual(nonzeros(st.encode('   ')),[]);
  // 小维度取模落桶。
  const small=new BanditStore(params({retrieverDim:8}),()=>0);
  assert.deepEqual(nonzeros(small.encode('abc')),[2315%8]);
  assert.deepEqual(nonzeros(small.encode('bcd')),[1826%8]);

  // —— 每键 call 状态（原 RouteMemory 用例收编；TTL 边界改上游严格 >）——
  let t=0;const clock=()=>t;
  st=new BanditStore(params(),clock);
  let view=st.snapshot('k');
  assert.equal(view.sampleCount,0);assert.equal(view.affinity,'');assert.equal(view.exclusions.length,0);
  st.reportCall('k','modelA','ok');
  view=st.snapshot('k');
  assert.equal(view.sampleCount,1);assert.equal(view.affinity,'modelA');assert.equal(view.exclusions.length,0);
  view.exclusions.push('hacked');view.sampleCount=99;   // 快照副本，外部改写不穿透。
  assert.equal(st.snapshot('k').exclusions.length,0);
  assert.equal(st.snapshot('k').sampleCount,1);
  st.reportCall('k','modelB','unavailable');
  st.reportCall('k','modelB','overflow');               // 排除去重。
  view=st.snapshot('k');
  assert.deepEqual([...view.exclusions],['modelB']);
  st.reportCall('k','modelA','ok');                     // ok 不回收排除。
  view=st.snapshot('k');
  assert.equal(view.affinity,'modelA');assert.deepEqual([...view.exclusions],['modelB']);
  assert.equal(view.sampleCount,4);
  st.reportCall('k','modelC','rejected');               // rejected 仅计数。
  view=st.snapshot('k');
  assert.equal(view.sampleCount,5);assert.equal(view.affinity,'modelA');
  assert.deepEqual([...view.exclusions],['modelB']);
  st.reportCall('k','','overflow');                     // 空模型 id 不进排除。
  assert.deepEqual([...st.snapshot('k').exclusions],['modelB']);
  // TTL 每报刷新 + 严格 > 边界。
  t=299_999;st.reportCall('k','modelA','ok');
  t=599_998;assert.ok(st.snapshot('k').sampleCount>0);
  t=599_999;assert.ok(st.snapshot('k').sampleCount>0);  // 恰 touchedAt+ttl → 存活。
  t=600_000;assert.equal(st.snapshot('k').sampleCount,0);
  assert.equal(st.snapshot('k').affinity,'');           // +1ms → 删。
  // 已读删除后的上报 → 重建。
  t=1_000_000;st.reportCall('k','modelZ','ok');
  view=st.snapshot('k');
  assert.equal(view.sampleCount,1);assert.equal(view.affinity,'modelZ');
  assert.deepEqual([...view.exclusions],[]);
  // 过期但未读 → 上报同样重建（上游 _absorb_call_locked；旧 RouteMemory 会延续旧排除表）。
  t=1_300_001;st.reportCall('k','modelY','overflow');
  view=st.snapshot('k');
  assert.equal(view.sampleCount,1);assert.deepEqual([...view.exclusions],['modelY']);

  // —— 两阶段记录（query 开 pending → reportObservation 关）——
  t=0;
  st=new BanditStore(params({retrieverDim:64}),clock);
  let q=st.query('k','hello world','r1');
  assert.equal(st.stats().pending,1);
  assert.equal(q.retrieved.length,0);
  st.reportObservation('r1','COMPLEX',0.5,0.0);
  let s=st.stats();
  assert.equal(s.pending,0);assert.equal(s.closed,1);assert.equal(s.unknown,0);
  q=st.query('k','hello world','r2');
  assert.equal(q.retrieved.length,1);
  assert.equal(q.retrieved[0].id,'r0');
  assert.ok(Math.abs(q.retrieved[0].score-1)<1e-6);
  assert.equal(q.retrieved[0].data.get('COMPLEX').quality,0.5);
  assert.equal(st.stats().pending,1);                   // r1 已关，r2 已开。
  st.query('k','hello world','');                       // 空 routeId 不开 pending。
  assert.equal(st.stats().pending,1);
  q=st.query('k','   ','r3');                           // 空白文本仅视图。
  assert.equal(q.retrieved.length,0);
  assert.equal(st.stats().pending,1);
  st.openPending('r4','some other text');               // 宿主优化口：只开记录不算近邻。
  assert.equal(st.stats().pending,2);
  st.reportObservation('r4','SIMPLE',-0.2,0.0);
  st.reportObservation('nope','SIMPLE',0.1,0.0);        // 未知 id → unknown++。
  assert.equal(st.stats().unknown,1);
  // 非法观察抛错（quality 越界/NaN、cost 负、未知档），且不计 unknown。
  assert.throws(()=>st.reportObservation('x','SIMPLE',Number.NaN,0));
  assert.throws(()=>st.reportObservation('x','SIMPLE',1.5,0));
  assert.throws(()=>st.reportObservation('x','SIMPLE',-2,0));
  assert.throws(()=>st.reportObservation('x','SIMPLE',0.1,-1));
  assert.throws(()=>st.reportObservation('x','BOGUS',0.1,0));
  assert.equal(st.stats().unknown,1);

  // —— 近邻：topK 截断与 minSimilarity 过滤 ——
  t=0;
  st=new BanditStore(params({topK:1}),clock);
  st.query('k','alpha beta gamma','a1');st.reportObservation('a1','SIMPLE',0.9,0);
  st.query('k','alpha beta gamma delta epsilon','b1');st.reportObservation('b1','SIMPLE',0.1,0);
  q=st.query('k','alpha beta gamma','c1');
  assert.equal(q.retrieved.length,1);                   // 两条都可能过阈值，但 topK=1 只取最相似。
  assert.equal(q.retrieved[0].id,'r0');
  st=new BanditStore(params({minSimilarity:0.99}),clock);
  st.query('k','alpha beta gamma','a1');st.reportObservation('a1','SIMPLE',0.9,0);
  q=st.query('k','alpha beta gamma delta','b1');
  assert.equal(q.retrieved.length,0);                   // 相似但低于阈值。

  // —— pending TTL：节流窗口 + expirePending 强扫 ——
  t=0;
  st=new BanditStore(params({pendingTtlMs:20_000}),clock);   // 窗口=clamp(2000,1000,60000)=2000。
  st.query('k','one','p1');                                  // t=0 节流。
  t=2_500;st.query('k','two','p2');                          // 扫：lastSweep=2500。
  t=19_500;st.query('k','three','p3');                       // 扫：lastSweep=19500。
  assert.equal(st.stats().pending,3);assert.equal(st.stats().dropped,0);
  t=20_500;st.query('k','four','p4');                        // p1 已过期但在窗口内 → 节流不清。
  assert.equal(st.stats().pending,4);assert.equal(st.stats().dropped,0);
  assert.equal(st.expirePending(),1);                        // 强扫绕过节流。
  assert.equal(st.stats().pending,3);assert.equal(st.stats().dropped,1);

  // pending 超 maxEntries → 窗口内强扫。
  t=0;
  st=new BanditStore(params({maxEntries:2,pendingTtlMs:10}),clock);  // 窗口=1000。
  st.query('k','one','p1');
  t=300;st.query('k','two','p2');
  assert.equal(st.stats().dropped,0);
  t=600;st.query('k','three','p3');                          // 3>2 强扫；p1/p2 已过 ttl(600>10)。
  assert.equal(st.stats().dropped,2);
  assert.equal(st.stats().pending,1);

  // —— 记录 FIFO（maxEntries=2，关 3 条淘汰最老）——
  t=0;
  st=new BanditStore(params({maxEntries:2}),clock);
  const close=(id,text,tier)=>{st.query('k',text,id);st.reportObservation(id,tier,0.5,0);};
  close('a1','alpha beta gamma','SIMPLE');
  close('b1','some other stuff','MEDIUM');
  close('c1','more different words','COMPLEX');
  assert.equal(st.stats().closed,2);
  q=st.query('k','alpha beta gamma','d1');                   // 最老已淘汰，与后两条无共享 gram。
  assert.equal(q.retrieved.length,0);

  // —— 端到端：store retrieved 喂 chooseTier → override ——
  t=0;
  st=new BanditStore(params(),clock);
  for(let i=1;i<=5;i++){
    st.query('k','the quick brown fox jumps','q'+i);
    st.reportObservation('q'+i,i<=3?'SIMPLE':'MEDIUM',i<=3?0.1:0.9,0.0);
  }
  q=st.query('k','the quick brown fox jumps','q6');
  const choice=chooseTier('SIMPLE',q.retrieved,defaultBanditParams());
  assert.equal(choice.code,BANDIT_OVERRIDE);
  assert.equal(choice.tier,'MEDIUM');
  assert.equal(choice.neighbours,5);

  console.log('PASS bandit store (fnv1a goldens, encode, call state, two-phase records, neighbours, ttl sweep, fifo, end-to-end choose)');
})().catch(e=>{console.error(e);process.exit(1);});
