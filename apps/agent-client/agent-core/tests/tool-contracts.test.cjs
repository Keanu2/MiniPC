/* End-to-end extension tests use the actual registry, parser and runner.
 * Providers/model responses are controlled; no real external writes occur. */
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.TYPESCRIPT_PATH||'D:/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve(__dirname,'../src/main/ets'),cache=new Map();
function load(relative){const file=path.resolve(root,relative);if(cache.has(file))return cache.get(file).exports;
 const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:file.replace(/\.ets$/,'.ts'),compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS},reportDiagnostics:true});
 assert.deepEqual((compiled.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error),[]);
 const mod={exports:{}};cache.set(file,mod);
 const requireLocal=name=>{
  if(name==='@ohos.util')return{default:{TextEncoder:class{encodeInto(s){return Buffer.from(s,'utf8');}}}};
  if(name==='../skill/SkillSnapshot')return{buildSkillsSection:()=>''};
  if(file.endsWith('ToolRegistry.ets')&&!['./ToolContract','./AgentTool','./A2uiObservationDigest'].includes(name))return{};
  if(name.startsWith('.'))return load(path.resolve(path.dirname(file),name+'.ets'));
  throw Error('Unexpected import '+name);
 };
 vm.runInThisContext('(function(require,module,exports){'+compiled.outputText+'\n})',{filename:file})(requireLocal,mod,mod.exports);return mod.exports;
}
const contracts=load('agent/ToolContract.ets'),core=load('agent/ReActCore.ets');
const {ToolRegistry}=load('agent/ToolRegistry.ets'),{ReActAgentRunner}=load('agent/ReActAgentRunner.ets');
const {AgentEventKind:K}=load('agent/AgentEvent.ets');
const {normalizeToolResult}=load('agent/AgentTool.ets');
const policy={readOnly:true,supportsParallel:true,cacheable:true,risk:'low'};
const tick=()=>new Promise(r=>setImmediate(r)),wait=ms=>new Promise(r=>setTimeout(r,ms));
const fixture=(name,run,contract)=>({name:()=>name,description:()=>name+' lookup',run,contract:()=>contract});
const typed=data=>({callId:'provider-local',status:'success',raw:JSON.stringify(data),displayText:'Lookup completed.',data});
function bookContract(){return{version:'1',inputFormat:'json',inputSchema:{type:'object',required:['isbn'],properties:{isbn:{type:'string',enum:['A','B']}},additionalProperties:false},
 outputSchema:{type:'object',required:['isbn','title'],properties:{isbn:{type:'string'},title:{type:'string'}}},evidenceFields:[{path:'title',kind:'literal',required:true}],finalization:'result'};}
const action=(name,input)=>'Action: '+name+'['+JSON.stringify(input)+']';
const manifest=specs=>'Plan: '+JSON.stringify({requirements:specs});
async function run(registry,task,responses,options={}){const prompts=[],events=[],contexts=[];let index=0;
 const model={complete:async(prompt,context)=>{prompts.push(prompt);contexts.push(context);options.onModelPrompt?.(prompt);const value=responses[Math.min(index++,responses.length-1)];if(value instanceof Error)throw value;return value;},cancel:()=>options.onModelCancel?.()};
 const runner=new ReActAgentRunner(model,registry,options.steps||12,undefined,false,false,options.compact===true,()=>options.budget||32768,options.taskContracts===true,options.finalReview===true);
 options.onRunner?.(runner);await runner.run(task,event=>{events.push(event);options.onEvent?.(event,runner);},options.conversation);
 return{events,prompts,contexts,final:events.filter(e=>e.kind===K.FINAL).map(e=>e.text).join('\n')};}
const tests=[];const test=(name,body)=>tests.push({name,body});

