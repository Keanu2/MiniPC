const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

const transpile=(file,stubs)=>{
  const moduleObject={exports:{}};
  const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,file),'utf8'),
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
    require:name=>(stubs||{})[name]||({})},{filename:file});
  return moduleObject;
};
const backendRouter=transpile('BackendRouter.ets',{
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
  '@kit.CoreFileKit':{fileIo:{readTextSync(){throw new Error('no file');}}}
});
const banditModule=transpile('Bandit.ets',{'./BackendRouter':backendRouter.exports});
const {
  chooseTier,parseObservations,aggregate,utilities,TierEvidence,defaultBanditParams,
  BANDIT_COLD,BANDIT_SAME,BANDIT_IGNORE,BANDIT_OVERRIDE
}=banditModule.exports;

const obs=(quality,costUsd)=>({quality,costUsd});
const item=(score,data)=>({id:'x',score,data:new Map(Object.entries(data))});

(async()=>{
  const p=defaultBanditParams();
  assert.equal(p.minNeighbors,5);
  assert.equal(p.margin,0.3);
  assert.equal(p.lambdaC,0.2);
  assert.equal(p.costRefUsd,0.005);

  // —— chooseTier ——
  // 冷启动：无邻居。
  let c=chooseTier('SIMPLE',[],p);
  assert.equal(c.tier,'SIMPLE');assert.equal(c.code,BANDIT_COLD);assert.equal(c.neighbours,0);
  // 邻居不足门槛（4<5）。
  const fourM=[item(1,{MEDIUM:obs(0.9,0)}),item(1,{MEDIUM:obs(0.8,0)}),
    item(1,{MEDIUM:obs(0.7,0)}),item(1,{MEDIUM:obs(0.6,0)})];
  c=chooseTier('COMPLEX',fourM,p);
  assert.equal(c.code,BANDIT_COLD);assert.equal(c.neighbours,4);

  const five=data=>[1,2,3,4,5].map(()=>item(1,data));
  // incumbent 档无证据 → ignore（即便别档有高分）。
  c=chooseTier('SIMPLE',five({MEDIUM:obs(0.9,0)}),p);
  assert.equal(c.code,BANDIT_IGNORE);assert.equal(c.tier,'SIMPLE');assert.equal(c.neighbours,5);
  // 无更高档 → same。
  c=chooseTier('SIMPLE',five({SIMPLE:obs(0.9,0)}),p);
  assert.equal(c.code,BANDIT_SAME);
  // 候选与 incumbent 平手 → 严格 > 不替换 → same。
  c=chooseTier('SIMPLE',five({SIMPLE:obs(0.7,0),MEDIUM:obs(0.7,0)}),p);
  assert.equal(c.code,BANDIT_SAME);
  // 更高档显著占优 → override。
  c=chooseTier('SIMPLE',five({SIMPLE:obs(0.1,0),MEDIUM:obs(0.8,0)}),p);
  assert.equal(c.code,BANDIT_OVERRIDE);assert.equal(c.tier,'MEDIUM');
  // 优势恰等于 margin → ignore（≤，单条目避免浮点累计）。
  const p1=Object.assign(defaultBanditParams(),{minNeighbors:1});
  c=chooseTier('SIMPLE',[item(1,{SIMPLE:obs(0,0),MEDIUM:obs(0.3,0)})],p1);
  assert.equal(c.code,BANDIT_IGNORE);assert.equal(c.tier,'SIMPLE');
  // 两候选平手 → 取更低档（升序遍历 + 严格 >）。
  c=chooseTier('SIMPLE',five({SIMPLE:obs(0.5,0),MEDIUM:obs(0.9,0),COMPLEX:obs(0.9,0)}),p);
  assert.equal(c.code,BANDIT_OVERRIDE);assert.equal(c.tier,'MEDIUM');

  // —— utilities ——
  const ev1=new TierEvidence();ev1.add(1,0.9,0.01);
  const ev2=new TierEvidence();ev2.add(2,0.8,null);   // 无成本报告
  const evidence=new Map();
  evidence.set('SIMPLE',ev1);evidence.set('MEDIUM',ev2);
  let u=utilities(evidence,p);
  // SIMPLE: 0.9 − 0.2·0.01/0.005 = 0.5；MEDIUM 无成本且 λ>0 → 剔除。
  assert.ok(Math.abs(u.get('SIMPLE')-0.5)<1e-9);
  assert.ok(!u.has('MEDIUM'));
  // λ=0 → MEDIUM 保留为纯质量。
  const p0=Object.assign(defaultBanditParams(),{lambdaC:0});
  u=utilities(evidence,p0);
  assert.ok(Math.abs(u.get('MEDIUM')-0.8)<1e-9);
  assert.ok(Math.abs(u.get('SIMPLE')-0.9)<1e-9);

  // —— parseObservations ——
  let po=parseObservations(null);
  assert.equal(po.size,0);
  po=parseObservations(new Map([['complex',obs(0.5,0)]]));
  assert.equal(po.size,1);assert.equal(po.get('COMPLEX').quality,0.5);
  po=parseObservations(new Map([['UNKNOWN',obs(0.5,0)],['MEDIUM',obs(0.5,0)]]));
  assert.equal(po.size,1);assert.ok(po.has('MEDIUM'));
  po=parseObservations(new Map([['MEDIUM',obs(Number.NaN,0)]]));
  assert.equal(po.size,0);
  po=parseObservations(new Map([['MEDIUM',obs(0.5,-1)]]));
  assert.equal(po.get('MEDIUM').costUsd,null);
  po=parseObservations(new Map([['MEDIUM',obs(0.5,Number.POSITIVE_INFINITY)]]));
  assert.equal(po.get('MEDIUM').costUsd,null);
  po=parseObservations(new Map([['MEDIUM',obs(0.5,null)]]));
  assert.equal(po.get('MEDIUM').costUsd,null);
  assert.equal(po.get('MEDIUM').quality,0.5);

  // —— aggregate ——
  let a=aggregate([item(0,{MEDIUM:obs(0.5,0)}),item(-1,{MEDIUM:obs(0.5,0)}),
    item(Number.NaN,{MEDIUM:obs(0.5,0)}),item(1,{})]);
  assert.equal(a.neighbours,0);assert.equal(a.evidence.size,0);
  a=aggregate([item(1,{MEDIUM:obs(1,0)}),item(3,{MEDIUM:obs(0.5,0)})]);
  assert.equal(a.neighbours,2);
  const m=a.evidence.get('MEDIUM');
  assert.equal(m.count,2);assert.equal(m.weight,4);
  assert.ok(Math.abs(m.meanQuality()-(1*1+3*0.5)/4)<1e-9);
  assert.equal(m.meanCost(),0);

  // —— TierEvidence 零权重 ——
  const zero=new TierEvidence();
  assert.equal(zero.meanQuality(),null);assert.equal(zero.meanCost(),null);
  const noCost=new TierEvidence();noCost.add(1,0.5,null);
  assert.equal(noCost.meanCost(),null);assert.equal(noCost.meanQuality(),0.5);

  console.log('PASS bandit pure functions (choose_tier/aggregate/utilities/parse_observations/TierEvidence)');
})().catch(e=>{console.error(e);process.exit(1);});
