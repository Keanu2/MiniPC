const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH || process.argv[2] || 'typescript');

// http 桩（JudgeClient 用），仿 XRouter.test。
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

const moduleObject=(()=>{
  const m={exports:{}};
  const code=ts.transpileModule(fs.readFileSync(path.join(__dirname,'Judge.ets'),'utf8'),
    {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(code,{module:m,exports:m.exports,console,
    require(name){
      if(name==='@ohos.net.http')return httpStub;
      return {};
    }},{filename:'Judge.ets'});
  return m;
})();
const {Judge,JudgeClient,JUDGE_SYSTEM_PROMPT,RUBRIC_WEIGHTS}=moduleObject.exports;

const near=(actual,expected)=>assert.ok(Math.abs(actual-expected)<1e-12,actual+' != '+expected);
const isJudgeError=e=>e!==null&&typeof e==='object'&&e.name==='JudgeError';
const msg=(role,content)=>({role,content});

(async()=>{
  // —— 常量逐字（rubric 权重/键序 + system prompt 字节断言，防顺手改写）——
  assert.deepEqual(Object.keys(RUBRIC_WEIGHTS),['task_progress','correctness','grounding']);
  assert.equal(RUBRIC_WEIGHTS['task_progress'],0.45);
  assert.equal(RUBRIC_WEIGHTS['correctness'],0.35);
  assert.equal(RUBRIC_WEIGHTS['grounding'],0.20);
  assert.equal(JUDGE_SYSTEM_PROMPT,[
    'You are a strict evaluator of a single assistant turn in an agent conversation.',
    'Score only the assistant turn from -1.0 to 1.0 for each criterion. Positive is good, zero is borderline, and negative is bad.',
    '- task_progress: +1 makes decisive concrete progress; 0 neither advances nor hurts; -1 stalls, is off-task, or moves backward.',
    '- correctness: +1 is correct and appropriate; 0 is partly correct or questionable; -1 is wrong or uses an invalid tool/arguments.',
    '- grounding: +1 is fully consistent with the conversation; 0 has minor unsupported details; -1 invents facts, files, or tools.',
    'Reply with ONLY a JSON object with task_progress, correctness, and grounding numeric fields.'
  ].join('\n'));

  // —— parseJudgeScore：全字段精确加权 ——
  near(Judge.parseJudgeScore('{"task_progress":0.6,"correctness":0.4,"grounding":0.2}'),0.45);
  near(Judge.parseJudgeScore('{"task_progress":1,"correctness":1,"grounding":1}'),1.0);
  near(Judge.parseJudgeScore('{"task_progress":-1,"correctness":-1,"grounding":-1}'),-1.0);
  // 部分字段按在场键重归一。
  near(Judge.parseJudgeScore('{"task_progress":1}'),1.0);
  near(Judge.parseJudgeScore('{"task_progress":1,"grounding":-1}'),0.25/0.65);
  // 越界字段忽略（不钳制）。
  near(Judge.parseJudgeScore('{"task_progress":2,"correctness":0.5}'),0.5);
  // bool / 字符串数字均不是可用字段。
  near(Judge.parseJudgeScore('{"task_progress":true,"correctness":0.5}'),0.5);
  near(Judge.parseJudgeScore('{"correctness":"0.8"}'),0.8);   // JSON 内不可用 → 兜底裸数字 0.8
  // 首个带 rubric 字段的 JSON 胜出；无字段的 JSON 跳过取下一个。
  near(Judge.parseJudgeScore('junk {"correctness":0.8} tail {"correctness":0.1}'),0.8);
  near(Judge.parseJudgeScore('{"a":1} {"correctness":0.8}'),0.8);
  // 代码围栏。
  near(Judge.parseJudgeScore('```json\n{"task_progress":1,"correctness":0,"grounding":0}\n```'),0.45);
  // 非法 JSON 跳过 → 兜底。
  near(Judge.parseJudgeScore('{"task_progress":} 0.7'),0.7);
  // 兜底取最后一个裸数字（带符号/小数）。
  near(Judge.parseJudgeScore('score: 0.3 then 0.7'),0.7);
  near(Judge.parseJudgeScore('final score -0.5'),-0.5);
  near(Judge.parseJudgeScore('quality is .5'),0.5);
  // 兜底越界抛错；JSON 全越界级联到兜底同样抛；全无数字抛；绝不静默 0。
  assert.throws(()=>Judge.parseJudgeScore('score: 1.5'),isJudgeError);
  assert.throws(()=>Judge.parseJudgeScore('{"task_progress":5,"correctness":-3}'),isJudgeError);
  assert.throws(()=>Judge.parseJudgeScore('I cannot evaluate this turn'),isJudgeError);
  assert.throws(()=>Judge.parseJudgeScore(''),isJudgeError);
  assert.throws(()=>Judge.parseJudgeScore(null),isJudgeError);

  // —— buildJudgeRequest：框架逐字 ——
  let req=Judge.buildJudgeRequest([msg('user','你好'),msg('assistant','好呀')],'不错');
  assert.equal(req.systemPrompt,JUDGE_SYSTEM_PROMPT);
  assert.equal(req.userPrompt,
    '<transcript>\n[user]: 你好\n[assistant]: 好呀\n</transcript>\n\n'
    +'<assistant_turn>\n不错\n</assistant_turn>\n\n'
    +'Score the assistant turn. Do not continue the conversation. Output only the JSON object.');
  // role 缺省 user；空 response → 空回答块。
  req=Judge.buildJudgeRequest([{role:'',content:'hi'}],'');
  assert.ok(req.userPrompt.startsWith('<transcript>\n[user]: hi\n</transcript>'));
  assert.ok(req.userPrompt.includes('<assistant_turn>\n\n</assistant_turn>'));
  // response 先 trim 再入块。
  req=Judge.buildJudgeRequest([msg('user','q')],'  answer  ');
  assert.ok(req.userPrompt.includes('<assistant_turn>\nanswer\n</assistant_turn>'));
  // transcript 中段截断：3000 预算、头尾各留一半、标记居中。
  req=Judge.buildJudgeRequest([msg('user','x'.repeat(5000))],'a');
  const transcriptBlock=req.userPrompt.split('</transcript>')[0];
  assert.ok(transcriptBlock.startsWith('<transcript>\n[user]: xxxxx'));
  assert.ok(transcriptBlock.endsWith('xxxxx\n'));
  assert.ok(transcriptBlock.includes('\n...[truncated]...\n'));
  assert.ok(transcriptBlock.length<='<transcript>\n'.length+3000);
  // response 中段截断：2000 预算 → 988+23+988=1999。
  req=Judge.buildJudgeRequest([msg('user','q')],'y'.repeat(2500));
  const turnBlock=req.userPrompt.split('<assistant_turn>\n')[1].split('\n</assistant_turn>')[0];
  assert.equal(turnBlock.length,1999);
  assert.ok(turnBlock.startsWith('yyy')&&turnBlock.endsWith('yyy'));
  assert.ok(turnBlock.includes('...[truncated]...'));

  // —— JudgeClient：端点归一 + 请求体形状（system/user 双消息、temperature=0、max_tokens）——
  let captured=null;
  httpState.onRequest=(url,options)=>{captured={url,options};};
  const client=new JudgeClient('sk-test','http://10.0.0.1:8080','GLM-5.3',60);
  httpState.nextResponse={responseCode:200,
    result:JSON.stringify({choices:[{message:{role:'assistant',content:'{"task_progress":1}'}}]})};
  assert.equal(await client.scoreAsync({systemPrompt:'sys',userPrompt:'usr'}),'{"task_progress":1}');
  assert.equal(captured.url,'http://10.0.0.1:8080/v1/chat/completions');
  let body=JSON.parse(captured.options.extraData);
  assert.equal(body.model,'GLM-5.3');
  assert.equal(body.max_tokens,2048);
  assert.equal(body.temperature,0);
  assert.equal(body.stream,false);
  assert.equal(body.messages.length,2);
  assert.equal(body.messages[0].role,'system');
  assert.equal(body.messages[0].content,'sys');
  assert.equal(body.messages[1].role,'user');
  assert.equal(body.messages[1].content,'usr');
  assert.equal(captured.options.header.Authorization,'Bearer sk-test');
  // 端点已带 /v1 不重复追加。
  await new JudgeClient('k','http://h/v1','m',30).scoreAsync({systemPrompt:'s',userPrompt:'u'});
  assert.equal(captured.url,'http://h/v1/chat/completions');
  // maxTokens 可配置（judge.maxTokens 装配钳制后传入）。
  await new JudgeClient('k','http://h','m',30,4096).scoreAsync({systemPrompt:'s',userPrompt:'u'});
  assert.equal(JSON.parse(captured.options.extraData).max_tokens,4096);
  // 非 2xx / 网络故障 → reject（宿主记 judgeFailed，绝不降级 0 分）。
  httpState.nextResponse={responseCode:500,result:'boom'};
  await assert.rejects(()=>client.scoreAsync({systemPrompt:'s',userPrompt:'u'}));
  httpState.nextResponse=null;
  httpState.fail=true;
  await assert.rejects(()=>client.scoreAsync({systemPrompt:'s',userPrompt:'u'}));
  httpState.fail=false;
  httpState.onRequest=null;

  console.log('PASS judge strict port: rubric weights verbatim, parse matrix (renormalize/out-of-range/bool/first-json/fallback-last-number/never-silent-zero), request framing, middle truncation, client shape');
})().catch(e=>{console.error(e);process.exit(1);});
