const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

// 虚拟文件系统（fileIo 桩）与 http 桩（CloudClassifier 用）。
const files={};
const httpState={nextResponse:null,fail:false,onRequest:null};
const httpMember={
  createHttp(){
    return {
      request(url,options){
        if(httpState.onRequest)httpState.onRequest(url,options);
        if(httpState.fail)return Promise.reject(new Error('network down'));
        return Promise.resolve(httpState.nextResponse||{responseCode:200,result:'{}'});
      },
      destroy(){}
    };
  },
  RequestMethod:{POST:'POST'},
  HttpDataType:{STRING:'STRING'}
};
const httpStub=Object.assign({default:httpMember},httpMember);

const transpile=file=>{
  const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,file),'utf8'),
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const moduleObject={exports:{}};
  vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
    require(name){
      if(name==='@kit.PerformanceAnalysisKit')return{hilog:{info(){},warn(){},error(){}}};
      if(name==='@kit.CoreFileKit')return{fileIo:{readTextSync:p=>{
        if(!(p in files))throw new Error('no such file: '+p);
        return files[p];
      }}};
      if(name==='@ohos.net.http')return httpStub;
      if(name==='./CloudClassifier')return cloudModule.exports;
      if(name==='./BackendRouter')return backendModule.exports;
      if(name==='./Bandit')return banditModule.exports;
      if(name==='./BanditStore')return banditStoreModule.exports;
      if(name==='@kit.ArkTS')return{util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}};
      if(name==='./InferenceWire')return inferenceWire.exports;
      return{};
    }},{filename:file});
  return moduleObject;
};
const inferenceWire=transpile('InferenceWire.ets');
const cloudModule=transpile('CloudClassifier.ets');
const backendModule=transpile('BackendRouter.ets');
const banditModule=transpile('Bandit.ets');
const banditStoreModule=transpile('BanditStore.ets');
const moduleObject=transpile('XRouter.ets');
const {XRouter,TIER_ORDER,NoTargetError}=moduleObject.exports;
const {defaultBanditParams}=banditModule.exports;
const {CloudClassifier}=cloudModule.exports;

const msg=(role,content)=>({role,content});
const ctx=(messages,image)=>({messages:messages||[msg('user','你好')],promptChars:2,image:image||'',maxTokens:0});
const ready=exclusions=>({localReady:true,localBusy:false,cloudReady:true,cloudBusy:false,exclusions:exclusions||[]});
const noCloud=()=>({localReady:true,localBusy:false,cloudReady:false,cloudBusy:false,exclusions:[]});
const noneReady=()=>({localReady:false,localBusy:false,cloudReady:false,cloudBusy:false,exclusions:[]});
const TIER_MODELS=new Map([['COMPLEX','GLM-5.3']]);
const params=(level,extra)=>Object.assign(
  {localCapabilityLevel:level,tierModels:TIER_MODELS,previewChars:6000,backend:null,shadow:false},extra||{});