test('state-changing tools run one at a time across callers; read-only tools stay concurrent; a stopped caller\'s queued write is skipped',async()=>{
 const registry=new ToolRegistry();let active=0,peak=0,reads=0,peakReads=0;const order=[];
 const writer=name=>({name:()=>name,description:()=>name,run:async(input)=>{active++;peak=Math.max(peak,active);order.push(input);await wait(15);active--;return 'wrote '+input;}});
 const reader={name:()=>'reader',description:()=>'reader',run:async()=>{reads++;peakReads=Math.max(peakReads,reads);await wait(15);reads--;return 'read';}};
 registry.register(writer('writer'),{readOnly:false,supportsParallel:false,cacheable:false,risk:'high'});
 registry.register(reader,policy);
 const [a,b,c]=await Promise.all([registry.run('writer','1','ns1/call-1'),registry.run('writer','2','ns2/call-1'),registry.run('writer','3','ns1/call-2')]);
 assert.equal(peak,1);assert.deepEqual(order,['1','2','3']);assert.ok([a,b,c].every(r=>r.status==='success'));
 await Promise.all([registry.run('reader','','ns1/call-3'),registry.run('reader','','ns2/call-3')]);assert.equal(peakReads,2);
 order.length=0;
 const first=registry.run('writer','x','ns1/call-4'),second=registry.run('writer','y','ns2/call-4'),third=registry.run('writer','z','ns1/call-5');
 await wait(2);registry.cancelActive('ns1/');
 const results=await Promise.all([first,second,third]);
 assert.equal(results[2].status,'unavailable');assert.equal(results[1].status,'success');assert.ok(order.indexOf('z')<0,'queued write of the stopped caller must not run');
});
test('schemas enforce types bounds enums arrays alternatives and own properties',()=>{
 const schema={type:'object',required:['id','rows'],additionalProperties:false,properties:{id:{type:'string',minLength:1,maxLength:4},rows:{type:'array',minItems:1,maxItems:2,items:{type:'integer',minimum:0,maximum:5}},flag:{type:'boolean'},choice:{anyOf:[{type:'number'},{type:'null'}]}}};
 assert.deepEqual(contracts.validateSchema({id:'x',rows:[0,5],flag:true,choice:null},schema),[]);
 for(const value of [{rows:[1]},{id:' ',rows:[1]},{id:'longer',rows:[1]},{id:'x',rows:[]},{id:'x',rows:[1.5]},{id:'x',rows:[6]},{id:'x',rows:[1,2,3]},{id:'x',rows:[1],extra:1},{id:'x',rows:[1],flag:'true'},{id:'x',rows:[1],choice:'1'}])assert.ok(contracts.validateSchema(value,schema).length);
 assert.ok(contracts.validateSchema({id:'x',rows:[1],constructor:1},schema).length);
});
test('schema declarations fail closed and registration replacement is atomic',()=>{
 const registry=new ToolRegistry();registry.register(fixture('books',async()=>typed({isbn:'A',title:'Edition A'}),bookContract()),policy);
 for(const schema of [{type:'string',format:'uuid'},{type:'string',minLength:5,maxLength:1},{type:'number',minimum:Infinity},{type:'array',maxItems:-1},{type:'object',additionalProperties:{}},{type:'made-up'},{anyOf:[]}]){
  assert.throws(()=>registry.register(fixture('books',async()=>'',{version:'2',inputFormat:'json',inputSchema:schema}),policy));
  assert.equal(registry.contracts().get('books').version,'1');assert.equal(registry.metadata('books').readOnly,true);
 }
 const cyclic={type:'object',properties:{}};cyclic.properties.next=cyclic;
 assert.throws(()=>registry.register(fixture('cyclic',async()=>'',{version:'1',inputFormat:'json',inputSchema:cyclic}),policy));
 assert.equal(registry.has('cyclic'),false);
});
test('validation is bounded for deeply nested or oversized input',()=>{
 let schema={type:'number'},value=1;for(let i=0;i<28;i++){schema={type:'array',items:schema};value=[value];}
 assert.ok(contracts.validateSchema(value,schema).length);
 assert.ok(contracts.validateSchema(Array(10001).fill(1),{type:'array',items:{type:'number'}}).length);
 const circular={};circular.self=circular;assert.throws(()=>contracts.canonicalValue(circular));
});
test('new renamed and dotted tools work through schemas and structured plans',async()=>{
 const files=['ReActCore.ets','ReActAgentRunner.ets','AgentTool.ets'];const before=files.map(f=>fs.readFileSync(path.join(root,'agent',f),'utf8'));
 for(const name of ['catalog.lookup','new_book_service','library_v2']){
  const registry=new ToolRegistry(),called=[];let active=0,max=0;
  registry.register(fixture(name,async(input)=>{const isbn=JSON.parse(input).isbn;called.push(isbn);active++;max=Math.max(max,active);await wait(isbn==='A'?8:1);active--;return typed({isbn,title:'Edition '+isbn,privateDebug:'INTERNAL_SECRET'});},bookContract()),policy);
  const plan=manifest([{id:'one',tool:name,input:{isbn:'A'},label:'First edition'},{id:'two',tool:name,input:{isbn:'B'},label:'Second edition'}]);
  const result=await run(registry,'Find both editions.',[plan+'\nExecution: parallel\n'+action(name,{isbn:'A'})+'\n'+action(name,{isbn:'B'}),'Final: Edition A and Edition B']);
  assert.deepEqual(called.sort(),['A','B']);assert.equal(max,2);assert.equal(result.final,'Edition A and Edition B');
  assert.ok(result.prompts.some(p=>p.includes('Returned evidence:')&&p.includes('Edition A')&&p.includes('Edition B')));
  assert.ok(result.prompts.every(p=>!p.includes('INTERNAL_SECRET')));await registry.close();
 }
 assert.deepEqual(files.map(f=>fs.readFileSync(path.join(root,'agent',f),'utf8')),before);
});
test('structured requirements keep different calls separate and reject an incomplete final',async()=>{
 const registry=new ToolRegistry(),called=[];registry.register(fixture('book_lookup',async(input)=>{const isbn=JSON.parse(input).isbn;called.push(isbn);return typed({isbn,title:'Edition '+isbn});},bookContract()),policy);
 const plan=manifest([{id:'a',tool:'book_lookup',input:{isbn:'A'},label:'A'},{id:'b',tool:'book_lookup',input:{isbn:'B'},label:'B'}]);
 const r=await run(registry,'Find two editions',[plan+'\n'+action('book_lookup',{isbn:'A'}),'Final: Edition A and Edition B',action('book_lookup',{isbn:'B'}),'Final: Edition A and Edition B']);
 assert.deepEqual(called,['A','B']);assert.equal(r.prompts.length,4);assert.ok(r.prompts[2].includes('no matching executed call: B'));assert.equal(r.final,'Edition A and Edition B');
 assert.match(r.prompts[1],/Execution phase:/);assert.match(r.prompts[1],/Execute only missing required calls now: book_lookup: B/);assert.doesNotMatch(r.prompts[1],/Synthesis phase:/);
 assert.match(r.prompts[3],/Evidence review phase:/);assert.ok(!r.prompts[3].includes(action('book_lookup',{isbn:'A'})));
});
test('unknown or forged plan fields invalidate the entire batch',async()=>{
 for(const specs of [[{id:'a',tool:'book_lookup',input:{isbn:'A'},label:'A'},{id:'b',tool:'missing',input:{},label:'B'}],
  [{id:'a',tool:'book_lookup',input:{isbn:'A'},label:'A',status:'success'}],
  [{id:'a',tool:'book_lookup',input:{isbn:'A'},label:'A',readOnly:true}],
  [{id:'same',tool:'book_lookup',input:{isbn:'A'},label:'A'},{id:'same',tool:'book_lookup',input:{isbn:'B'},label:'B'}]]){
  let count=0;const registry=new ToolRegistry();registry.register(fixture('book_lookup',async()=>{count++;return typed({isbn:'A',title:'Edition A'});},bookContract()),policy);
  await run(registry,'Find an edition',[manifest(specs)+'\n'+action('book_lookup',{isbn:'A'}),'Final: unavailable']);assert.equal(count,0);
 }
});
test('schema-invalid sibling prevents all calls including a valid write',async()=>{
 const registry=new ToolRegistry();let writes=0,reads=0;
 registry.register(fixture('write_record',async()=>{writes++;return'ok';},{version:'1',inputFormat:'json',inputSchema:{type:'object',required:['value'],properties:{value:{type:'number'}}}}));
 registry.register(fixture('book_lookup',async()=>{reads++;return typed({isbn:'A',title:'Edition A'});},bookContract()),policy);
 await run(registry,'Perform a batch',[action('write_record',{value:1})+'\n'+action('book_lookup',{isbn:4}),'Final: unavailable']);assert.equal(writes,0);assert.equal(reads,0);
});
test('output schemas and evidence declarations reject invalid successful payloads',async()=>{
 for(const data of [{isbn:'A'},{isbn:'A',title:4},undefined]){
  const registry=new ToolRegistry();registry.register(fixture('book_lookup',async()=>({...typed(data),raw:'raw diagnostic',displayText:'claim of success'}),bookContract()),policy);
  const result=await registry.run('book_lookup','{"isbn":"A"}','owned');assert.equal(result.status,'failed');assert.match(result.displayText,/output does not satisfy/);assert.equal(result.callId,'owned');
 }
 const registry=new ToolRegistry();registry.register(fixture('price_probe',async()=>typed({price:'4'}),{version:'1',inputFormat:'json',evidenceFields:[{path:'price',kind:'number',required:true}]}),policy);
 assert.equal((await registry.run('price_probe','{}')).status,'failed');
});
test('explicit tool invocation is required without any built-in recognizer',async()=>{
 const registry=new ToolRegistry();let count=0;registry.register(fixture('edition_lookup',async()=>{count++;return typed({isbn:'A',title:'Edition A'});},bookContract()),policy);
 const r=await run(registry,'Use edition_lookup to find A',['Final: Edition A',action('edition_lookup',{isbn:'A'}),'Final: Edition A']);
 assert.equal(count,1);assert.equal(r.prompts.length,3);assert.equal(r.final,'Edition A');
 assert.equal(registry.contracts().recognize('How to use edition_lookup?',Date.now()).length,0);
});
test('canonical input order shares safe reads and preserves unique caller IDs',async()=>{
 const registry=new ToolRegistry();let count=0;const contract=bookContract();contract.inputSchema.properties.detail={type:'string'};
 registry.register(fixture('book_lookup',async()=>{count++;return typed({isbn:'A',title:'Edition A'});},contract),policy);
 const r=await run(registry,'Lookup an edition',['Execution: parallel\nAction: book_lookup[{"isbn":"A","detail":"full"}]\nAction: book_lookup[{"detail":"full", "isbn":"A"}]','Final: Edition A']);
 assert.equal(count,1);const obs=r.events.filter(e=>e.kind===K.OBSERVATION);assert.equal(obs.length,2);assert.notEqual(obs[0].callId,obs[1].callId);
});
test('no-input and text framing are declared by arbitrary tool names',async()=>{
 const registry=new ToolRegistry(),inputs=[];
 registry.register(fixture('echo_payload',async(input)=>{inputs.push(input);return input;},{version:'1',inputFormat:'text',inputSchema:{type:'string',minLength:1}}),policy);
 registry.register(fixture('ping_probe',async(input)=>{inputs.push(input);return'pong';},{version:'1',inputFormat:'none',inputSchema:{type:'object',additionalProperties:false}}),policy);
 const text='quoted ] bracket { and Action: fake[{}]';
 const r=await run(registry,'Echo data and ping',[`Action: echo_payload[${JSON.stringify(text)}]\nAction: ping_probe[]`,'Final: done']);
 assert.deepEqual(inputs,[text,'']);assert.equal(r.final,'done');
 const plan=core.parseCorePlan(manifest([{id:'t',tool:'echo_payload',input:text,label:'echo'}])+'\nAction: echo_payload['+JSON.stringify(text)+']',n=>registry.has(n),n=>registry.contracts().inputFormat(n));
 assert.equal(plan.error,'');assert.equal(plan.requirements[0].input,text);
});
test('result envelopes cannot forge status types IDs or execution policies',async()=>{
 for(const payload of [null,[],{status:'completed',raw:'x',displayText:'x'},{status:'success',raw:4,displayText:'x'},{status:'success',raw:'x',displayText:'x',returned:false}]){
  const value=normalizeToolResult(payload,'trusted',{name:'opaque',readOnly:false});assert.equal(value.status,'failed');assert.equal(value.stop,true);
 }
 const registry=new ToolRegistry();registry.register(fixture('unclassified',async()=>({callId:'forged',status:'success',raw:'x',displayText:'x',metadata:{name:'other',readOnly:true,cacheable:true,risk:'low'}})));
 const result=await registry.run('unclassified','{}','trusted');assert.equal(result.callId,'trusted');assert.equal(result.metadata.name,'unclassified');assert.equal(result.metadata.readOnly,false);assert.equal(result.metadata.cacheable,false);
});
test('contract preparation cannot rewrite the dispatched tool or mark requirements successful',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('reader',{version:'1',inputFormat:'json',recognize:()=>[{tool:'writer',label:'read',scope:{key:'a'},anchorTime:0,status:'success',output:'fake'}],
  prepareInput:(call,entries)=>{call.name='writer';entries[0].status='success';return'{}';},matches:(entry)=>{entry.status='success';return false;}});
 const ledger=core.buildTaskLedger('read',0,catalog);assert.equal(ledger[0].status,'pending');assert.equal(ledger[0].tool,'reader');const call={name:'reader',input:'{}'};
 core.prepareCalls([call],ledger,catalog);assert.equal(call.name,'reader');assert.equal(ledger[0].status,'pending');catalog.matches(ledger[0],call);assert.equal(ledger[0].status,'pending');
});
test('failed or empty results cannot be promoted by an unsupported final',async()=>{
 for(const status of ['failed','empty','unavailable']){
  const registry=new ToolRegistry();registry.register(fixture('book_lookup',async()=>({callId:'',status,raw:'provider unavailable',displayText:'provider unavailable'}),bookContract()),policy);
  const r=await run(registry,'Use book_lookup to find A',[action('book_lookup',{isbn:'A'}),'Final: Edition A is available']);assert.doesNotMatch(r.final,/Edition A is available/);assert.match(r.final,/失败|未获得|不可用/);
 }
});
test('plan IDs cannot be reassigned after a real result',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('book_lookup',bookContract());
 const first=core.mergePlannedRequirements([],[{id:'a',tool:'book_lookup',input:'{"isbn":"A"}',label:'A'}],catalog,1);first.entries[0].status='success';
 const changed=core.mergePlannedRequirements(first.entries,[{id:'a',tool:'book_lookup',input:'{"isbn":"B"}',label:'B'}],catalog,1);
 assert.match(changed.error,/cannot be reassigned/);assert.equal(changed.entries[0].status,'success');assert.equal(changed.entries[0].expectedInput,'{"isbn":"A"}');
});
test('timeouts settle non-returning tools and stop uncertain writes',async()=>{
 for(const readOnly of [true,false]){
  const registry=new ToolRegistry();let cancelled=false;const tool=fixture('slow_tool',async()=>new Promise(()=>{}));tool.cancel=()=>{cancelled=true;throw Error('transport closed');};
  registry.register(tool,{readOnly,supportsParallel:readOnly,cacheable:false,risk:readOnly?'low':'high',timeoutMs:5});
  const result=await registry.run('slow_tool','{}');assert.equal(result.status,'failed');assert.equal(result.returned,false);assert.equal(result.stop,!readOnly);assert.match(result.displayText,/超时/);assert.equal(cancelled,true);assert.equal(registry.activeInvocations.size,0);
 }
});
test('cancel settles locally and stale callbacks cannot consume a reused public ID',async()=>{
 const registry=new ToolRegistry(),jobs=[],contexts=[];
 const tool=fixture('deferred_tool',async(_input,context)=>{contexts.push(context);return new Promise(resolve=>jobs.push(resolve));});tool.cancel=()=>{throw Error('cancel failed');};registry.register(tool,policy);
 const old=registry.run('deferred_tool','{}','shared');await tick();registry.cancelActive();assert.equal((await old).stop,true);assert.equal(contexts[0].isCancelled(),true);
 const current=registry.run('deferred_tool','{}','shared');await tick();assert.notEqual(contexts[0].invocationId,contexts[1].invocationId);jobs[0]('late');await tick();assert.equal(registry.activeInvocations.size,1);
 jobs[1]('current');assert.equal((await current).displayText,'current');assert.equal(registry.activeInvocations.size,0);
});
test('provider exceptions stop uncertain writes and cannot trigger automatic replay',async()=>{
 for(const readOnly of [true,false]){
  const registry=new ToolRegistry();let calls=0;registry.register(fixture('exception_tool',async()=>{calls++;throw Error('provider disconnected after starting');}),{...policy,readOnly});
  const result=await registry.run('exception_tool','{}');assert.equal(result.status,'failed');assert.equal(result.returned,false);assert.equal(result.stop,!readOnly);
  if(!readOnly){calls=0;await run(registry,'Perform operation',[action('exception_tool',{}),action('exception_tool',{}),'Final: done']);assert.equal(calls,1);}
 }
});
test('runner stop during a hung tool never emits a late final',async()=>{
 const registry=new ToolRegistry();let started;const began=new Promise(r=>started=r);
 registry.register(fixture('hung_tool',async()=>{started();return new Promise(()=>{});}),policy);let runner;
 const result=run(registry,'Call hung_tool',[action('hung_tool',{})],{onRunner:r=>runner=r});await began;runner.requestStop();const done=await result;
 assert.equal(done.final,'');assert.ok(done.events.some(e=>e.kind===K.ERROR&&/已停止/.test(e.text)));assert.equal(registry.activeInvocations.size,0);
});
test('close is idempotent cancels pending work and prevents resource resurrection',async()=>{
 const registry=new ToolRegistry();let closes=0;registry.registerCloseHandler(async()=>closes++);registry.register(fixture('hung',async()=>new Promise(()=>{})),policy);
 const pending=registry.run('hung','{}');await tick();await registry.close();await registry.close();assert.equal(closes,1);assert.equal((await pending).stop,true);
 assert.equal((await registry.run('hung','{}')).status,'unavailable');assert.throws(()=>registry.register(fixture('new',async()=>'')),/closed/);
});
test('unknown and mutating policies never gain parallelism from a plan',async()=>{
 const registry=new ToolRegistry();let active=0,max=0,count=0;
 registry.register(fixture('opaque',async()=>{count++;active++;max=Math.max(max,active);await wait(2);active--;return'ok';}));
 await run(registry,'Perform two operations',['Execution: parallel\n'+action('opaque',{})+'\n'+action('opaque',{}),'Final: done']);assert.equal(count,2);assert.equal(max,1);
});
test('core code contains no built-in domain switches and small randomized schemas stay consistent',()=>{
 for(const file of ['ReActCore.ets','ReActAgentRunner.ets','AgentTool.ets'])assert.doesNotMatch(fs.readFileSync(path.join(root,'agent',file),'utf8'),/weather_search|train_search|map_search|air_quality|unit_convert|date_calculator|calculator/);
 for(let value=-25;value<=25;value++){const schema={type:'integer',minimum:-4,maximum:9};assert.equal(contracts.validateSchema(value,schema).length===0,value>=-4&&value<=9);assert.ok(contracts.validateSchema(String(value),schema).length);}
});
test('declared scope and labels prevent swapped values and numeric list markers',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('inventory.lookup',{version:'1',inputFormat:'json',answerScopeFields:['sku'],evidenceFields:[{path:'quantity',kind:'number',required:true,answerLabels:['quantity','数量']}]});
 const entries=[['SKU4',0],['SKU40',20]].map(([sku,quantity],i)=>({tool:'inventory.lookup',label:sku,scope:{},anchorTime:0,status:'success',output:JSON.stringify({sku,quantity}),data:{sku,quantity},resultCallId:'call-'+i}));
 assert.deepEqual(catalog.validateAnswer(entries,'SKU4 quantity: 0\nSKU40 数量：20'),[]);
 for(const answer of ['SKU4 quantity: 20\nSKU40 quantity: 0','0. SKU4 quantity: 20\nSKU40 quantity: 20','SKU40 quantity: 0\nSKU40 quantity: 20','SKU4 and SKU40 quantity: 0 quantity: 20'])assert.ok(catalog.validateAnswer(entries,answer).length,answer);
});
test('literal evidence uses token boundaries and declared numeric tolerance',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('measurement',{version:'1',inputFormat:'json',evidenceFields:[{path:'id',kind:'literal',required:true},{path:'value',kind:'number',required:true,answerLabels:['value'],tolerance:0.01}]});
 const entry={tool:'measurement',label:'sample',scope:{},anchorTime:0,status:'success',output:'SKU4 value 10',data:{id:'SKU4',value:10}};
 assert.deepEqual(catalog.validateAnswer([entry],'SKU4 value 10.005'),[]);
 for(const answer of ['SKU40 value 10','SKU4 value 10.1','SKU4 value 10 and value 11'])assert.ok(catalog.validateAnswer([entry],answer).length);
 for(const fact of [{path:'value',kind:'number',tolerance:-1},{path:'value',kind:'number',tolerance:Infinity},{path:'value',kind:'number',answerLabels:['']}])assert.throws(()=>catalog.register('bad',{version:'1',inputFormat:'json',evidenceFields:[fact]}));
});
test('close-handler failures do not prevent other cleanup including late registration',async()=>{
 const registry=new ToolRegistry();let closes=0;registry.registerCloseHandler(async()=>{throw Error('provider close failed');});registry.registerCloseHandler(async()=>{closes++;});
 await registry.close();registry.registerCloseHandler(async()=>{closes++;});await tick();assert.equal(closes,2);
});
test('validated result synthesis preserves additional writing after dependent calls',async()=>{
 const registry=new ToolRegistry();const name='measurement.value';const declaration={version:'1',inputFormat:'json',inputSchema:{type:'object',required:['id'],properties:{id:{type:'string'}}},outputSchema:{type:'object',required:['value'],properties:{value:{type:'number'}}},evidenceFields:[{path:'value',kind:'number',required:true}],finalization:'result'};
 registry.register(fixture(name,async(input)=>{const value=JSON.parse(input).id==='A'?5:6;return{...typed({value}),displayText:'quantity: '+value};},declaration),policy);
 const synthesis='A: 5. B: 6.\n云随风起，月照归途。';
 const r=await run(registry,'Read both quantities and write a poem',[manifest([{id:'a',tool:name,input:{id:'A'},label:'A'},{id:'b',tool:name,input:{id:'B'},label:'B'}])+'\n'+action(name,{id:'A'}),action(name,{id:'B'}),'Final: '+synthesis]);
 assert.equal(r.prompts.length,3);assert.equal(r.final,synthesis);assert.ok(!r.prompts[1].includes(action(name,{id:'A'})));
 // A display omitting declared facts must not replace a valid synthesis.
 const books=new ToolRegistry();books.register(fixture('new.books',async()=>typed({isbn:'A',title:'Edition A'}),bookContract()),policy);
 const b=await run(books,'Use new.books to read A',[action('new.books',{isbn:'A'}),'Final: Edition A']);assert.equal(b.final,'Edition A');
});
const taskContract=load('agent/TaskContract.ets');
test('valid synthesis covers extra deliverables in two model calls without an unconditional review',async()=>{
 for(const task of ['读取资料并解释结论，再写一首诗','先核对数据，我还想知道建议的规模和理由']){
  const r=await run(probes('arbitrary.lookup'),task,[action('arbitrary.lookup',{key:'A'}),'Final: value 10. 建议规模为两组，理由是易于比较。云随风起。',new Error('an unnecessary third call')],{finalReview:true});
  assert.equal(r.prompts.length,2);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/两组/);assert.match(r.final,/云随风起/);
  assert.match(r.prompts[1],new RegExp(task));assert.match(r.prompts[1],/Call call-1/);assert.match(r.prompts[1],/quantities|quantity/);assert.ok(!r.prompts[1].includes(action('arbitrary.lookup',{key:'A'})));
 }
});
function editionRegistry(){const registry=new ToolRegistry();registry.register(fixture('edition.lookup',async()=>({...typed({isbn:'A',title:'Edition A'}),displayText:'Edition A'}),bookContract()),policy);return registry;}

