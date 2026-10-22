const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

// hilog 捕获桩（断言路由/重试日志）。
const logs=[];
const hilogStub={info:(d,tag,fmt,...a)=>logs.push('I '+fmt+' | '+a.join(',')),
  warn:(d,tag,fmt,...a)=>logs.push('W '+fmt+' | '+a.join(',')),
  error:()=>{}};
const requireStub=(name)=>{
  if(name==='@kit.PerformanceAnalysisKit')return{hilog:hilogStub};
  return {};
};
// http 桩（CloudClassifier/JudgeClient 模块加载用；RouterChat 测试不发真实请求）。
const httpMember={
  createHttp(){
    return {request(){return Promise.reject(new Error('no http in router tests'));},destroy(){}};
  },
  RequestMethod:{POST:'POST'},
  HttpDataType:{STRING:'STRING'}
};
const httpStub=Object.assign({default:httpMember},httpMember);
const transpile=(file)=>{
  const moduleObject={exports:{}};
  const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,file),'utf8'),
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
    require:name=>{
      if(name==='./InferenceWire')return inferenceWire.exports;
      if(name==='./BackendRouter')return backendRouter.exports;
      if(name==='./Bandit')return bandit.exports;
      if(name==='./BanditStore')return banditStore.exports;
      if(name==='./CloudClassifier')return cloudClassifier.exports;
      if(name==='./Judge')return judgeModule.exports;
      if(name==='./XRouter')return xRouter.exports;
      if(name==='@ohos.net.http')return httpStub;
      if(name==='@kit.ArkTS')return{util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}};
      return requireStub(name);
    }},{filename:file});
  return moduleObject;
};
const inferenceWire=transpile('InferenceWire.ets');
const backendRouter=transpile('BackendRouter.ets');
const bandit=transpile('Bandit.ets');
const banditStore=transpile('BanditStore.ets');
const cloudClassifier=transpile('CloudClassifier.ets');
const judgeModule=transpile('Judge.ets');
const xRouter=transpile('XRouter.ets');
const moduleObject=transpile('RouterChat.ets');
const {RouterChat}=moduleObject.exports;
const {BanditStore,defaultStoreParams}=banditStore.exports;

const tick=()=>new Promise(r=>setTimeout(r,0));
const MSG=[{role:'user',content:'你好'}];
const makeBackend=(spec)=>({
  isBusy:()=>false,
  activeCount:()=>0,
  readinessError:()=>spec.notReady?'模型未就绪':'',
  start(messages,callback,requestId,options){
    spec.starts.push({messages,requestId,options});
    if(spec.refuse)return spec.refuse;
    const seq=spec.updates[spec.starts.length-1]||[];
    for(const u of seq)callback(u);
    return '';
  },
  cancel(){},close(){}
});
const makeRouter=(decisions,policy)=>{
  const calls=[];
  return {
    calls,
    policy:()=>policy||'xrouter',
    routeAsync:(context,status)=>{
      calls.push({context,status});
      const decision=decisions[calls.length-1];
      if(decision===undefined)throw new Error('unexpected extra route #'+calls.length);
      if(decision instanceof Error)return Promise.reject(decision);
      return Promise.resolve(decision);
    }
  };
};
const cloudDecision={side:'cloud',model:'GLM-5.3',tier:'SIMPLE',reason:'x-router: rule=escalate_cloud tier=SIMPLE source=llm'};
const localDecision={side:'local',model:'local',tier:'SIMPLE',reason:'x-router: rule=target_excluded_degrade tier=SIMPLE source=llm'};
const fail=(error,extra)=>Object.assign({kind:'done',text:'',error,finishReason:'error'},extra||{});
const run=async(rc)=>{
  const updates=[];
  rc.start(MSG,u=>updates.push(u),'req-1',{});
  for(let i=0;i<25&&!updates.some(u=>u.kind==='done');i++)await tick();
  return updates;
};