(async()=>{
  // 档位次序与秩。
  assert.equal(TIER_ORDER.length,5);
  assert.equal(TIER_ORDER[0],'SIMPLE');
  assert.equal(TIER_ORDER[2],'COMPLEX');
  assert.equal(TIER_ORDER[4],'REASONING');
  assert.equal(XRouter.tierRank('SIMPLE'),0);
  assert.equal(XRouter.tierRank('MEDIUM'),1);
  assert.equal(XRouter.tierRank('REASONING'),4);

  // 严格单标签解析：恰一个档名（大小写/首尾空白容忍），散文与多标签一律拒绝。
  assert.equal(XRouter.parseTier('SIMPLE'),'SIMPLE');
  assert.equal(XRouter.parseTier('  simple '),'SIMPLE');
  assert.equal(XRouter.parseTier('Research'),'RESEARCH');
  assert.equal(XRouter.parseTier('you should use COMPLEX'),'');
  assert.equal(XRouter.parseTier('SIMPLE MEDIUM'),'');
  assert.equal(XRouter.parseTier(''),'');

  // 对话视图：system 与 system-reminder 脚手架、空消息均剔除。
  const view=XRouter.conversationView([
    msg('system','prove the theorem'),
    msg('user',' <system-reminder>xx<prompt-attachment>y</prompt-attachment></system-reminder>'),
    msg('user','你好'),
    msg('user','   ')
  ]);
  assert.equal(view.length,1);
  assert.equal(view[0].role,'user');
  assert.equal(view[0].content,'你好');

  // 预览：[role]: text 逐行；窗口 6 条；最新 user 轮被挤出窗口时重新置顶；超预算中段截断。
  assert.equal(XRouter.conversationPreview([msg('user','你好')],6000),'[user]: 你好');
  const eight=[...Array(8)].map((_,i)=>msg(i%2?'assistant':'user','m'+i));
  const p1=XRouter.conversationPreview(eight,6000);
  assert.ok(p1.includes('m2')&&p1.includes('m7'));
  assert.ok(!p1.includes('m0')&&!p1.includes('m1'));
  const seven=[msg('user','first question'),msg('assistant','a1'),msg('assistant','a2'),
    msg('assistant','a3'),msg('assistant','a4'),msg('assistant','a5'),msg('assistant','a6')];
  const p2=XRouter.conversationPreview(seven,6000);
  assert.ok(p2.startsWith('[user]: first question'));
  assert.ok(p2.includes('a6'));
  assert.ok(!p2.includes('a1'));
  const p3=XRouter.conversationPreview([msg('user','x'.repeat(3000))],1000);
  assert.equal(p3.length,1000);
  assert.ok(p3.includes('\n...[truncated]...\n'));
  assert.ok(p3.startsWith('[user]: xxx')&&p3.endsWith('xxx'));

  // 分类器 prompt：上游模板逐字 + 预览注入；全脚手架对话抛错。
  const prompt=XRouter.buildClassifierPrompt([msg('user','你好')],6000);
  assert.ok(prompt.startsWith('Classify the work needed'));
  assert.ok(prompt.includes('Conversation and recent progress:\n[user]: 你好'));
  assert.ok(prompt.endsWith('Reply with ONLY the tier name.'));
  assert.throws(()=>XRouter.buildClassifierPrompt([msg('system','sys')],6000),/non-empty/);

  // 启发式（上游英文冻结集 + 空白分词，无中文扩充）。
  const heur=new XRouter(params('NONE'));
  const tierOf=messages=>heur.classifyHeuristic(ctx(messages));
  assert.equal(tierOf([msg('user','你好')]),'SIMPLE');
  // 中文无关键词命中（上游对中文同样失明，由 LLM 分类器主路径覆盖）。
  assert.equal(tierOf([msg('user','帮我写一个登录页面')]),'SIMPLE');
  assert.equal(tierOf([msg('user','帮我对比分析这两个方案的优劣')]),'SIMPLE');
  assert.equal(tierOf([msg('user','please prove that the sum equals n(n+1)/2')]),'REASONING');
  assert.equal(tierOf([msg('user','step by step guide across all files')]),'COMPLEX');
  assert.equal(tierOf([msg('user','please summarize this document')]),'MEDIUM');
  assert.equal(tierOf([msg('user','write a function to parse json')]),'MEDIUM');
  assert.equal(tierOf([msg('user','survey paper on transformer architecture')]),'RESEARCH');
  // 词数阈值（空白分词，上游冻结 80/400/1200）。
  assert.equal(tierOf([msg('user','好'.repeat(130))]),'SIMPLE');
  assert.equal(tierOf([msg('user','lorem '.repeat(81).trim())]),'MEDIUM');
  assert.equal(tierOf([msg('user','lorem '.repeat(401).trim())]),'COMPLEX');
  assert.equal(tierOf([msg('user','lorem '.repeat(1201).trim())]),'RESEARCH');
  // user 轮次与问号数阈值（2/6/3）。
  assert.equal(tierOf([msg('user','你好'),msg('assistant','好'),msg('user','在吗'),
    msg('assistant','在'),msg('user','嗯')]),'MEDIUM');
  assert.equal(tierOf([msg('user','在吗？吃了吗？睡了吗？好吗？')]),'COMPLEX');
  // 脚手架不参与特征。
  assert.equal(tierOf([msg('system','prove the theorem'),msg('',''),msg('user','你好')]),'SIMPLE');

  // 决策规则与 reason 格式（对齐上游 "x-router: rule=… tier=… source=…"）。
  const decide=(router,messages,status,image)=>router.decideAsync(ctx(messages,image),status);
  let d=await decide(new XRouter(params('NONE')),[msg('user','你好')],ready());
  assert.equal(d.side,'cloud');
  assert.equal(d.model,'GLM-5.3');
  assert.equal(d.tier,'SIMPLE');
  assert.equal(d.reason,'x-router: rule=escalate_cloud tier=SIMPLE source=heuristic');
  d=await decide(new XRouter(params('SIMPLE')),[msg('user','你好')],ready());
  assert.equal(d.side,'local');
  assert.equal(d.model,'local');
  assert.equal(d.reason,'x-router: rule=within_local_capability tier=SIMPLE source=heuristic');
  // 未配置档位回退 COMPLEX 模型；已配置档位用专属模型。
  const models2=new Map([['COMPLEX','fast'],['RESEARCH','deep'],['REASONING','deep']]);
  const r2=new XRouter(params('NONE',{tierModels:models2}));
  d=await decide(r2,[msg('user','你好')],ready());
  assert.equal(d.model,'fast');
  d=await decide(r2,[msg('user','please prove the theorem')],ready());
  assert.equal(d.model,'deep');
  assert.equal(d.tier,'REASONING');

  // 降级路径：云模型被状态排除 → 降级本地；云侧未就绪同理。
  d=await decide(new XRouter(params('NONE')),[msg('user','你好')],ready(['GLM-5.3']));
  assert.equal(d.side,'local');
  assert.equal(d.model,'local');
  assert.equal(d.reason,'x-router: rule=target_excluded_degrade tier=SIMPLE source=heuristic');
  d=await decide(new XRouter(params('NONE')),[msg('user','你好')],noCloud());
  assert.equal(d.side,'local');
  assert.equal(d.reason,'x-router: rule=target_excluded_degrade tier=SIMPLE source=heuristic');
  // 上游 quirk：本地被排除时 within_local_capability 经 _pick 落到目录首个目标（云模型）。
  d=await decide(new XRouter(params('SIMPLE')),[msg('user','你好')],ready(['local']));
  assert.equal(d.side,'cloud');
  assert.equal(d.model,'GLM-5.3');
  assert.equal(d.reason,'x-router: rule=within_local_capability tier=SIMPLE source=heuristic');
  // 双侧无目标：决策层抛 NoTargetError（上游 RouterError::NoTarget，宿主兜底）。
  await assert.rejects(
    decide(new XRouter(params('NONE')),[msg('user','你好')],noneReady()),
    (e)=>e instanceof NoTargetError&&e.message==='no available target');
  // 带图不再由决策层钉端侧（宿主 RouterChat 预检接管），照常分类决策。
  d=await decide(new XRouter(params('NONE')),[msg('user','看图')],ready(),'b64');
  assert.equal(d.side,'cloud');
  assert.equal(d.model,'GLM-5.3');
  assert.equal(d.reason,'x-router: rule=escalate_cloud tier=SIMPLE source=heuristic');

  // retrieval_text：预览格式 + 16KB 字节上限（码点边界，无半个码点截断）。
  let rt=XRouter.retrievalText([msg('user','你好'),msg('assistant','好呀')],6000);
  assert.ok(rt.startsWith('[user]: '));
  assert.ok(rt.includes('[assistant]: 好呀'));
  rt=XRouter.retrievalText([msg('user','a'.repeat(500))],100);
  assert.ok(rt.length<200&&rt.includes('...[truncated]...'));
  rt=XRouter.retrievalText([msg('user','啊'.repeat(20000))],6000);
  let rtBytes=Buffer.byteLength(rt,'utf8');
  assert.ok(rtBytes<=16384,'bytes='+rtBytes);
  assert.equal(Buffer.from(rt,'utf8').toString('utf8'),rt);
  // 大 maxChars 跳过预览截断，直测 16KB 字节上限的代理对安全（4096×4=16384）。
  rt=XRouter.retrievalText([msg('user','😀'.repeat(9000))],60000);
  rtBytes=Buffer.byteLength(rt,'utf8');
  assert.ok(rtBytes<=16384&&rtBytes>16000,'bytes='+rtBytes);
  assert.equal(Buffer.from(rt,'utf8').toString('utf8'),rt);

  // 影子模式：实际路由沿用 config 语义，分档结论只进 reason。
  const shadow=new XRouter(params('SIMPLE',{shadow:true}));
  d=await decide(shadow,[msg('user','你好')],ready());
  assert.equal(d.side,'cloud');
  assert.equal(d.model,'local');
  assert.ok(d.reason.includes('shadow=true')&&d.reason.includes('would=local'));
  d=await decide(shadow,[msg('user','你好')],noCloud());
  assert.equal(d.side,'local');

  // bandit 挂点：note 逐字（前导空格）、终档覆写进 tier/model、未配置逐字节回归（上方已断言）。
  const bp=defaultBanditParams();
  const decideBandit=(router,retrieved)=>router.decideAsync(
    {messages:[msg('user','你好')],promptChars:2,image:'',maxTokens:0,retrieved:retrieved},ready());
  // 空 retrieved → cold（近邻不足），档位不动。
  let db=await decideBandit(new XRouter(params('NONE',{bandit:bp})),[]);
  assert.equal(db.reason,'x-router: rule=escalate_cloud tier=SIMPLE source=heuristic tier_llm=SIMPLE bandit=cold neighbors=0');
  assert.equal(db.tier,'SIMPLE');
  // incumbent 无证据（仅 MEDIUM 证据）→ ignore。
  const medOnly=[...Array(5)].map((_,i)=>({id:'m'+i,score:1,
    data:new Map([['MEDIUM',{quality:0.9,costUsd:0.0}]])}));
  db=await decideBandit(new XRouter(params('NONE',{bandit:bp})),medOnly);
  assert.ok(db.reason.includes('bandit=ignore'));
  assert.equal(db.tier,'SIMPLE');
  // 混合证据（SIMPLE 0.1×3 / MEDIUM 0.9×2）→ override MEDIUM，tier_llm 仍 SIMPLE。
  const mixed=[...Array(5)].map((_,i)=>{
    const data=new Map();
    if(i<3)data.set('SIMPLE',{quality:0.1,costUsd:0.0});
    else data.set('MEDIUM',{quality:0.9,costUsd:0.0});
    return {id:'x'+i,score:1,data};
  });
  db=await decideBandit(new XRouter(params('NONE',{bandit:bp})),mixed);
  assert.equal(db.reason,'x-router: rule=escalate_cloud tier=MEDIUM source=heuristic tier_llm=SIMPLE bandit=override neighbors=5');
  assert.equal(db.tier,'MEDIUM');
  assert.equal(db.model,'GLM-5.3');           // MEDIUM 未配模型 → 回落 COMPLEX 模型
  // within_local_capability 同样携带 bandit 尾注。
  db=await decideBandit(new XRouter(params('SIMPLE',{bandit:bp})),[]);
  assert.equal(db.reason,'x-router: rule=within_local_capability tier=SIMPLE source=heuristic tier_llm=SIMPLE bandit=cold neighbors=0');
  assert.equal(db.side,'local');

  // 分类器注入槽：应答/异常/解析失败/构建失败四态（source 体系对齐上游）。
  const withBackend=(reply,mode)=>{
    const backend={classifyAsync:()=>mode==='reject'
      ?Promise.reject(new Error('classifier down')):Promise.resolve(reply)};
    return new XRouter(params('NONE',{backend}));
  };
  d=await decide(withBackend('COMPLEX'),[msg('user','你好')],ready());
  assert.equal(d.reason,'x-router: rule=escalate_cloud tier=COMPLEX source=llm');
  assert.equal(d.tier,'COMPLEX');
  d=await decide(withBackend('please use COMPLEX'),[msg('user','你好')],ready());
  assert.equal(d.reason,'x-router: rule=escalate_cloud tier=SIMPLE source=parse_failed');
  d=await decide(withBackend('','reject'),[msg('user','你好')],ready());
  assert.equal(d.reason,'x-router: rule=escalate_cloud tier=SIMPLE source=heuristic_fallback');
  d=await decide(withBackend('COMPLEX'),[msg('system','sys')],ready());
  assert.ok(d.reason.includes('source=heuristic_fallback'));

  // 配置装配（上游 ParamsError 语义）：任一参数非法即 null。
  const CFG='/files/cloud_config.json';
  const load=raw=>{if(raw===null)delete files[CFG];else files[CFG]=raw;return XRouter.loadParams('/files');};
  assert.equal(load(null),null);
  assert.equal(load('{"backend":"cloud"}'),null);
  let loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"localCapabilityLevel":"NONE","tierModels":{"COMPLEX":"m"}}}');
  assert.equal(loaded.localCapabilityLevel,'NONE');
  assert.equal(loaded.tierModels.get('COMPLEX'),'m');
  assert.equal(loaded.tierModels.size,1);
  assert.equal(loaded.previewChars,6000);
  assert.equal(loaded.backend,null);
  assert.equal(loaded.shadow,false);
  loaded=load('{"xRouter":{"tierModels":{"COMPLEX":"m","research":"r"},"classifierPreviewChars":512,"shadow":true}}');
  assert.equal(loaded.localCapabilityLevel,'MEDIUM');
  assert.equal(loaded.tierModels.get('RESEARCH'),'r');
  assert.equal(loaded.previewChars,512);
  assert.equal(loaded.shadow,true);
  assert.equal(load('{"xRouter":{"localCapabilityLevel":"BOGUS","tierModels":{"COMPLEX":"m"}}}'),null);
  assert.equal(load('{"xRouter":{"tierModels":{"SIMPLE":"m"}}}'),null);
  assert.equal(load('{"xRouter":{"tierModels":{"COMPLEX":"m","SIMPL":"x"}}}'),null);
  assert.equal(load('{"xRouter":{"tierModels":{"COMPLEX":"  "}}}'),null);
  assert.equal(load('{"xRouter":{"tierModels":{"COMPLEX":"m"},"classifierPreviewChars":100}}'),null);
  assert.equal(load('{oops'),null);
  loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"classifier":{"enabled":true}}}');
  assert.ok(loaded.backend!==null);
  loaded=load('{"baseUrl":"http://x","xRouter":{"tierModels":{"COMPLEX":"m"},"classifier":{"enabled":true}}}');
  assert.equal(loaded.backend,null);
  loaded=load('{"apiKey":"k","baseUrl":"http://x","xRouter":{"tierModels":{"COMPLEX":"m"}}}');
  assert.equal(loaded.backend,null);

  // 服务装配配置（loadServiceConfig）：judge/store 段语义。
  const svc=raw=>{if(raw===null)delete files[CFG];else files[CFG]=raw;return XRouter.loadServiceConfig('/files');};
  // 无文件/无 xRouter/无 judge 无 store → null（无服务，行为同旧）。
  assert.equal(svc(null),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m"}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"}}}'),null);
  // judge 全凭据：model 回落顶层，超时/令牌默认 60/2048。
  let s=svc('{"apiKey":"k","baseUrl":"http://x","model":"top","xRouter":{"judge":{"enabled":true}}}');
  assert.ok(s!==null&&s.judge!==null);
  assert.equal(s.judge.apiKey,'k');
  assert.equal(s.judge.baseUrl,'http://x');
  assert.equal(s.judge.model,'top');
  assert.equal(s.judge.timeoutSeconds,60);
  assert.equal(s.judge.maxTokens,2048);
  assert.equal(s.storeParams,null);              // 无 store 表 → 宿主默认激活
  // judge 显式 model + 钳制（timeout [5,120]、maxTokens [16,8192]）。
  s=svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true,"model":"jm","timeoutSeconds":999,"maxTokens":8}}}');
  assert.equal(s.judge.model,'jm');
  assert.equal(s.judge.timeoutSeconds,120);
  assert.equal(s.judge.maxTokens,16);
  // judge 缺凭据 → judge null；无 store 表 → 服务整体 null。
  assert.equal(svc('{"baseUrl":"http://x","xRouter":{"judge":{"enabled":true}}}'),null);
  // judge 缺凭据但 store 表在 → store 单独激活。
  s=svc('{"baseUrl":"http://x","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"topK":5}}}}');
  assert.equal(s.judge,null);
  assert.ok(s.storeParams!==null);
  assert.equal(s.storeParams.topK,5);
  assert.equal(s.storeParams.retrieverDim,4096); // 未写字段取默认
  // judge.enabled 非 true → judge null（store 表仍可独立激活）。
  s=svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":false},"bandit":{"store":{"topK":5}}}}');
  assert.equal(s.judge,null);
  assert.equal(s.storeParams.topK,5);
  // store 子表任一非法 → 整体 null（严格回落）。
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"topK":257}}}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"minSimilarity":1.5}}}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"forgettingGamma":0}}}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"pendingTtlSeconds":0}}}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"retrieverDim":0}}}}'),null);
  assert.equal(svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"judge":{"enabled":true},"bandit":{"store":{"maxEntries":1.5}}}}'),null);
  // store 单独在场（无 judge）→ 服务激活，秒→毫秒。
  s=svc('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"bandit":{"store":{"pendingTtlSeconds":2,"exclusionTtlSeconds":3,"minSimilarity":0.75,"forgettingGamma":0.9}}}}');
  assert.equal(s.judge,null);
  assert.equal(s.storeParams.pendingTtlMs,2000);
  assert.equal(s.storeParams.exclusionTtlMs,3000);
  assert.equal(s.storeParams.minSimilarity,0.75);
  assert.equal(s.storeParams.forgettingGamma,0.9);

  // loadParams bandit 段：缺省/显式 false → null；表存在无 enabled → 启用；非法 → 整体 null。
  loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"}}}');
  assert.equal(loaded.bandit,null);
  loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"enabled":false,"store":{"topK":5}}}}');
  assert.equal(loaded.bandit,null);            // Stage 1 形状：显式关闭（store 段仍归 loadServiceConfig）
  loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{}}}');
  assert.ok(loaded.bandit!==null);
  assert.equal(loaded.bandit.minNeighbors,5);  // 默认 5/0.3/0.2/0.005
  assert.equal(loaded.bandit.margin,0.3);
  assert.equal(loaded.bandit.lambdaC,0.2);
  assert.equal(loaded.bandit.costRefUsd,0.005);
  loaded=load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"enabled":true,"minNeighbors":8,"margin":0.5,"lambdaC":0,"costRefUsd":0.01}}}');
  assert.equal(loaded.bandit.minNeighbors,8);
  assert.equal(loaded.bandit.margin,0.5);
  assert.equal(loaded.bandit.lambdaC,0);
  assert.equal(loaded.bandit.costRefUsd,0.01);
  assert.equal(load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"margin":-1}}}'),null);
  assert.equal(load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"costRefUsd":0}}}'),null);
  assert.equal(load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"minNeighbors":0}}}'),null);
  assert.equal(load('{"apiKey":"k","baseUrl":"http://x","model":"m","xRouter":{"tierModels":{"COMPLEX":"m"},"bandit":{"minNeighbors":2.5}}}'),null);

  // 云端分类器：端点拼装、请求体形状（max_tokens 默认 2048 覆盖推理思考/temperature=0/Bearer）、错误路径 reject。
  let captured=null;
  httpState.onRequest=(url,options)=>{captured={url,options};};
  const classifier=new CloudClassifier('sk-test','http://10.0.0.1:8080','GLM-5.3',30);
  httpState.nextResponse={responseCode:200,
    result:JSON.stringify({choices:[{message:{role:'assistant',content:'  RESEARCH  '}}]})};
  assert.equal(await classifier.classifyAsync('classify this'),'  RESEARCH  ');
  assert.equal(captured.url,'http://10.0.0.1:8080/v1/chat/completions');
  let body=JSON.parse(captured.options.extraData);
  assert.equal(body.model,'GLM-5.3');
  assert.equal(body.max_tokens,2048);
  assert.equal(body.temperature,0);
  assert.equal(body.messages[0].role,'user');
  assert.equal(body.messages[0].content,'classify this');
  assert.equal(captured.options.header.Authorization,'Bearer sk-test');
  // max_tokens 可配置（推理模型思考预算）。
  const tuned=new CloudClassifier('sk-test','http://10.0.0.1:8080','GLM-5.3',30,256);
  httpState.nextResponse={responseCode:200,
    result:JSON.stringify({choices:[{message:{role:'assistant',content:'SIMPLE'}}]})};
  await tuned.classifyAsync('x');
  body=JSON.parse(captured.options.extraData);
  assert.equal(body.max_tokens,256);
  // disableThinking 开关：缺省不带 enable_thinking；true → enable_thinking:false（qwen3 系防思考吃预算）。
  assert.equal(body.enable_thinking,undefined);
  const noThink=new CloudClassifier('sk-test','http://10.0.0.1:8080','GLM-5.3',30,2048,true);
  httpState.nextResponse={responseCode:200,
    result:JSON.stringify({choices:[{message:{role:'assistant',content:'SIMPLE'}}]})};
  await noThink.classifyAsync('x');
  assert.equal(JSON.parse(captured.options.extraData).enable_thinking,false);
  httpState.nextResponse={responseCode:500,result:'boom'};
  await assert.rejects(()=>classifier.classifyAsync('x'));
  httpState.nextResponse=null;
  httpState.fail=true;
  await assert.rejects(()=>classifier.classifyAsync('x'));
  httpState.fail=false;
  httpState.onRequest=null;

  console.log('PASS x-router strict port: tiers, strict parsing, preview window, upstream heuristic, decision rules, degrade paths, shadow mode, backend slot, strict config loading, cloud classifier shape');
})().catch(e=>{console.error(e);process.exit(1);});