test('synthesis and conditional review retain executed inputs and concrete issues without importing a rejected draft',async()=>{
 for(const name of ['catalog.lookup','renamed.reader']){
  const registry=new ToolRegistry(),inputs=[];
  registry.register(fixture(name,async input=>{inputs.push(input);return typed({isbn:'A',title:'Edition A'});},
   {...bookContract(),prepareInput:()=>JSON.stringify({isbn:'A'})}),policy);
  const r=await run(registry,'使用'+name+'读取目标资料',[action(name,{isbn:'B'}),'Final: REJECTED_DRAFT Edition B','Final: Edition A'],{compact:true,finalReview:true});
  assert.deepEqual(inputs,['{"isbn":"A"}']);assert.equal(r.prompts.length,3);assert.equal(r.final,'Edition A');
  assert.match(r.prompts[1],/Executed input: \{"isbn":"A"\}/);
  assert.match(r.prompts[2],/执行输入（数据）：\{"isbn":"A"\}/);
  assert.match(r.prompts[2],/待修正问题（数据）：\n\["[^\n]+"\]/);
  assert.doesNotMatch(r.prompts[2],/REJECTED_DRAFT|Edition B|"isbn":"B"/);
 }
});
test('conditional repair cannot execute another tool or repeatedly request a new review',async()=>{
 const r=await run(editionRegistry(),'使用edition.lookup读取A',[action('edition.lookup',{isbn:'A'}),'Final: Edition B',action('edition.lookup',{isbn:'B'})],{finalReview:true});
 assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/Edition A/);assert.doesNotMatch(r.final,/Edition B/);
});
test('conditional repair transport failure preserves real tool evidence rather than an invalid draft',async()=>{
 const r=await run(editionRegistry(),'使用edition.lookup读取A',[action('edition.lookup',{isbn:'A'}),'Final: Edition B',new Error('review offline')],{finalReview:true});
 assert.equal(r.prompts.length,3);assert.match(r.final,/Edition A/);assert.doesNotMatch(r.final,/Edition B|工具.*失败/);
});
test('review cannot override owner evidence validation and never loops over unsupported facts',async()=>{
 const registry=new ToolRegistry();registry.register(fixture('edition.lookup',async()=>({...typed({isbn:'A',title:'Edition A'}),displayText:'Edition A'}),bookContract()),policy);
 const r=await run(registry,'使用edition.lookup读取A',[action('edition.lookup',{isbn:'A'}),'Final: Edition B','Final: Edition B'],{finalReview:true});
 assert.equal(r.prompts.length,3);assert.match(r.final,/Edition A/);assert.doesNotMatch(r.final,/Edition B/);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);
});
test('review cancellation publishes neither draft nor late final',async()=>{
 let runner;const r=await run(editionRegistry(),'使用edition.lookup读取A',[action('edition.lookup',{isbn:'A'}),'Final: Edition B','Final: late Edition A'],{finalReview:true,onRunner:x=>runner=x,onModelPrompt:p=>{if(p.includes('Final review phase'))runner.requestStop();}});
 assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.FINAL).length,0);assert.ok(r.events.some(e=>e.kind===K.ERROR&&/已停止/.test(e.text)));
});
test('rail adapter preserves requested category across routes without changing ambiguous calls',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('train_search',load('agent/contracts/TrainContract.ets').trainContract());
 for(const [route,kind] of [['南京到上海','高铁'],['杭州到苏州','动车']]){
  const ledger=core.buildTaskLedger('查一下明天'+route+'的'+kind+'票',Date.now(),catalog),call={name:'train_search',input:JSON.stringify({query:'明天'+route+'车次'})};
  assert.equal(ledger.length,1);assert.deepEqual(core.prepareCalls([call],ledger,catalog),[]);assert.ok(JSON.parse(call.input).query.includes(kind));assert.equal(catalog.matches(ledger[0],call),true);
  const unrelated={name:'train_search',input:JSON.stringify({query:'明天广州到长沙车次'})};core.prepareCalls([unrelated],ledger,catalog);assert.ok(!JSON.parse(unrelated.input).query.includes(kind));
 }
});
test('structured answer scopes keep heading entities with their facts and exclude the next section',()=>{
 const {scopedSections}=load('agent/contracts/TaskText.ets');
 const entry={scope:{entity:'对象甲',date:'明天',timeWindow:''},anchorTime:Date.now()};
 const answer='1. 对象甲\n明天结果为10°C。\n2. 对象乙\n明天结果为20°C。';
 const selected=scopedSections(entry,answer,/结果/);assert.equal(selected.length,1);assert.match(selected[0],/10°C/);assert.doesNotMatch(selected[0],/20°C/);
});
test('semantic review relaxes only declared wording heuristics and retains status and structured facts',()=>{
 for(const mode of ['heuristic','strict']){
  const catalog=new contracts.ToolContractCatalog();catalog.register('renamed.note',{version:'1',inputFormat:'json',answerValidation:mode,
   evidenceFields:[{path:'value',kind:'number',required:true,answerLabels:['value']}],validateAnswer:()=>['exact phrase missing']});
  const entry={tool:'renamed.note',label:'item',scope:{entity:'item'},anchorTime:0,status:'success',output:'value 10',data:{value:10}};
  assert.ok(catalog.validateAnswer([entry],'value 10').length);
  assert.deepEqual(catalog.validateAnswer([entry],'value 10',true),mode==='heuristic'?[]:['exact phrase missing']);
  assert.ok(catalog.validateAnswer([entry],'value 20',true).length);
  for(const status of ['pending','failed'])assert.ok(catalog.validateAnswer([{...entry,status}],'value 10',true).length);
 }
});
test('reviewed natural answer is displayed instead of replaced by tool text after wording-only rejection',async()=>{
 const name='new.service',registry=new ToolRegistry();registry.register(fixture(name,async()=>({...typed({value:10}),displayText:'tool value 10'}),{
  version:'1',inputFormat:'json',answerValidation:'heuristic',evidenceFields:[{path:'value',kind:'number',required:true}],
  recognize:(_task,anchor)=>[{tool:name,label:'item',scope:{entity:'item'},anchorTime:anchor,status:'pending',output:''}],matches:()=>true,
  validateAnswer:()=>['legacy exact phrase missing']}),policy);
 const r=await run(registry,'Explain this result and add advice',[action(name,{}),'Final: result 10','Final: Result 10. Additional advice is preserved.'],{finalReview:true});
 assert.equal(r.prompts.length,3);assert.equal(r.final,'Result 10. Additional advice is preserved.');assert.doesNotMatch(r.final,/综合回答未完成|tool value/);
});
test('list numbering is presentation rather than a numeric fact and cannot satisfy a required result',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('numeric.lookup',{version:'1',inputFormat:'json',restrictNumericClaims:true,evidenceFields:[{path:'value',kind:'number',required:true}]});
 const entry={tool:'numeric.lookup',label:'value',scope:{},anchorTime:0,status:'success',output:'value 10',data:{value:10}};
 assert.deepEqual(catalog.validateAnswer([entry],'1. value 10\n2. explanation',true),[]);
 assert.ok(catalog.validateAnswer([entry],'10. missing result',true).length);
 assert.ok(catalog.validateAnswer([entry],'1. value 10\n2. value 99',true).length);
});
test('final composition isolates prior answers in both prompt and model context while execution retains references',async()=>{
 const conversation={isEmpty:()=>false,toChatMessages:()=>[{role:'user',content:'Previous context: object A'},{role:'assistant',content:'STALE_ANSWER value 99'}]};
 const r=await run(probes(),'Read that object and explain the current result',[action('probe',{key:'A'}),'Final: current value 10'],{conversation,finalReview:true});
 assert.equal(r.prompts.length,2);assert.match(r.prompts[0],/STALE_ANSWER/);assert.equal(r.contexts[0],conversation);
 assert.doesNotMatch(r.prompts[1],/STALE_ANSWER|99/);assert.equal(r.contexts[1],undefined);assert.match(r.prompts[1],/value: 10/);assert.match(r.final,/current value 10/);
});
test('preparation receives immutable original task context independently of requirement recognizers',async()=>{
 let received;const registry=new ToolRegistry();registry.register(fixture('arbitrary.input',async()=> 'ok',{
  version:'1',inputFormat:'json',prepareInput:(call,_entries,task)=>{received=task;return call.input;}}),policy);
 const task='A new phrasing without a registered requirement recognizer.';
 const r=await run(registry,task,[action('arbitrary.input',{}),'Final: ok']);assert.equal(received,task);assert.equal(r.final,'ok');
});
test('repeated completed cacheable reads transition once to composition without replay or losing extra writing',async()=>{
 const read=action('probe',{key:'A'});
 const r=await run(probes(),'Read A and add a poem',[read,read,'Final: value 10. 云随风起。'],{finalReview:true});
 assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/value 10/);assert.match(r.final,/云随风起/);
});
test('rail preparation preserves unambiguous clock operators from original context across numeric forms',()=>{
 const catalog=new contracts.ToolContractCatalog();catalog.register('train_search',load('agent/contracts/TrainContract.ets').trainContract());
 for(const [task,query,expected] of [['想乘上午九点前后的高铁','明天深圳到北京9点前高铁','上午九点前后'],['想乘上午九点前后的高铁','明天深圳到北京高铁','上午九点前后'],['请查下午三点附近的动车','明天上海到南京15:00后动车','下午三点附近'],['想乘上午九点半左右的高铁','明天南京到杭州09:30前高铁','上午九点半左右']]){
  const call={name:'train_search',input:JSON.stringify({query})};core.prepareCalls([call],[],catalog,task);assert.ok(JSON.parse(call.input).query.includes(expected));
 }
 for(const task of ['上午九点前后开会，然后坐高铁','不考虑上午九点前后的高铁','上午九点前后的高铁；下午三点附近的动车','上午九点半左右的高铁']){
  const call={name:'train_search',input:JSON.stringify({query:'明天北京到上海09:00前高铁'})},before=call.input;core.prepareCalls([call],[],catalog,task);assert.equal(call.input,before);
 }
});
test('partial evidence for a new request drops past answers but still permits missing independent queries',async()=>{
 const context={isEmpty:()=>false,toChatMessages:()=>[{role:'user',content:'old request'},{role:'assistant',content:'OLD_UNSUPPORTED_FACT 99'}]};
 const r=await run(probes(),'Read two new independent objects',[action('probe',{key:'A'}),action('probe',{key:'B'}),'Final: value 10 and value 20'],{conversation:context});
 assert.match(r.prompts[0],/OLD_UNSUPPORTED_FACT/);assert.doesNotMatch(r.prompts[1],/OLD_UNSUPPORTED_FACT/);assert.equal(r.contexts[1],undefined);
 assert.deepEqual(r.events.filter(e=>e.kind===K.ACTION).map(e=>JSON.parse(e.input).key),['A','B']);
 assert.equal(r.final,'value 10 and value 20');
});
test('ordinary callers default to text ReAct without requiring a task-goal protocol',async()=>{
 const registry=new ToolRegistry(),prompts=[],events=[];
 registry.register(fixture('lookup',async()=> 'current result'),policy);
 const responses=[action('lookup',{}),'Final: current result; requested extra prose'];let index=0;
 const runner=new ReActAgentRunner({complete:async p=>{prompts.push(p);return responses[index++];}},registry,6);
 await runner.run('Look up a value and add prose',e=>events.push(e));
 assert.equal(prompts.length,2);assert.doesNotMatch(prompts[0],/Task contract mode|First return Plan goals/);
 assert.equal(events.filter(e=>e.kind===K.ACTION).length,1);assert.equal(events.find(e=>e.kind===K.FINAL).text,'current result; requested extra prose');
});
const {TaskCoordinator,validateTaskGraph,graphNodeMayParallel}=load('agent/TaskCoordinator.ets');
const {ReActTaskWorker}=load('agent/ReActTaskWorker.ets');
const {planTaskGraph}=load('agent/TaskPlanner.ets');
const {ModelTaskAggregator}=load('agent/ModelTaskAggregator.ets');
const goal=(id,tools=['probe'],fields=['值'],kind='fact')=>({id,label:id,fields,tools,kind});
const goalPlan=goals=>'Plan: '+JSON.stringify({goals});
const answer=(id,values,evidence,status='answered',reason)=>({id,status,values,evidence,...(reason?{reason}:{})});
const final=answers=>'Final: '+JSON.stringify({answers});
function probes(name='probe'){const registry=new ToolRegistry();registry.register(fixture(name,async(input)=>{const value=JSON.parse(input).key==='A'?10:20;return{...typed({value}),displayText:'value: '+value};},{version:'1',inputFormat:'json',inputSchema:{type:'object',required:['key'],properties:{key:{type:'string'}}},outputSchema:{type:'object',required:['value'],properties:{value:{type:'number'}}},evidenceFields:[{path:'value',kind:'number',required:true}]}),policy);return registry;}

