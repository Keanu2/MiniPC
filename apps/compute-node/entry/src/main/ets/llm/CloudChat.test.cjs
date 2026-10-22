const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

// fileIo 桩（create 读配置）与 http 桩（/chat/completions）。
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

const moduleObject={exports:{}};
const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,'CloudChat.ets'),'utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
vm.runInNewContext(code,{module:moduleObject,exports:moduleObject.exports,console,
  require(name){
    if(name==='@kit.PerformanceAnalysisKit')return{hilog:{info(){},warn(){},error(){}}};
    if(name==='@kit.CoreFileKit')return{fileIo:{readTextSync:p=>{
      if(!(p in files))throw new Error('no such file: '+p);
      return files[p];
    }}};
    if(name==='@ohos.net.http')return httpStub;
    return {};
  }},{filename:'CloudChat.ets'});
const {CloudChat}=moduleObject.exports;

const tick=()=>new Promise(r=>setTimeout(r,0));
const CFG='/files/cloud_config.json';
const VALID='{"backend":"cloud","apiKey":"k","baseUrl":"http://10.0.0.1:8080","model":"GLM-5.3","timeoutSeconds":30}';
const msg=[{role:'user',content:'你好'}];
const run=async(cloud,messages,options)=>{
  const updates=[];
  const refused=cloud.start(messages,u=>updates.push(u),'req-1',options||{});
  for(let i=0;i<10;i++){await tick();}
  return {refused,updates};
};
const respond=(choices)=>{httpState.nextResponse={responseCode:200,
  result:JSON.stringify({choices})};};

(async()=>{
  // 装配：文件缺失/显式 local/字段不齐 → null；齐全 → 实例。
  delete files[CFG];
  assert.equal(CloudChat.create('/files'),null);
  files[CFG]='{"backend":"local"}';
  assert.equal(CloudChat.create('/files'),null);
  files[CFG]='{"apiKey":"k","baseUrl":"http://x"}';
  assert.equal(CloudChat.create('/files'),null);
  files[CFG]=VALID;
  const cloud=CloudChat.create('/files');
  assert.ok(cloud!==null);
  assert.equal(cloud.modelName,'GLM-5.3');
  assert.equal(cloud.readinessError(),'');

  // 成功：delta + done(stop)，请求体形状（端点拼装/Bearer/max_tokens 钳制）。
  let captured=null;
  httpState.onRequest=(url,options)=>{captured={url,options};};
  respond([{message:{role:'assistant',content:'答案'},finish_reason:'stop'}]);
  let r=await run(cloud,msg,{maxTokens:512});
  assert.equal(r.refused,'');
  assert.equal(captured.url,'http://10.0.0.1:8080/v1/chat/completions');
  assert.equal(captured.options.header.Authorization,'Bearer k');
  let body=JSON.parse(captured.options.extraData);
  assert.equal(body.model,'GLM-5.3');
  assert.equal(body.stream,false);
  assert.equal(body.max_tokens,512);
  assert.equal(body.messages[0].content,'你好');
  assert.equal(r.updates.length,2);
  assert.equal(r.updates[0].kind,'delta');
  assert.equal(r.updates[0].text,'答案');
  assert.equal(r.updates[1].kind,'done');
  assert.equal(r.updates[1].text,'答案');
  assert.equal(r.updates[1].finishReason,'stop');

  // max_tokens：缺省 2048，上限 8192。
  respond([{message:{role:'assistant',content:'x'},finish_reason:'stop'}]);
  await run(cloud,msg,{});
  body=JSON.parse(captured.options.extraData);
  assert.equal(body.max_tokens,2048);
  respond([{message:{role:'assistant',content:'x'},finish_reason:'stop'}]);
  await run(cloud,msg,{maxTokens:99999});
  body=JSON.parse(captured.options.extraData);
  assert.equal(body.max_tokens,8192);

  // 推理模型思考耗尽预算：content 空 + finish_reason=length → OVERFLOW 细分
  // + 诚实文案，无 delta（上游 Outcome.OVERFLOW，RouterChat 据此排除降级）。
  respond([{message:{role:'assistant',content:''},finish_reason:'length'}]);
  r=await run(cloud,msg,{});
  assert.equal(r.updates.length,1);
  assert.equal(r.updates[0].kind,'done');
  assert.equal(r.updates[0].text,'');
  assert.ok(r.updates[0].error.includes('预算耗尽'));
  assert.equal(r.updates[0].failureKind,'overflow');
  assert.equal(r.updates[0].finishReason,'error');

  // 空 content 但 finish_reason=stop：原样 done（无错误标注），由上层判失败。
  respond([{message:{role:'assistant',content:''},finish_reason:'stop'}]);
  r=await run(cloud,msg,{});
  assert.equal(r.updates.length,1);
  assert.equal(r.updates[0].text,'');
  assert.equal(r.updates[0].error,undefined);
  assert.equal(r.updates[0].failureKind,undefined);
  assert.equal(r.updates[0].finishReason,'stop');

  // HTTP 5xx：错误文案带状态码与明细，无 overflow 标注。
  httpState.nextResponse={responseCode:500,
    result:JSON.stringify({error:{message:'upstream boom'}})};
  r=await run(cloud,msg,{});
  assert.equal(r.updates.length,1);
  assert.ok(r.updates[0].error.includes('HTTP 500'));
  assert.ok(r.updates[0].error.includes('upstream boom'));
  assert.equal(r.updates[0].failureKind,undefined);
  assert.equal(r.updates[0].finishReason,'error');

  // 网络失败：统一错误文案。
  httpState.nextResponse=null;
  httpState.fail=true;
  r=await run(cloud,msg,{});
  assert.equal(r.updates.length,1);
  assert.ok(r.updates[0].error.includes('云端模型请求失败'));
  httpState.fail=false;

  // 带图 fail closed：同步拒收，不发请求。
  let httpCalls=0;
  httpState.onRequest=()=>{httpCalls+=1;};
  const refused=cloud.start(msg,()=>{}, 'req-2',{image:'b64'});
  assert.equal(refused,'云端模型暂不支持图片理解。');
  await tick();
  assert.equal(httpCalls,0);

  // 生命周期：start 后 isBusy=true，收尾后 false。
  respond([{message:{role:'assistant',content:'x'},finish_reason:'stop'}]);
  const busy=[];
  cloud.start(msg,()=>{},'req-3',{});
  busy.push(cloud.isBusy());
  await tick();
  busy.push(cloud.isBusy());
  assert.deepEqual(busy,[true,false]);
  httpState.onRequest=null;

  console.log('PASS cloud chat: create gate, request shape, token clamp, overflow outcome, empty/stop, http error, network fail, image fail-closed, busy lifecycle');
})().catch(e=>{console.error(e);process.exit(1);});
