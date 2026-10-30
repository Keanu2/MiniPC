const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(__dirname + '/../../resources/rawfile/peer-chat.html', 'utf8');
const elements = {};
function element() {
  return { handlers: {}, style: {}, hidden: true, value: '', textContent: '', innerHTML: '',
    classList: { add() {}, remove() {} }, addEventListener(type, fn) { this.handlers[type] = fn; },
    setAttribute() {}, querySelectorAll() { return []; }, querySelector() { return element(); } };
}
for (const match of html.matchAll(/\bid="([^"]+)"/g)) elements[match[1]] = element();
const document = { getElementById: id => elements[id], addEventListener() {}, createElement: element };
const selections = [];
const outputModes=[];
const usageSaves=[];
const routerAlgorithms=[];
let error = '', currentState = null, tick;
let usageState={tasks:'3',tokens:'20',yuan:'1.5',priceMode:'flash',inputYuan:'1',outputYuan:'4'};
const window = { chatBridge: { selectModel(name) { selections.push(name); return error; },
  setOutputMode(mode){outputModes.push(mode);return error;},
  models() { return JSON.stringify(currentState); },
  usageSettings() { return JSON.stringify(usageState); },
  saveUsageSettings(payload) {
    const patch=JSON.parse(payload);
    usageSaves.push(patch);
    if (error) return error;
    if (patch.reset) usageState=Object.assign({}, usageState, {tasks:'0', tokens:'0', yuan:'0'});
    else usageState=Object.assign({}, usageState, patch);
    return '';
  },
  setRouterAlgorithm(name){routerAlgorithms.push(name);return error;} } };
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], {
  document, window, Date, setInterval(fn) { tick = fn; }
});
const options = [{name:'Qwen2.5-7B-Instruct-Q4',vision:false}, {name:'Qwen-2.5-vl-3B-instruct-Q4',vision:true}];
const state = {selected: options[0].name, options, locked:false};
const dashboard = modelSettings => window.onNativeEvent({kind:'dashboard',devices:[],jobs:[],groups:[],modelSettings});
dashboard(state);
assert.equal(elements.settings.hidden, true, 'model selection stays off the home page');
elements.openSettings.handlers.click();
assert.equal(elements.settings.hidden, false);
assert.equal(elements.selectedModel.value, options[0].name);
assert(elements.modelHint.textContent.includes('只处理文字'));
assert(elements.selectedModel.innerHTML.includes('仅带图片'));
elements.selectedModel.value = options[1].name;
elements.selectedModel.handlers.change();
assert(elements.modelHint.textContent.includes('只处理带图片'));
dashboard(state);
assert.equal(elements.selectedModel.value, options[1].name, 'telemetry polls preserve the unsaved choice');
dashboard({...state,locked:true});
assert.equal(elements.selectedModel.disabled, true);
assert.equal(elements.applyModels.disabled, true);
currentState = state;
tick();
assert.equal(elements.selectedModel.disabled, false, 'native cleanup unlocks the open selector even with near-field disabled');
assert.equal(elements.applyModels.disabled, false, 'the draft survives inference ending');
error = '保存失败';
elements.applyModels.handlers.click();
assert.equal(elements.modelMessage.textContent, error);
assert.equal(elements.applyModels.disabled, false, 'failed persistence can be retried');
error = '';
elements.applyModels.handlers.click();
assert.equal(selections.at(-1), options[1].name);
assert.equal(elements.applyModels.disabled, true);
dashboard({...state,selected:options[1].name});
assert(elements.modelHint.textContent.includes('只处理带图片'));
elements.selectedModel.value = '';
elements.selectedModel.handlers.change();
assert(elements.modelHint.textContent.includes('自动模式'));
elements.applyModels.handlers.click();
assert.equal(selections.at(-1), '', 'automatic routing can be restored');
dashboard({selected:'Missing',options,locked:false});
assert(elements.selectedModel.innerHTML.includes('不可用'));
assert(elements.modelHint.textContent.includes('不可用'));
assert(html.includes('aria-label="设置"'), 'the home page opens model selection from settings');
assert(!html.includes('<summary>模型选择'), 'the home page no longer expands model selection inline');
elements.closeSettings.handlers.click();
assert.equal(elements.settings.hidden, true);
window.onNativeEvent({kind:'dashboard',devices:[{id:'self',role:'self',name:'算力设备',ready:true,
  model:'Qwen2.5-7B-Instruct / Qwen-2.5-vl-3B-instruct',capabilities:['text','vision'],modelTier:2,jobs:0}],jobs:[],groups:[]});
assert(elements.devices.innerHTML.includes('Qwen2.5-7B · 文本模型'));
assert(elements.devices.innerHTML.includes('Qwen-2.5-vl-3B · 多模态模型'));
assert(!elements.devices.innerHTML.includes(' · 多模态 ·') && !elements.devices.innerHTML.includes(' · 多模态<'));
console.log('PASS: single-model selector, input-type hints, draft preservation, busy lock, persistence errors and automatic mode');