test('generic goal plans reject forged status permissions duplicate fields and unknown tools',()=>{
 const good=[goal('a')];assert.equal(taskContract.parseTaskGoals(good,n=>n==='probe').error,'');
 for(const bad of [[],[goal('a'),goal('a')],[{...goal('a'),status:'success'}],[{...goal('a'),readOnly:true}],[{...goal('a'),fields:['值','值']}],[{...goal('a'),tools:['missing']}],[{...goal('a'),kind:'completed'}]])assert.ok(taskContract.parseTaskGoals(bad,n=>n==='probe').error);
});
test('all arbitrary deliverable fields must exist and cannot be replaced by a different goal',()=>{
 const goals=[goal('facts'),goal('advice',['probe'],['数量','说明'],'inference')],ev=[{callId:'call-1',tool:'probe',status:'success',output:'value10',facts:'{"value":10}',goalIds:['facts','advice']}];
 const good=[answer('facts',{'值':10},['call-1']),answer('advice',{'数量':'2到3','说明':'derived recommendation'},['call-1'])];assert.equal(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:good}),ev).complete,true);
 for(const bad of [[good[0]],[good[0],answer('advice',{'说明':'recommendation'},['call-1'])],[good[0],good[0]],[good[0],answer('other',{'数量':2,'说明':'x'},['call-1'])]])assert.ok(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:bad}),ev).issues.length);
 assert.equal(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:good}),[]).issues.length>0,true);
});
test('same-tool goal references cannot swap values or use stale call IDs',()=>{
 const goals=[goal('a'),goal('b')],ev=[{callId:'one',tool:'probe',status:'success',output:'10',facts:'{"value":10}',goalIds:['a']},{callId:'two',tool:'probe',status:'success',output:'20',facts:'{"value":20}',goalIds:['b']}];
 assert.deepEqual(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:[answer('a',{'值':10},['one']),answer('b',{'值':20},['two'])]}),ev).issues,[]);
 for(const value of [[answer('a',{'值':20},['two']),answer('b',{'值':10},['one'])],[answer('a',{'值':20},['one']),answer('b',{'值':10},['two'])],[answer('a',{'值':10},['old']),answer('b',{'值':20},['two'])]])assert.ok(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:value}),ev).issues.length);
});
test('tool failures and worker dispatch failures remain distinct terminal evidence',()=>{
 const goals=[goal('a')],ev=[{callId:'node/control',tool:'',source:'worker',goalIds:['a'],status:'unavailable',output:'device offline'}];
 const check=taskContract.checkTaskAnswer(goals,JSON.stringify({answers:[answer('a',{},['node/control'],'unavailable','device offline')]}),ev);
 assert.deepEqual(check.issues,[]);assert.equal(check.complete,false);assert.match(check.text,/未完成/);
 assert.ok(taskContract.checkTaskAnswer(goals,JSON.stringify({answers:[answer('a',{'值':10},['node/control'])]}),ev).issues.length);
});
test('default task mode binds metadata for renamed arbitrary tools and renders all goal fields',async()=>{
 for(const name of ['probe','renamed.lookup','totally_new']){
  const registry=probes(name),goals=[goal('a',[name]),goal('b',[name])];
  const r=await run(registry,'Two independent values',[goalPlan(goals)+'\nExecution: parallel\nFor: ["a"]\n'+action(name,{key:'A'})+'\nFor: ["b"]\n'+action(name,{key:'B'}),final([answer('a',{'值':10},['call-1']),answer('b',{'值':20},['call-2'])])],{taskContracts:true});
  assert.equal(r.prompts.length,2);assert.equal(r.final,'a：\n值：10\n\nb：\n值：20');assert.ok(r.prompts[1].includes('"goalIds":["a"]'));assert.ok(!r.prompts[1].includes(action(name,{key:'A'})));
 }
});
test('missing generic answer field is repaired once without repeating tools',async()=>{
 const registry=probes(),goals=[goal('a'),goal('b',['probe'],['数量','解释'],'inference')];
 const r=await run(registry,'Facts and derived advice',[goalPlan(goals)+'\nFor: ["a","b"]\n'+action('probe',{key:'A'}),final([answer('a',{'值':10},['call-1'])]),final([answer('a',{'值':10},['call-1']),answer('b',{'数量':'2','解释':'derived'},['call-1'])])],{taskContracts:true});
 assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/数量：2/);assert.match(r.final,/推导建议/);
});
test('invalid Final cannot restart tools and repeated Final is bounded to one correction',async()=>{
 for(const last of [action('probe',{key:'B'}),'Final: still invalid']){
  const registry=probes(),goals=[goal('a')];const r=await run(registry,'Read A',[goalPlan(goals)+'\n'+action('probe',{key:'A'}),'Final: invalid',last],{taskContracts:true});
  assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/综合回答未完成/);assert.match(r.final,/value: 10/);
 }
});
test('extra writing deliverables survive without being replaced by tool-only presentation',async()=>{
 const registry=probes(),goals=[goal('a'),goal('poem',[],['正文'],'inference')];
 const r=await run(registry,'Read value and write a poem',[goalPlan(goals)+'\n'+action('probe',{key:'A'}),final([answer('a',{'值':10},['call-1']),answer('poem',{'正文':'云随风起'},[])])],{taskContracts:true});assert.match(r.final,/云随风起/);assert.match(r.final,/值：10/);
});
test('repeated cached plans cannot keep generic task mode inferring indefinitely',async()=>{
 const registry=probes(),goals=[goal('a')],act=action('probe',{key:'A'});const r=await run(registry,'Read A',[goalPlan(goals)+'\n'+act,act],{taskContracts:true});
 assert.equal(r.prompts.length,3);assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(r.final,/终止循环/);
});
test('task goal omission prevents dispatch and an executed plan cannot rewrite goal IDs',async()=>{
 const registry=probes();const r=await run(registry,'Read A',[action('probe',{key:'A'}),'Final: 10'],{taskContracts:true});assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,0);
 const q=await run(probes(),'Read A',[goalPlan([goal('a')])+'\n'+action('probe',{key:'A'}),goalPlan([goal('b')])+'\n'+action('probe',{key:'B'})],{taskContracts:true});assert.equal(q.events.filter(e=>e.kind===K.ACTION).length,1);assert.match(q.final,/冻结/);
});
const graph=()=>({goals:[goal('a'),goal('b'),goal('c',['probe'],['建议'],'inference')],nodes:[{id:'a',goalIds:['a'],dependsOn:[]},{id:'b',goalIds:['b'],dependsOn:[]},{id:'c',goalIds:['c'],dependsOn:['a','b']}]});
const resultFor=(workerId,req,value=10)=>({taskId:req.taskId,subtaskId:req.subtaskId,attemptId:req.attemptId,workerId,status:'success',text:'value '+value,evidence:[{callId:req.attemptId+'/call-1',tool:'probe',status:'success',output:'value '+value,facts:JSON.stringify({value}),goalIds:req.goals.map(g=>g.id)}]});
function aggregator(counter={calls:0}){return{cancel:()=>{},complete:async(_id,g,results,ev)=>{counter.calls++;return JSON.stringify({answers:g.goals.map(item=>{const node=g.nodes.find(n=>n.goalIds.includes(item.id)),r=results.find(x=>x.subtaskId===node.id);if(r.status!=='success'){const proof=ev.find(x=>x.source==='worker'&&x.goalIds.includes(item.id));return answer(item.id,{},[proof.callId],'unavailable',r.text);}const proof=ev.find(x=>x.status==='success'&&x.goalIds.includes(item.id));return answer(item.id,Object.fromEntries(item.fields.map(f=>[f,item.kind==='inference'?'derived 2':JSON.parse(proof.facts).value])),[proof.callId]);})});}};}
test('task graphs reject cycles missing goals duplicate ownership and forged permissions',()=>{
 const good=graph();assert.deepEqual(validateTaskGraph(good),[]);
 for(const change of [g=>g.nodes[0].dependsOn=['c'],g=>g.nodes.pop(),g=>g.nodes[1].goalIds=['a'],g=>g.nodes[0].dependsOn=['missing'],g=>g.nodes[0].readOnly=true,g=>g.goals.push(goal('a'))]){const copy=JSON.parse(JSON.stringify(good));change(copy);assert.ok(validateTaskGraph(copy).length);}
});
test('two workers run independent nodes concurrently dependency waits and aggregate runs once',async()=>{
 const started=[],held=[],count={calls:0};let both;const ready=new Promise(r=>both=r);
 const workers=['device-a','device-b'].map(id=>({id,capacity:1,supports:()=>true,cancel:()=>{},execute:async req=>{started.push(req.subtaskId);if(req.subtaskId==='c'){assert.equal(req.dependencies.length,2);assert.ok(req.dependencies.every(x=>x.status==='success'));return resultFor(id,req,30);}return new Promise(resolve=>{held.push(()=>resolve(resultFor(id,req,req.subtaskId==='a'?10:20)));if(held.length===2)both();});}}));
 const coordinator=new TaskCoordinator(2,1000),pending=coordinator.run('parallel',graph(),workers,()=>true,aggregator(count));await ready;assert.deepEqual(started,['a','b']);held[1]();await tick();assert.deepEqual(started,['a','b']);held[0]();const r=await pending;
 assert.equal(r.status,'success');assert.equal(count.calls,1);assert.deepEqual(started,['a','b','c']);assert.notEqual(r.results[0].workerId,r.results[1].workerId);
});
test('unknown or mutating safety policy serializes otherwise independent worker nodes',async()=>{
 let active=0,max=0;const workers=['one','two'].map(id=>({id,capacity:1,supports:()=>true,cancel:()=>{},execute:async req=>{active++;max=Math.max(max,active);await wait(2);active--;return resultFor(id,req);}}));
 const r=await new TaskCoordinator(2).run('serial',graph(),workers,()=>false,aggregator());assert.equal(r.status,'success');assert.equal(max,1);
});
test('failed worker blocks dependent only preserves sibling and does not auto replay',async()=>{
 let calls=0;const worker={id:'one',capacity:2,supports:()=>true,cancel:()=>{},execute:async req=>{calls++;if(req.subtaskId==='a')throw Error('device offline');return resultFor('one',req,20);}};
 const r=await new TaskCoordinator(2).run('fail',graph(),[worker],()=>true,aggregator());assert.equal(calls,2);assert.equal(r.status,'partial');assert.deepEqual(r.results.map(x=>x.status),['failed','success','blocked']);assert.match(r.answer,/device offline/);
});
test('worker timeouts settle locally even if cancellation throws',async()=>{
 let cancels=0;const worker={id:'slow',capacity:2,supports:()=>true,cancel:()=>{cancels++;throw Error('closed');},execute:async()=>new Promise(()=>{})};
 const r=await new TaskCoordinator(2,5).run('timeout',graph(),[worker],()=>true,aggregator());assert.equal(r.status,'partial');assert.equal(cancels,2);assert.equal(r.results[2].status,'blocked');
});
test('cancel ignores late worker output skips aggregation and reused task IDs get fresh attempts',async()=>{
 const jobs=[],requests=[],count={calls:0};let started;const ready=new Promise(r=>started=r);
 const worker={id:'one',capacity:1,supports:()=>true,cancel:()=>{throw Error('closed');},execute:async req=>{requests.push(req);started();return new Promise(resolve=>jobs.push(resolve));}};
 const one={goals:[goal('a')],nodes:[{id:'a',goalIds:['a'],dependsOn:[]}]},coordinator=new TaskCoordinator();const old=coordinator.run('same',one,[worker],()=>true,aggregator(count));await ready;coordinator.requestStop();const stopped=await old;assert.equal(stopped.status,'cancelled');assert.equal(count.calls,0);
 const current=coordinator.run('same',one,[worker],()=>true,aggregator(count));await tick();assert.notEqual(requests[0].attemptId,requests[1].attemptId);jobs[0](resultFor('one',requests[0],99));await tick();jobs[1](resultFor('one',requests[1],10));const r=await current;assert.equal(r.status,'success');assert.doesNotMatch(r.answer,/99/);assert.equal(count.calls,1);
});
test('forged worker identity cross-attempt evidence and callback mutation are rejected or isolated',async()=>{
 for(const mutation of [r=>r.taskId='other',r=>r.evidence[0].callId='old/call-1',r=>r.evidence[0].tool='writer',r=>r.evidence.push(r.evidence[0])]){
  const worker={id:'one',capacity:1,supports:req=>{req.goals[0].fields.push('forged');return true;},cancel:()=>{},execute:async req=>{assert.deepEqual(req.goals[0].fields,['值']);const r=resultFor('one',req);mutation(r);return r;}};
  const g={goals:[goal('a')],nodes:[{id:'a',goalIds:['a'],dependsOn:[]}]};const r=await new TaskCoordinator().run('owned',g,[worker],()=>true,aggregator());assert.equal(r.status,'partial');assert.equal(r.results[0].status,'failed');assert.deepEqual(g.goals[0].fields,['值']);
 }
});
test('aggregation failures preserve worker results and never trigger another aggregation',async()=>{
 const g={goals:[goal('a')],nodes:[{id:'a',goalIds:['a'],dependsOn:[]}]},worker={id:'one',capacity:1,supports:()=>true,cancel:()=>{},execute:async req=>resultFor('one',req)};
 for(const response of ['{"answers":[]}',new Error('summary transport failed')]){let calls=0;const a={cancel:()=>{},complete:async()=>{calls++;if(response instanceof Error)throw response;return response;}};const r=await new TaskCoordinator().run('aggregate',g,[worker],()=>true,a);assert.equal(calls,1);assert.equal(r.status,'partial');assert.match(r.answer,/value 10/);}
});
test('planner uses a generic dependency graph and cannot execute actions while planning',async()=>{
 const g=graph(),text='Plan: '+JSON.stringify({goals:g.goals,nodes:g.nodes});let prompt;
 const plan=await planTaskGraph('Arbitrary compound task',{complete:async p=>{prompt=p;return text;}},'probe schema',n=>n==='probe');assert.deepEqual(plan.nodes,g.nodes);assert.match(prompt,/Planning phase ONLY/);
 await assert.rejects(planTaskGraph('task',{complete:async()=>text+'\n'+action('probe',{key:'A'})},'',()=>true));
});
test('actual ReAct workers isolate call IDs reuse dependency evidence and aggregate once',async()=>{
 const g=graph();let calls=0,aggregateCalls=0;
 const workers=['cpu-a','cpu-b'].map(id=>new ReActTaskWorker(id,1,async req=>{
  const registry=probes(),isDerived=req.subtaskId==='c';let step=0;
  const proof=isDerived?req.dependencies[0].evidence[0].callId:req.attemptId+'/call-1';
  const model={complete:async prompt=>{calls++;if(isDerived){const input=req.dependencies[0].evidence[0].input;assert.equal(typeof input,'string');assert.ok(prompt.includes(JSON.stringify(input)));}if(!isDerived&&step++===0)return action('probe',{key:req.subtaskId==='a'?'A':'B'});return final([answer(req.goals[0].id,{[req.goals[0].fields[0]]:isDerived?'derived 2':req.subtaskId==='a'?10:20},[proof])]);}};
  return{model,tools:registry,prompt:'Execute assigned goals',maxPromptBytes:()=>32768};
 },()=>true));
 const modelAggregator=new ModelTaskAggregator({complete:async prompt=>{aggregateCalls++;assert.match(prompt,/Aggregation phase ONLY/);assert.ok(prompt.includes(JSON.stringify('{"key":"A"}')));return final([answer('a',{'值':10},['actual/a/1-1/call-1']),answer('b',{'值':20},['actual/b/1-2/call-1']),answer('c',{'建议':'derived 2'},['actual/a/1-1/call-1'])]);}});
 const r=await new TaskCoordinator(2).run('actual',g,workers,()=>true,modelAggregator);assert.equal(r.status,'success');assert.equal(calls,5);assert.equal(aggregateCalls,1);assert.equal(r.results[2].evidence.length,0);assert.match(r.answer,/推导建议/);
});
test('coordinator and task contract modules contain no built-in domain rules',()=>{
 for(const file of ['TaskContract.ets','TaskCoordinator.ets','TaskPlanner.ets','ReActTaskWorker.ets','ModelTaskAggregator.ets'])assert.doesNotMatch(fs.readFileSync(path.join(root,'agent',file),'utf8'),/weather_search|train_search|map_search|air_quality|unit_convert|calculator|clothing|layers|温度|穿衣/);
});
test('graph parallel policy trusts registered metadata and denies unknown or mutating tools',()=>{
 const g=graph(),node=g.nodes[0];assert.equal(graphNodeMayParallel(node,g.goals,()=>({readOnly:true,risk:'low'})),true);
 for(const meta of [{},{readOnly:true,risk:'high'},{readOnly:false,risk:'low'}])assert.equal(graphNodeMayParallel(node,g.goals,()=>meta),false);
 assert.equal(graphNodeMayParallel(node,g.goals,()=>{throw Error('unknown');}),false);
});
test('scoped registry cancellation cannot stop another worker invocation',async()=>{
 const registry=new ToolRegistry(),jobs=[];registry.register(fixture('deferred',async()=>new Promise(resolve=>jobs.push(resolve))),policy);
 const a=registry.run('deferred','{}','worker-a/call-1'),b=registry.run('deferred','{}','worker-b/call-1');await tick();registry.cancelActive('worker-a/');assert.equal((await a).stop,true);
 jobs[0]('late');await tick();assert.equal(registry.activeInvocations.size,1);jobs[1]('other completed');assert.equal((await b).displayText,'other completed');
});
test('aggregator timeout and cancellation settle without a second synthesis',async()=>{
 const g={goals:[goal('a')],nodes:[{id:'a',goalIds:['a'],dependsOn:[]}]},worker={id:'one',capacity:1,supports:()=>true,cancel:()=>{},execute:async req=>resultFor('one',req)};
 let calls=0,cancels=0;const a={complete:async()=>{calls++;return new Promise(()=>{});},cancel:()=>{cancels++;throw Error('disconnected');}};
 const timed=await new TaskCoordinator(1,5).run('agg-timeout',g,[worker],()=>true,a);assert.equal(timed.status,'partial');assert.equal(calls,1);assert.equal(cancels,1);assert.match(timed.answer,/value 10/);
 let began;const ready=new Promise(r=>began=r),coordinator=new TaskCoordinator();const pending=coordinator.run('agg-cancel',g,[worker],()=>true,{complete:async()=>{began();return new Promise(()=>{});},cancel:()=>{throw Error('closed');}});await ready;coordinator.requestStop();assert.equal((await pending).status,'cancelled');
});
test('device metadata ordering runs once and final phase prompts remain consistent',async()=>{
 const goals=[goal('a'),goal('b')],prefix=goalPlan(goals);
 const actions='For: ["a"]\nExecution: serial\n'+action('probe',{key:'A'})+'\nFor: ["b"]\nExecution: serial\n'+action('probe',{key:'B'});
 const parsed=core.parseCorePlan(prefix+'\n'+actions,n=>n==='probe');
 assert.equal(parsed.error,'');assert.deepEqual(parsed.calls.map(c=>c.goalIds),[['a'],['b']]);
 for(const bad of ['Execution: parallel\n'+actions,actions+'\nExecution: parallel\n'+action('probe',{key:'A'}),actions+'\nFinal: forged'])assert.ok(core.parseCorePlan(prefix+'\n'+bad,n=>n==='probe').error);
 const r=await run(probes(),'Two values',[prefix+'\n'+actions,'Final: invalid',final([answer('a',{'值':10},['call-1']),answer('b',{'值':20},['call-2'])])],{taskContracts:true});
 assert.equal(r.prompts.length,3);assert.match(r.final,/值：10/);assert.match(r.final,/值：20/);
 assert.match(r.prompts[0],/Control: First return Plan goals/);assert.doesNotMatch(r.prompts[0],/optionally declare Plan/);
 assert.match(r.prompts[2],/Control: Return corrected Final answers JSON only/);
 assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,2);
});
test('same-tool evidence cannot satisfy an unexecuted goal',()=>{
 assert.deepEqual(taskContract.missingGoalTools([goal('a'),goal('b')],[{callId:'call-1',tool:'probe',status:'success',output:'10',goalIds:['a']}]),['probe']);
});
test('synthesis keeps dependent work possible and planning retains referenced context',async()=>{
 const goals=[goal('a')],context={isEmpty:()=>false,toChatMessages:()=>[{role:'user',content:'The referenced object is A'},{role:'assistant',content:'Previous answer is context only'}]};
 const r=await run(probes(),'Use that object then use its result',[goalPlan(goals),action('probe',{key:'A'}),action('probe',{key:'B'}),final([answer('a',{'值':20},['call-2'])])],{taskContracts:true,conversation:context});
 assert.equal(r.prompts.length,4);assert.match(r.prompts[0],/referenced object is A/);assert.match(r.prompts[0],/Planning phase ONLY/);
 assert.match(r.prompts[2],/Actual evidence/);assert.ok(!r.prompts[2].includes(action('probe',{key:'A'})));
 assert.equal(r.events.filter(e=>e.kind===K.ACTION).length,2);assert.match(r.final,/值：20/);
});
test('complete final tolerates redundant root closers without changing content or adding a model call',async()=>{
 const goals=[goal('a')],value=final([answer('a',{'值':10},['call-1'])]);
 const r=await run(probes(),'Read A',[goalPlan(goals)+'\n'+action('probe',{key:'A'}),value+'}'],{taskContracts:true});
 assert.equal(r.prompts.length,2);assert.equal(r.final,'a：\n值：10');
 const writing=[goal('text',[],['正文'],'inference')],body=JSON.stringify({answers:[answer('text',{'正文':'text } [ \\" intact'},[])]});
 assert.match(taskContract.checkTaskAnswer(writing,body+'}}',[]).text,/text } \[/);
 for(const bad of [body+'{}',body+'\nAction: probe[{}]',body+'trailing',body.slice(0,-2),body+']'])assert.ok(taskContract.checkTaskAnswer(writing,bad,[]).issues.length);
});
test('worker pending factory reserves capacity cancellation wins and stale dependencies reject',async()=>{
 let open,modelCalls=0;const waitFactory=new Promise(r=>open=r);
 const worker=new ReActTaskWorker('one',1,async()=>waitFactory,()=>true),req={taskId:'parent',subtaskId:'a',attemptId:'parent/a/1',goals:[goal('a')],dependencies:[]};
 const pending=worker.execute(req);await tick();assert.equal(worker.supports(req),false);worker.cancel(req.attemptId);
 open({tools:probes(),prompt:'task',maxPromptBytes:()=>32768,model:{complete:async()=>{modelCalls++;return final([]);},cancel:()=>{}}});const r=await pending;assert.equal(r.status,'cancelled');assert.equal(modelCalls,0);assert.equal(worker.supports(req),true);
 await assert.rejects(worker.execute({...req,dependencies:[{taskId:'other',status:'success',evidence:[]}]}),/another task/);
});
test('compact prompts retain input schemas and permission text while removing examples and duplicate evidence schemas',async()=>{
 const registry=new ToolRegistry(),declaration=bookContract();let executions=0;
 registry.register({name:()=>'edition.lookup',description:()=>'Read only; never send or modify files without confirmation.',contract:()=>declaration,
  run:async()=>{executions++;return typed({isbn:'A',title:'Edition A'});}},policy);
 const responses=[action('edition.lookup',{isbn:'A'}),'Final: Edition A'];
 const full=await run(registry,'Use edition.lookup to read A',responses,{finalReview:true});
 const compact=await run(registry,'Use edition.lookup to read A',responses,{compact:true,finalReview:true});
 assert.equal(compact.prompts.length,2);assert.equal(executions,2);assert.equal(compact.final,'Edition A');
 assert(compact.prompts[0].length<full.prompts[0].length*0.8);
 assert(compact.prompts[0].includes(JSON.stringify(declaration.inputSchema)));
 assert.match(compact.prompts[0],/never send or modify files without confirmation/);
 assert.doesNotMatch(compact.prompts[0],/Example 1|Answer evidence:/);
 assert.match(compact.prompts[1],/Edition A/);
 const invalid=await run(registry,'Use edition.lookup to read A',[action('edition.lookup',{}),...responses],{compact:true,finalReview:true});
 assert.equal(executions,3,'invalid compact input was rejected before the provider ran');assert.equal(invalid.final,'Edition A');
});

