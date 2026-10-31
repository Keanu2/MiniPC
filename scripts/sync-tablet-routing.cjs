// Regenerate the chat-side route view from the compute-side renderer. Compute UI is unchanged.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'apps/compute-node/entry/src/main/resources/rawfile/peer-chat.html'), 'utf8').replace(/\r\n/g, '\n');
function part(start, end) {
 const a=source.indexOf(start), b=source.indexOf(end,a+start.length);
 if(a<0||b<0)throw new Error('Compute route renderer marker missing: '+start);
 return source.slice(a,b);
}
const css = part('    .flow-view{', '</style>');
const symbols = [...source.matchAll(/<symbol id="flow-[\s\S]*?<\/symbol>/g)].map(m=>m[0]).join('\n');
const helpers = part('    function summaryText(', '    function focusWithoutScroll(')+
 part('    function morphNode(', '    function phaseView(')+
 part('    function esc(', '    function sideClass(')+
 part('    function publicJobName(', '    function updateButton(')+
 part('    function jobKey(', '    // The rail is rebuilt');
const renderer = part('    const flowView=', '    function setTaskView(');
const setup = `let jobs=[],remoteCalls=[],devices=[],groups=[],selfLabel='算力设备1';
function allCalls(){return jobs.concat(remoteCalls);}
`;
const adapter = `
const viewport=document.getElementById('viewport'),stage=document.getElementById('stage'),space=document.getElementById('space');
function fitFlow(){const scale=Math.min(1,viewport.clientWidth/1000);stage.style.transform='scale('+scale+')';space.style.height=Math.ceil(stage.scrollHeight*scale)+'px';}
window.onNativeEvent=function(event){devices=event.devices||[];jobs=event.jobs||[];groups=[];queuedCalls=event.queuedCalls||[];mirroredCalls=event.flowCalls||[];renderFlow();fitFlow();};
window.addEventListener('resize',()=>{flowSignature='';renderFlow();fitFlow();});
flowView.addEventListener('click',event=>{const button=event.target.closest('[data-flow-detail]');if(!button)return;
 const job=jobs.find(j=>jobKey(j)===button.getAttribute('data-flow-detail'));if(!job)return;
 document.getElementById('detailText').textContent=(job.question||'推理请求')+'\\n执行设备：'+(job.source||'等待分派')+'\\n状态：'+(job.phase||'running');
 document.getElementById('detail').hidden=false;
});
document.getElementById('closeDetail').addEventListener('click',()=>document.getElementById('detail').hidden=true);
setInterval(()=>{renderFlow();fitFlow();},500);renderFlow();fitFlow();
`;
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>任务路由</title><style>
:root{--ink:#16332C;--muted:#6B7F79;--ok:#1a9b6a;--busy:#3d5bdb}*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden}body{font-family:system-ui,'HarmonyOS Sans SC',sans-serif;color:var(--ink);background:white}
${css}
#viewport{position:relative;width:100%;height:100%;overflow:auto;overscroll-behavior:contain;touch-action:pan-y}#stage{position:absolute;left:0;top:0;width:1000px;transform-origin:top left}.flow-view{width:1000px;padding:8px 20px 16px;min-height:0;overflow:visible}.flow-labels{min-width:960px}.flow-empty{left:370px}#detail{position:fixed;inset:12px;padding:16px;background:#f7fbfa;border:1px solid #d8e5df;border-radius:14px;overflow:auto}#detail[hidden]{display:none}#detailText{white-space:pre-wrap;overflow-wrap:anywhere}#closeDetail{float:right;border:0;border-radius:8px;padding:8px;background:#d8f3ea;color:#0f8a74}
</style></head><body><svg style="position:absolute;width:0;height:0" aria-hidden="true"><defs>${symbols}</defs></svg>
<div id="viewport"><div id="space"></div><div id="stage"><section id="collaboration" class="flow-view" aria-label="设备协同运行图"></section></div></div>
<div id="detail" hidden><button id="closeDetail">关闭</button><p id="detailText"></p></div>
<script>${setup}${helpers}${renderer}${adapter}</script></body></html>`;
fs.writeFileSync(path.join(root,'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html'),html);
console.log('Generated task-routing.html from compute route renderer');