(async()=>{
  // 成功：delta+done 转发，一次路由，ok 不进排除表。
  {
    const cloud={starts:[],updates:[
      [{kind:'delta',text:'部分'},{kind:'done',text:'答案',finishReason:'stop'}],
      [{kind:'done',text:'又答',finishReason:'stop'}]
    ]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision,cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    let updates=await run(rc);
    assert.equal(updates.length,2);
    assert.equal(updates[1].text,'答案');
    assert.equal(router.calls.length,1);
    assert.equal(cloud.starts.length,1);
    await run(rc);
    assert.deepEqual([...router.calls[1].status.exclusions],[]);
    assert.ok(logs.some(l=>l.startsWith('I route side=')));
  }

  // overflow：上报排除该模型 → 同请求重路由 → 降级本地成功（react_agent 闭环）。
  {
    const cloud={starts:[],updates:[[
      fail('云端模型输出预算耗尽（思考占满上限），请简化问题或稍后重试。',{failureKind:'overflow'})
    ]]};
    const local={starts:[],updates:[[{kind:'done',text:'本地答案',finishReason:'stop'}]]};
    const router=makeRouter([cloudDecision,localDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,1);
    assert.equal(updates[0].text,'本地答案');
    assert.equal(router.calls.length,2);
    assert.deepEqual([...router.calls[1].status.exclusions],["GLM-5.3"]);
    assert.equal(cloud.starts.length,1);
    assert.equal(local.starts.length,1);
    assert.ok(logs.some(l=>l.startsWith('W backend failed')&&l.includes('GLM-5.3,overflow')));
    assert.ok(logs.some(l=>l.startsWith('I route retry ')));
  }

  // 连续失败：总尝试上限 4（上游 range(4)），最终错误原样透传。
  {
    const cloud={starts:[],updates:[
      [fail('e1')],[fail('e2')],[fail('e3')],[fail('e4',{failureKind:'overflow'})]
    ]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision,cloudDecision,cloudDecision,cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,1);
    assert.equal(updates[0].error,'e4');
    assert.equal(router.calls.length,4);
    assert.equal(cloud.starts.length,4);
  }

  // 取消：不重试、不产生观察。
  {
    const cloud={starts:[],updates:[[{kind:'done',text:'已停止生成',finishReason:'cancelled'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,1);
    assert.equal(updates[0].finishReason,'cancelled');
    assert.equal(router.calls.length,1);
  }

  // 拒收：同样上报 Unavailable 并重试（上游 invoke 抛错 → report → continue）。
  {
    const cloud={starts:[],updates:[],refuse:'算力繁忙'};
    const local={starts:[],updates:[[{kind:'done',text:'本地答案',finishReason:'stop'}]]};
    const router=makeRouter([cloudDecision,localDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates[0].text,'本地答案');
    assert.equal(router.calls.length,2);
    assert.deepEqual([...router.calls[1].status.exclusions],["GLM-5.3"]);
    assert.ok(logs.some(l=>l.startsWith('W backend refused')));
  }

  // 空 done（无错误文本）：同样判失败重试；耗尽后合成诚实文案。
  {
    const cloud={starts:[],updates:[
      [{kind:'done',text:'',finishReason:'stop'}],
      [{kind:'done',text:'',finishReason:'stop'}],
      [{kind:'done',text:'',finishReason:'stop'}],
      [{kind:'done',text:'',finishReason:'stop'}]
    ]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision,cloudDecision,cloudDecision,cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,1);
    assert.equal(updates[0].error,'模型未返回内容，请重试。');
    assert.equal(updates[0].finishReason,'stop');
    assert.equal(router.calls.length,4);
  }

  // 已流出 delta 的失败不重试（避免二次 delta 拼接乱流）。
  {
    const cloud={starts:[],updates:[[
      {kind:'delta',text:'流了一半'},fail('中途断流')
    ]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,2);
    assert.equal(updates[0].text,'流了一半');
    assert.equal(updates[1].error,'中途断流');
    assert.equal(router.calls.length,1);
    assert.equal(local.starts.length,0);
  }

  // config 策略：维持单次直连语义，失败不重试。
  {
    const cloud={starts:[],updates:[[fail('boom')]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision],'config');
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates[0].error,'boom');
    assert.equal(router.calls.length,1);
  }

  // NoTarget：决策层抛错 → 宿主兜底本地一次（外部行为同旧降级路径）。
  {
    const noTarget=new Error('no available target');noTarget.name='NoTargetError';
    const cloud={starts:[],updates:[]};
    const local={starts:[],updates:[[{kind:'done',text:'本地兜底',finishReason:'stop'}]]};
    const router=makeRouter([noTarget]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates[0].text,'本地兜底');
    assert.equal(router.calls.length,1);
    assert.equal(local.starts.length,1);
    assert.ok(logs.some(l=>l.includes('host: no-target fallback local')));
  }

  // 普通决策异常：守门文案不变（护栏）。
  {
    const cloud={starts:[],updates:[]};
    const local={starts:[],updates:[]};
    const router=makeRouter([new Error('decision boom')]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=await run(rc);
    assert.equal(updates.length,1);
    assert.equal(updates[0].error,'路由决策失败，请重试。');
    assert.equal(updates[0].finishReason,'error');
  }

  // 图片宿主预检（xrouter 策略）：不进路由决策，直接钉本地。
  {
    const cloud={starts:[],updates:[]};
    const local={starts:[],updates:[[{kind:'done',text:'看图作答',finishReason:'stop'}]]};
    const router=makeRouter([localDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=[];
    rc.start(MSG,u=>updates.push(u),'req-img',{image:'b64'});
    for(let i=0;i<25&&!updates.some(u=>u.kind==='done');i++)await tick();
    assert.equal(updates[0].text,'看图作答');
    assert.equal(router.calls.length,0);          // routeAsync 未被调用
    assert.equal(local.starts.length,1);
    assert.ok(logs.some(l=>l.includes('host: rule=image_local')));
  }

  // 图片预检单发：本地拒收不重试（一次错误回调）。
  {
    const cloud={starts:[],updates:[]};
    const local={starts:[],updates:[],refuse:'本地未就绪'};
    const router=makeRouter([]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=[];
    rc.start(MSG,u=>updates.push(u),'req-img2',{image:'b64'});
    for(let i=0;i<25&&!updates.some(u=>u.kind==='done');i++)await tick();
    assert.equal(updates[0].error,'本地未就绪');
    assert.equal(local.starts.length,1);          // 单发，不重试
    assert.equal(router.calls.length,0);
  }

  // config 策略带图：不走预检，决策照常（策略门控护栏）。
  {
    const cloud={starts:[],updates:[[{kind:'done',text:'云答',finishReason:'stop'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision],'config');
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router);
    const updates=[];
    rc.start(MSG,u=>updates.push(u),'req-img3',{image:'b64'});
    for(let i=0;i<25&&!updates.some(u=>u.kind==='done');i++)await tick();
    assert.equal(updates[0].text,'云答');
    assert.equal(router.calls.length,1);
    assert.equal(cloud.starts.length,1);
  }

  // —— settle 闭环（service 注入，上游 XRouterService 语义）——
  const makeService=over=>{
    const service=Object.assign({
      store:new BanditStore(defaultStoreParams()),
      judge:null,banditEnabled:false,previewChars:6000,queueCap:256
    },over||{});
    return service;
  };
  const waitSettle=async(rc,pred)=>{for(let i=0;i<50&&!pred(rc.serviceStats());i++)await tick();};

  // done-ok → judge 打分 → store 关记录；bandit 关 → 不填 context.retrieved。
  {
    const cloud={starts:[],updates:[[{kind:'delta',text:'部分'},{kind:'done',text:'答案文本',finishReason:'stop'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const judged=[];
    const service=makeService({judge:{scoreAsync(req){
      judged.push(req);
      return Promise.resolve('{"task_progress":0.6,"correctness":0.4,"grounding":0.2}');
    }}});
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,service);
    const updates=await run(rc);
    assert.equal(updates[1].text,'答案文本');
    assert.equal(router.calls[0].context.retrieved,undefined);   // bandit 关 → 仅开 pending
    await waitSettle(rc,s=>s.settled===1);
    const stats=rc.serviceStats();
    assert.equal(stats.settled,1);
    assert.equal(stats.judgeFailed,0);
    assert.equal(stats.store.closed,1);
    assert.equal(stats.store.pending,0);
    assert.equal(stats.store.unknown,0);
    assert.equal(judged.length,1);
    assert.ok(judged[0].userPrompt.includes('[user]: 你好'));
    assert.ok(judged[0].userPrompt.includes('答案文本'));
    assert.ok(judged[0].systemPrompt.includes('strict evaluator'));
    assert.ok(logs.some(l=>l.includes('judge settled quality=')&&l.includes('0.45')));
    assert.ok(logs.some(l=>l.includes('judge settled')&&l.includes('req-1#1')));
    assert.ok(logs.some(l=>l.includes('store stats pending=')&&l.includes('| 0,1,')));
  }

  // judge 失败 → 只计数 judgeFailed，pending 留给 TTL，聊天回调不受影响。
  {
    const cloud={starts:[],updates:[[{kind:'done',text:'答案',finishReason:'stop'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const service=makeService({judge:{scoreAsync:()=>Promise.reject(new Error('judge down'))}});
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,service);
    const updates=await run(rc);
    assert.equal(updates[0].text,'答案');
    await waitSettle(rc,s=>s.judgeFailed===1);
    const stats=rc.serviceStats();
    assert.equal(stats.judgeFailed,1);
    assert.equal(stats.settled,0);
    assert.equal(stats.store.pending,1);   // 无质量可报，未关
    assert.equal(stats.store.closed,0);
  }

  // judge null（store-only service）→ 不评分，仅开两阶段记录。
  {
    const cloud={starts:[],updates:[[{kind:'done',text:'答案',finishReason:'stop'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,makeService({}));
    await run(rc);
    const stats=rc.serviceStats();
    assert.equal(stats.submitted,0);
    assert.equal(stats.store.pending,1);
    assert.equal(stats.store.closed,0);
  }

  // queueCap=1 + 永不返回的 judge + 两连发 → 第二发 droppedFull。
  {
    const never=new Promise(()=>{});
    const cloud={starts:[],updates:[
      [{kind:'done',text:'一',finishReason:'stop'}],
      [{kind:'done',text:'二',finishReason:'stop'}]
    ]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision,cloudDecision]);
    const service=makeService({judge:{scoreAsync:()=>never},queueCap:1});
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,service);
    let updates=await run(rc);
    assert.equal(updates[0].text,'一');
    updates=await run(rc);
    assert.equal(updates[0].text,'二');
    const stats=rc.serviceStats();
    assert.equal(stats.submitted,1);
    assert.equal(stats.droppedFull,1);
    assert.equal(stats.inflight,1);
    assert.equal(stats.store.pending,2);   // 两发各自开了 pending，均未关
  }

  // routeId 唯一性：溢出重试 → 首试 pending 未关（失败不评分）、重试已关。
  {
    const cloud={starts:[],updates:[
      [fail('云端模型输出预算耗尽（思考占满上限），请简化问题或稍后重试。',{failureKind:'overflow'})]
    ]};
    const local={starts:[],updates:[[{kind:'done',text:'本地答案',finishReason:'stop'}]]};
    const router=makeRouter([cloudDecision,localDecision]);
    const service=makeService({judge:{scoreAsync:()=>Promise.resolve('{"correctness":0.5}')}});
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,service);
    const updates=await run(rc);
    assert.equal(updates[0].text,'本地答案');
    await waitSettle(rc,s=>s.settled===1);
    const stats=rc.serviceStats();
    assert.equal(stats.settled,1);
    assert.equal(stats.store.closed,1);    // 重试 routeId 已关
    assert.equal(stats.store.pending,1);   // 首试 routeId 未关
    assert.equal(stats.store.unknown,0);   // 无孤儿观察 = routeId 管道正确
  }

  // banditEnabled → context.retrieved 由 store 近邻填充。
  {
    const cloud={starts:[],updates:[[{kind:'done',text:'答',finishReason:'stop'}]]};
    const local={starts:[],updates:[]};
    const router=makeRouter([cloudDecision]);
    const service=makeService({banditEnabled:true});
    service.store.query('default','the quick brown fox jumps','warm1');
    service.store.reportObservation('warm1','SIMPLE',0.9,0);
    const rc=new RouterChat(makeBackend(local),makeBackend(cloud),router,service);
    const updates=[];
    rc.start([{role:'user',content:'the quick brown fox jumps'}],u=>updates.push(u),'req-b',{});
    for(let i=0;i<25&&!updates.some(u=>u.kind==='done');i++)await tick();
    assert.equal(updates[0].text,'答');
    const retrieved=router.calls[0].context.retrieved;
    assert.ok(Array.isArray(retrieved));
    assert.equal(retrieved.length,1);
    assert.equal(retrieved[0].id,'r0');
  }

  console.log('PASS router chat: success, overflow exclude+degrade retry, attempt cap, cancelled, refusal retry, empty-done synthesis, partial-stream no-retry, config passthrough, no-target fallback, decision-error guard, image precheck, settle loop (scored/fail/dropped-full/route-id-uniqueness/bandit-retrieved)');
})().catch(e=>{console.error(e);process.exit(1);});
