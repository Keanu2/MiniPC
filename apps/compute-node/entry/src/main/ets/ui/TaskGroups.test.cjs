const assert=require('node:assert/strict'),dashboard=require('./DashboardHarness.cjs');
const h=dashboard(),now=Date.now();
const group={id:'parent',key:'5:parent',title:'原问题 <script>不能执行</script>',origin:'聊天设备2',executor:'算力设备1',phase:'running',startedAt:now-4000,endedAt:0,answer:'',subtasks:[
 {id:'s1',title:'A',input:'完整子任务A',device:'算力设备1',phase:'running',detail:'调用工具'},
 {id:'s2',title:'B',input:'完整子任务B',device:'算力设备2',phase:'done',result:'B最终结果'}]};
const request=(id,child,extra={})=>({id,key:'5:'+id,groupKey:group.key,subtaskId:child,question:'内部提示词',input:'原始模型输入 '+id,answer:'Action: 模型调用 '+id,
 source:'算力设备1',origin:'聊天设备2',startedAt:now-2000,firstAt:now-1000,endedAt:now,running:false,elapsedMs:2000,...extra});
const event={kind:'dashboard',selfLabel:'算力设备1',groups:[group],jobs:[request('call1','s1'),request('call2','s1')]};h.window.onNativeEvent(event);
assert.equal((h.elements.history.innerHTML.match(/data-result="s1"/g)||[]).length,1);assert.match(h.elements.history.innerHTML,/完整子任务A/);
assert.match(h.elements.history.innerHTML,/B最终结果/);assert.doesNotMatch(h.elements.history.innerHTML,/Action:|内部提示词|轮推理/);
assert.match(h.elements.history.innerHTML,/&lt;script&gt;不能执行&lt;\/script&gt;/);
h.elements.history.handlers.click({target:h.target({'data-collapse':group.key})});assert.doesNotMatch(h.elements.history.innerHTML,/完整子任务B/);
h.elements.history.handlers.click({target:h.target({'data-collapse':group.key})});
h.elements.history.handlers.click({target:h.target({'data-result':'s1','data-group':group.key})});assert.match(h.elements.detailContent.textContent,/最终结果尚未返回/);
group.subtasks[0].phase='done';group.subtasks[0].result='A经过工具后的最终结果';h.window.onNativeEvent(event);assert.equal(h.elements.detailContent.textContent,group.subtasks[0].result);
assert.match(h.elements.history.innerHTML,/执行中/,'parent remains active while children finish');
h.document.handlers.keydown({key:'Escape'});group.phase='done';group.endedAt=now;group.answer='最终汇总回答';h.window.onNativeEvent(event);
h.elements.history.handlers.click({target:h.target({'data-summary':group.key})});assert.equal(h.elements.detailContent.textContent,group.answer);
h.window.onNativeEvent({...event,groups:[],jobs:[]});assert.equal(h.elements.detail.hidden,true);
const calls=[request('a','s1'),request('b','s1'),request('c','s2'),request('d','s1',{groupKey:'6:parent'}),
 request('plain1','main',{groupKey:undefined,question:'相同问题'}),request('plain2','main',{groupKey:undefined,question:'相同问题'})];
h.window.onNativeEvent({...event,groups:[],jobs:calls});assert.equal(h.elements.taskCount.textContent,'共 5 个任务');
const before=[...h.elements.history.innerHTML.matchAll(/data-row-key="([^"]+)"/g)].map(x=>x[1]);
calls.push(request('later','s1',{startedAt:now,running:true,endedAt:0}));h.window.onNativeEvent({...event,groups:[],jobs:calls});
assert.deepEqual([...h.elements.history.innerHTML.matchAll(/data-row-key="([^"]+)"/g)].map(x=>x[1]),before);
console.log('PASS: end-to-end child rows, authoritative final output, parent lifecycle, escaping, collapse, exact identity and stable list order');