test('absolute Agent deadline does not start expired work and cancels an unresponsive model without late tool execution',async()=>{
 let calls=0,cancels=0,release;const events=[];const registry=probes();
 const model={complete:()=>{calls++;return new Promise(resolve=>release=resolve);},cancel(){cancels++;}};
 const expired=new ReActAgentRunner(model,registry,10);
 await expired.run('read A',event=>events.push(event),undefined,{namespace:'expired',goals:[],evidence:[],deadlineAt:Date.now()-1});
 assert.equal(calls,0);assert.match(events[0].text,/总时限/);
 events.length=0;
 const runner=new ReActAgentRunner(model,registry,10);
 await runner.run('read A',event=>events.push(event),undefined,{namespace:'bounded',goals:[],evidence:[],deadlineAt:Date.now()+40});
 assert.equal(calls,1);assert.equal(cancels,1);assert.equal(events.length,1);assert.match(events[0].text,/总时限/);
 release(action('probe',{key:'A'}));await tick();await tick();
 assert.equal(events.length,1);assert.equal(calls,1,'late model completion cannot start another round');
});

test('Agent timeout returns completed evidence when synthesis ignores cancellation and suppresses a late answer',async()=>{
 let calls=0,release,cancels=0;const events=[];
 const model={complete:async()=>{calls++;if(calls===1)return action('probe',{key:'A'});return new Promise(resolve=>release=resolve);},cancel(){cancels++;}};
 const runner=new ReActAgentRunner(model,probes(),10,undefined,false,false,true,()=>32768,false,true);
 await runner.run('Read A and explain it',event=>events.push(event),undefined,{namespace:'timeout',goals:[],evidence:[],deadlineAt:Date.now()+60});
 const terminal=events.at(-1);assert.equal(terminal.kind,K.FINAL);assert.equal(terminal.status,'partial');assert.match(terminal.text,/总时限|value 10/);assert.match(terminal.text,/value: 10/);assert.equal(cancels,1);
 const count=events.length;release('Final: late value 10');await tick();await tick();assert.equal(events.length,count);
});