dashboard({...state,streaming:true});elements.openSettings.handlers.click();
assert.equal(elements.outputMode.value,'stream');
elements.outputMode.value='complete';elements.outputMode.handlers.change();
assert.equal(elements.applyOutputMode.disabled,false);
dashboard({...state,streaming:true,locked:true});
assert.equal(elements.outputMode.value,'complete','telemetry preserves the unsaved output preference');
assert.equal(elements.applyOutputMode.disabled,false,'future requests can change output mode during inference');
error='保存失败';elements.applyOutputMode.handlers.click();
assert.equal(elements.outputModeMessage.textContent,error);assert.equal(elements.applyOutputMode.disabled,false);
error='';elements.applyOutputMode.handlers.click();assert.equal(outputModes.at(-1),'complete');
assert.equal(elements.applyOutputMode.disabled,true);
elements.outputMode.value='stream';elements.outputMode.handlers.change();
assert.equal(elements.applyOutputMode.disabled,false,'saved mode updates immediately before the next telemetry poll');
elements.applyOutputMode.handlers.click();assert.equal(outputModes.at(-1),'stream');
currentState={...state,streaming:false};dashboard(currentState);elements.closeSettings.handlers.click();elements.openSettings.handlers.click();
assert.equal(elements.outputMode.value,'complete','reopening settings reflects the persisted mode');
assert.equal(elements.usageTasks.value,'3');
assert.equal(elements.usageInputPrice.disabled,true,'flash pricing leaves the custom rates unused');
elements.usageTasks.value='9';
elements.usageTasks.handlers.input();
assert.equal(elements.saveUsage.disabled,false);
dashboard(state);
assert.equal(elements.usageTasks.value,'9','telemetry keeps unsaved totals');
elements.usagePriceMode.value='custom';
elements.usagePriceMode.handlers.change();
assert.equal(elements.usageInputPrice.disabled,false);
elements.usageInputPrice.value='2';
elements.usageOutputPrice.value='8';
elements.usageYuan.value='1.5';
elements.usageTokens.value='20';
elements.saveUsage.handlers.click();
assert.equal(usageSaves.at(-1).tasks,'9');
assert.equal(usageSaves.at(-1).priceMode,'custom');
assert.equal(elements.saveUsage.disabled,true);
assert.equal(elements.usageMessage.textContent,'已保存，标题旁的数字已更新。');
elements.resetUsage.handlers.click();
assert.equal(usageSaves.at(-1).reset,true);
assert.equal(elements.usageTasks.value,'0');
assert.equal(elements.usagePriceMode.value,'custom','reset keeps the chosen price');
assert.equal(elements.usageMessage.textContent,'已清零累计显示，计价方式保持不变。');
error='保存失败';
elements.usageTasks.handlers.input();
elements.saveUsage.handlers.click();
assert.equal(elements.usageMessage.textContent,'保存失败');
assert.equal(elements.saveUsage.disabled,false);
console.log('PASS: output selector, active-request independence, draft preservation and failed-save retry');

// 面板机制用虚构的两选项驱动（单选项注册表产生不出草稿，但这套 JS 契约与
// 算法数量无关）；末尾再用真实的单选项形状验证 registry 下发。
const fabricatedOptions=[{name:'least_load',label:'最小负载'},{name:'future',label:'未来算法'}];
dashboard({...currentState,routeAlgorithm:'least_load',routeOptions:fabricatedOptions});
assert.equal(elements.routeAlgorithm.value,'least_load','panel defaults to the hub route mode');
assert(elements.routeAlgorithm.innerHTML.includes('未来算法'),'options render from the registry choices');
assert(elements.applyRouteAlgorithm.disabled===true,'no unsaved draft keeps apply disabled');
elements.routeAlgorithm.value='future';elements.routeAlgorithm.handlers.change();
assert.equal(elements.applyRouteAlgorithm.disabled,false);
assert(elements.routeMessage.textContent.includes('保存路由算法'),'change announces the pending save');
dashboard({...currentState,routeAlgorithm:'least_load',routeOptions:fabricatedOptions});
assert.equal(elements.routeAlgorithm.value,'future','telemetry preserves the unsaved route draft');
error='保存失败';elements.applyRouteAlgorithm.handlers.click();
assert.equal(elements.routeMessage.textContent,error);
assert.equal(elements.applyRouteAlgorithm.disabled,false,'failed persistence can be retried');
error='';elements.applyRouteAlgorithm.handlers.click();
assert.equal(routerAlgorithms.at(-1),'future');
assert.equal(elements.applyRouteAlgorithm.disabled,true);
currentState={...currentState,routeAlgorithm:'future'};dashboard(currentState);elements.closeSettings.handlers.click();elements.openSettings.handlers.click();
assert.equal(elements.routeAlgorithm.value,'future','reopening settings reflects the persisted algorithm');
// 单算法注册表的真实形状：唯一选项即当前值，无草稿可产生。
dashboard({...currentState,routeAlgorithm:'least_load',routeOptions:[{name:'least_load',label:'最小负载（空闲优先，档位决胜）'}]});
assert.equal(elements.routeAlgorithm.value,'least_load','single-option registry keeps the current algorithm');
assert(elements.routeAlgorithm.innerHTML.includes('最小负载（空闲优先，档位决胜）'),'registry label renders');
assert(elements.applyRouteAlgorithm.disabled===true,'no other option means no draft');
console.log('PASS: router algorithm selector, registry options, draft preservation and failed-save retry');
