const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {transpile}=require('../../../../tests/ets-harness.cjs');
function load(file,requires={}){const box={exports:{},require:name=>requires[name]||{},JSON,Array,Math,Number,Date};vm.runInNewContext(transpile(path.resolve(__dirname,'../../entry/src/main/ets/'+file)),box);return box.exports;}
let saved,fail=false;
const preferences={getPreferencesSync(){return {getSync:()=>saved??'{}',putSync:(key,value)=>{saved=value;},async flush(){if(fail)throw new Error('disk');}};}};
const settings=load('model/TabletPreferences.ets',{'@kit.ArkData':{preferences}});
(async()=>{
 const displaySize=load('model/TabletDisplay.ets');
 assert.equal(displaySize.TABLET_WIDTH_MM,127);assert.equal(displaySize.TABLET_HEIGHT_MM,198);
 assert.ok(Math.abs(displaySize.physicalPixelsPerInch()-264.068544)<0.00001);
 let pixels=displaySize.tabletSizePx(3120,2080);assert.equal(pixels.width,1320);assert.equal(pixels.height,2058);
 pixels=displaySize.tabletSizePx(2080,3120);assert.equal(pixels.width,1320);assert.equal(pixels.height,2058);
 pixels=displaySize.tabletSizePx(1560,1040);assert.equal(pixels.width,660);assert.equal(pixels.height,1029);
 pixels=displaySize.fitDefaultWindow({width:1320,height:2058},3120,1980);assert.equal(pixels.width,1320);assert.equal(pixels.height,1980);
 assert.equal(displaySize.physicalPixelsPerInch(0,0,0),displaySize.physicalPixelsPerInch());
 const windowCalls=[],screen={width:3120,height:2080,availableWidth:3120,availableHeight:1980,densityPixels:2};
 const win={async setWindowLimits(limits){windowCalls.push(['limits',limits]);return limits;},async resize(w,h){windowCalls.push(['resize',w,h]);}};
 const {default:EntryAbility}=load('entryability/EntryAbility.ets',{
  '@kit.AbilityKit':{UIAbility:class{}},'@kit.BasicServicesKit':{deviceInfo:{deviceType:'2in1'}},
  '@kit.ArkUI':{display:{getDefaultDisplaySync:()=>screen},window:{}},'../model/TabletDisplay':displaySize
 });
 const ability=new EntryAbility();await ability.configureDefaultWindow({getMainWindowSync:()=>win});
 const limits=windowCalls[0][1];assert.ok(limits.minWidth<limits.maxWidth);assert.ok(limits.minHeight<limits.maxHeight);
 assert.deepEqual(windowCalls[1],['resize',1320,1980]);
 const pageSource=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/pages/Index.ets'),'utf8');
 assert.doesNotMatch(pageSource,/TABLET_WIDTH_VP|TABLET_HEIGHT_VP|TABLET_DISPLAY_RATIO/);
 assert.match(pageSource,/this.sessionSidebar\(\)/);assert.doesNotMatch(pageSource,/this.sessionStrip\(\)/);
 let value=settings.loadTabletPreferences({});assert.equal(value.quickInputs.length,3);assert.equal(value.sidebarCollapsed,false);
 await settings.saveTabletPreferences({},{quickInputs:['第一行\n第二行','自定义任务',''],sidebarCollapsed:true,sidebarWidth:240});
 value=settings.loadTabletPreferences({});assert.deepEqual(Array.from(value.quickInputs),['第一行\n第二行','自定义任务','']);assert.equal(value.sidebarCollapsed,true);assert.equal(value.sidebarWidth,240);
 value=settings.normalizeTabletPreferences({quickInputs:['x'.repeat(5000)],sidebarWidth:999});assert.equal(value.quickInputs[0].length,4000);assert.equal(value.sidebarWidth,300);
 saved='broken';assert.equal(settings.loadTabletPreferences({}).quickInputs.length,3);
 fail=true;await assert.rejects(settings.saveTabletPreferences({},value),/disk/);
 const {TaskRoutingStore}=load('ui/TaskRoutingStore.ets'),store=new TaskRoutingStore();
 const connectedHub={id:'hub',deviceUid:'hub',name:'算力设备1',role:'compute',ready:true};
 const noRoster=new TaskRoutingStore();
 let connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',true,7,connectedHub));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,1,'handshake-complete hub must show before any task or roster');
 noRoster.receive({type:'deviceInfoSync',devices:[connectedHub]},7);
 connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',true,7,connectedHub));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,1,'roster replaces the handshake fallback without duplicates');
 connectedEvent=JSON.parse(noRoster.snapshot([],'聊天设备1','chat',false,-1,null));
 assert.equal(connectedEvent.devices.filter(d=>d.role==='compute').length,0,'disconnect removes the connected node');
 const linkSource=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/nearby/LinkEnhanceChannel.ets'),'utf8').replace(/\r\n/g,'\n');
 const linkStart=linkSource.indexOf('  connectedComputeInfo('),linkEnd=linkSource.indexOf('\n  }',linkStart)+4;
 const routeTs=require(process.env.TYPESCRIPT_PATH||'typescript'),linkBox={exports:{},IS_SERVER:false};
 vm.runInNewContext(routeTs.transpileModule('class Links {'+linkSource.slice(linkStart,linkEnd)+'} exports.Links=Links;', {compilerOptions:{target:routeTs.ScriptTarget.ES2020}}).outputText,linkBox);
 const links=new linkBox.exports.Links();Object.assign(links,{peers:[],lastHits:[],idsMatch:(a,b)=>a===b});
 assert.equal(links.connectedComputeInfo(),null);
 links.peers=[{ready:true,deviceUid:'hub',peerId:'mac'}];links.lastHits=[{mac:'mac',slot:1}];
 assert.equal(links.connectedComputeInfo().deviceUid,'hub');assert.equal(links.connectedComputeInfo().name,'算力设备1');
 links.peers[0].ready=false;assert.equal(links.connectedComputeInfo(),null);

 store.receive({type:'deviceInfoSync',devices:[{deviceUid:'hub',name:'算力设备1',role:'compute',ready:true,memUsage:52,modelRequests:1,capabilities:['text','vision']},{deviceUid:'chat',name:'聊天设备1',role:'chat',ready:true}]},7);
 const calls=[{id:'one',question:'测试<任务>',image:'',device:'算力设备1',phase:'running',startedAt:1000},{id:'two',question:'排队',image:'',device:'',phase:'queued',startedAt:1001}];
 let event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,7));assert.equal(event.devices.length,2);assert.equal(event.jobs.length,1);assert.equal(event.queuedCalls.length,1);assert.equal(event.jobs[0].originId,'chat');assert.equal(event.devices[0].memUsage,52);
 event=JSON.parse(store.snapshot([], '聊天设备1','chat',false,-1));assert.equal(event.devices.length,1);assert.equal(event.jobs.length,0);
 store.receive({type:'deviceInfoSync',devices:[{id:'stale',role:'compute'}]},7);event=JSON.parse(store.snapshot([], '聊天设备1','chat',true,8));assert.equal(event.devices.length,1,'old epoch roster must not survive reconnect');
 event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,8));assert.equal(event.devices[1].name,'算力设备1','acceptance is actual device evidence');
 const notice={key:'other',revision:2,kind:'text',phase:'running',source:'算力设备2',origin:'聊天设备2',originId:'chat2',elapsed:3000};
 store.receiveFlow({text:JSON.stringify(notice)});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,1);
 store.receiveFlow({text:JSON.stringify({...notice,revision:3,phase:'cleared'})});
 store.receiveFlow({text:JSON.stringify({...notice,revision:2})});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0,'late route must not revive cleared request');
 store.receiveFlow({text:JSON.stringify({...notice,key:'own',revision:1,originId:'chat'})});event=JSON.parse(store.snapshot(calls,'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0,'owned requests must not duplicate mirrors');
 store.receiveFlow({text:JSON.stringify({...notice,key:'bad',revision:1,elapsed:-1})});event=JSON.parse(store.snapshot([],'聊天设备1','chat',true,8));assert.equal(event.flowCalls.length,0);

 // The chat asset uses the same node, wire and task renderer as the compute dashboard.
 const compute=fs.readFileSync(path.resolve(__dirname,'../../../compute-node/entry/src/main/resources/rawfile/peer-chat.html'),'utf8').replace(/\r\n/g,'\n');
 const html=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/resources/rawfile/task-routing.html'),'utf8');
 const start=compute.indexOf('    function flowClock('),end=compute.indexOf('    function flowTitle(',start);
 assert.ok(html.includes(compute.slice(start,end)),'compute clock, icons and safe image helpers must stay intact');
 const elements={};function el(){return {style:{},clientWidth:640,scrollHeight:500,scrollTop:0,innerHTML:'',handlers:{},addEventListener(k,v){this.handlers[k]=v;},querySelectorAll(){return[];}};}
 for(const id of ['viewport','stage','space','collaboration','detail','detailText','closeDetail'])elements[id]=el();
 const document={getElementById:id=>elements[id]||null,createElement:()=>({})};
 const window={addEventListener(){}};vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date,Map,Set,JSON,Math,Array,String,Number,setInterval(){}});
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true,memUsage:52},{id:'chat',name:'聊天设备1',role:'chat',ready:true}],jobs:[{id:'r',key:'client:r',source:'算力设备1',originId:'chat',origin:'聊天设备1',phase:'running',running:true,question:'测试<任务>',startedAt:Date.now()-5000}]});
 assert.match(elements.collaboration.innerHTML,/flow-compute/);assert.match(elements.collaboration.innerHTML,/测试&lt;任务&gt;/);assert.match(elements.collaboration.innerHTML,/路由中心/);assert.equal(elements.stage.style.transform,'scale(0.64)');
 window.onNativeEvent({devices:[{id:'hub',name:'算力设备1',role:'compute',ready:true},{id:'worker',name:'算力设备2',role:'compute',ready:true,jobs:0},{id:'chat',name:'聊天设备1',role:'chat',ready:true}],jobs:[]});
 assert.equal((elements.collaboration.innerHTML.match(/class="flow-compute"/g)||[]).length,2,'idle compute members must remain visible');
 const beforeRoster=JSON.parse(new TaskRoutingStore().snapshot([],'聊天设备1','chat',true,7,connectedHub));
 window.onNativeEvent(beforeRoster);assert.match(elements.collaboration.innerHTML,/flow-compute/);assert.doesNotMatch(elements.collaboration.innerHTML,/等待算力设备上线/);
 const sending=JSON.parse(new TaskRoutingStore().snapshot([{id:'upload',question:'任务',image:'',device:'',phase:'sending',startedAt:Date.now()}],'聊天设备1','chat',true,7,connectedHub));
 window.onNativeEvent(sending);assert.match(elements.collaboration.innerHTML,/flow-packet/,'upload animates toward the connected hub before acceptance');
 window.onNativeEvent({devices:[],jobs:[]});assert.doesNotMatch(elements.collaboration.innerHTML,/flow-task working/);
 // Execute the actual compute publisher: ready chat clients receive route notices too.
 const computePage=fs.readFileSync(path.resolve(__dirname,'../../../compute-node/entry/src/main/ets/pages/Index.ets'),'utf8').replace(/\r\n/g,'\n');
 const methodStart=computePage.indexOf('  private publishFlow('),methodEnd=computePage.indexOf('\n  }',methodStart)+4;
 const ts=require(process.env.TYPESCRIPT_PATH||'typescript'),publisher={exports:{},computeLabel:()=> '算力设备1',Date,Math,Map,Array};
 vm.runInNewContext(ts.transpileModule('class Publisher {'+computePage.slice(methodStart,methodEnd)+'} exports.Publisher=Publisher;', {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText,publisher);
 const p=new publisher.exports.Publisher(),sent=[];
 Object.assign(p,{isComputeHub:()=>true,flowNotices:new Map(),flowDeliveries:new Map(),flowRevision:0,channel:{peerInfos:()=>[{epoch:1,role:'chat',ready:true},{epoch:2,role:'compute',ready:true},{epoch:3,role:'chat',ready:false}],send:(message,epoch)=>{sent.push(epoch);return Promise.resolve(true);}}});
 p.publishFlow([{key:'r',startedAt:Date.now(),running:true,source:'算力设备1',origin:'聊天设备1'}]);
 assert.deepEqual(sent,[1],'executor skip must only apply to compute peers, not chat peers');
 console.log('PASS tablet preferences persistence, multiline custom text, bounds, failures, roster epochs, actual device evidence, shared route renderer and cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