test('a parallel batch publishes and retains each finished call before a slower sibling and starts synthesis only after all settle',async()=>{
 const registry=new ToolRegistry(),events=[],prompts=[];let releaseSlow;
 const declaration={version:'1',inputFormat:'json'};
 registry.register(fixture('source.quick',async()=>({...typed({value:10}),displayText:'value: 10'}),declaration),policy);
 registry.register(fixture('source.slow',()=>new Promise(resolve=>releaseSlow=resolve),declaration),policy);
 const model={complete:async prompt=>{prompts.push(prompt);return prompts.length===1?'Execution: parallel\n'+action('source.slow',{})+'\n'+action('source.quick',{}):'Final: values 10 and 20';}};
 const runner=new ReActAgentRunner(model,registry,6),job=runner.run('Read two independent sources',event=>events.push(event));
 await tick();await tick();
 const before={evidence:runner.getEvidence(),observations:events.filter(e=>e.kind===K.OBSERVATION),modelCalls:prompts.length};
 releaseSlow({...typed({value:20}),displayText:'value: 20'});await job;
 assert.equal(before.evidence.length,1);assert.equal(before.evidence[0].tool,'source.quick');assert.equal(before.evidence[0].input,'{}');
 assert.equal(before.evidence[0].callId,'call-2','completion order cannot reassign a result to a different invocation');
 assert.equal(before.observations.length,1);assert.equal(before.modelCalls,1,'no synthesis while another batch member is still running');
 assert.equal(prompts.length,2);assert.equal(runner.getEvidence().length,2);assert.equal(events.filter(e=>e.kind===K.FINAL).length,1);
 assert.match(prompts[1],/value.*10/);assert.match(prompts[1],/value.*20/);
});

test('whole-task timeout preserves a completed parallel result even when another tool ignores cancellation',async()=>{
 const registry=new ToolRegistry(),events=[];let releaseSlow,cancels=0;
 registry.register(fixture('source.quick',async()=>({...typed({value:10}),displayText:'value: 10'}),{version:'1',inputFormat:'json'}),policy);
 registry.register(fixture('source.slow',()=>new Promise(resolve=>releaseSlow=resolve),{version:'1',inputFormat:'json'}),policy);
 const runner=new ReActAgentRunner({complete:async()=> 'Execution: parallel\n'+action('source.quick',{})+'\n'+action('source.slow',{}),cancel(){cancels++;}},registry,6);
 await runner.run('Read independent sources',event=>events.push(event),undefined,{namespace:'batch',goals:[],evidence:[],deadlineAt:Date.now()+60});
 const terminal=events.at(-1);assert.equal(terminal.kind,K.FINAL);assert.equal(terminal.status,'partial');assert.match(terminal.text,/10/);
 assert.equal(runner.getEvidence().length,1);assert.equal(cancels,1);
 const count=events.length;releaseSlow(typed({value:20}));await tick();await tick();
 assert.equal(events.length,count);assert.equal(runner.getEvidence().length,1);
});

test('stopping on a serial result prevents the next authorized side effect in the same model batch',async()=>{
 const registry=new ToolRegistry(),executed=[],events=[];
 for(const name of ['first.change','next.change'])registry.register(fixture(name,async()=>{executed.push(name);return 'completed '+name;},{version:'1',inputFormat:'json'}));
 const runner=new ReActAgentRunner({complete:async()=> 'Execution: serial\n'+action('first.change',{})+'\n'+action('next.change',{})},registry,6);
 await runner.run('Execute the two authorized changes',event=>{events.push(event);if(event.kind===K.OBSERVATION)runner.requestStop();});
 assert.deepEqual(executed,['first.change']);assert.equal(events.filter(e=>e.kind===K.ACTION).length,1);
 assert.equal(runner.getEvidence().length,1);assert.equal(events.at(-1).kind,K.ERROR);
});

test('a progress observer failure cancels parallel siblings before returning and ignores their late completions',async()=>{
 const registry=new ToolRegistry(),events=[];let slowContext,releaseSlow;
 registry.register(fixture('source.quick',async()=> 'quick result',{version:'1',inputFormat:'json'}),policy);
 registry.register(fixture('source.slow',(_input,context)=>{slowContext=context;return new Promise(resolve=>releaseSlow=resolve);},{version:'1',inputFormat:'json'}),policy);
 const runner=new ReActAgentRunner({complete:async()=> 'Execution: parallel\n'+action('source.slow',{})+'\n'+action('source.quick',{})},registry,6);
 try{
  await assert.rejects(runner.run('Read independent sources',event=>{events.push(event);if(event.kind===K.OBSERVATION)throw Error('observer closed');}),/observer closed/);
  assert.equal(slowContext.isCancelled(),true);assert.equal(runner.getEvidence().length,1);
  const count=events.length;releaseSlow('late result');await tick();await tick();
  assert.equal(events.length,count);assert.equal(runner.getEvidence().length,1);
 }finally{await registry.close();}
});

test('a tool completion past the absolute deadline cannot enter evidence before a delayed timer callback runs',async()=>{
 const originalNow=Date.now;let now=originalNow(),executions=0;const registry=new ToolRegistry(),events=[];
 registry.register(fixture('source',async()=>{executions++;now+=100;return 'late result';},{version:'1',inputFormat:'json'}),policy);
 const runner=new ReActAgentRunner({complete:async()=>action('source',{})},registry,6);
 try{
  Date.now=()=>now;
  await runner.run('Read a source',event=>events.push(event),undefined,{namespace:'clock',goals:[],evidence:[],deadlineAt:now+50});
 }finally{Date.now=originalNow;}
 assert.equal(executions,1);assert.equal(runner.getEvidence().length,0);assert.equal(events.filter(e=>e.kind===K.OBSERVATION).length,0);
 assert.match(events.at(-1).text,/总时限/);
});

test('a model fulfilled after the deadline cannot dispatch tools before the expired timer callback runs',async()=>{
 const originalNow=Date.now;let now=originalNow(),executed=0;const events=[];
 const registry=new ToolRegistry();registry.register(fixture('probe',async()=>{executed++;return 'ok';}),policy);
 const runner=new ReActAgentRunner({complete:async()=>{now+=100;return action('probe',{key:'A'});}},registry,10);
 try{
  Date.now=()=>now;
  await runner.run('read A',event=>events.push(event),undefined,{namespace:'clock',goals:[],evidence:[],deadlineAt:now+50});
 }finally{Date.now=originalNow;}
 assert.equal(executed,0);assert.match(events.at(-1).text,/总时限/);
});

(async()=>{let passed=0;for(const {name,body}of tests){try{await body();passed++;console.log('PASS '+name);}catch(error){console.error('FAIL '+name+'\n'+error.stack);process.exitCode=1;}}console.log(passed+'/'+tests.length+' actual-registry contract tests passed; controlled providers, no real external writes');})().catch(e=>{console.error(e);process.exitCode=1;});
