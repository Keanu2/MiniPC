// Exercise the real node-patching branch (the older DOM stubs only exercise innerHTML fallback).
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
let focusCalls=0;
class Node {
  constructor(name,attrs={},text=''){this.nodeName=name;this.nodeType=name==='#text'?3:1;this._attrs={...attrs};this._children=[];this.data=text;this.parentNode=null;this.scrollTop=0;}
  get attributes(){return Object.entries(this._attrs).map(([name,value])=>({name,value}));}
  get children(){return this._children.filter(node=>node.nodeType===1);}
  get childNodes(){return this._children;}
  get lastChild(){return this._children.at(-1);}
  get isConnected(){return !!this.parentNode;}
  get innerHTML(){return this._children.map(node=>node.nodeName+node.data+node.innerHTML).join('');}
  getAttribute(name){return this._attrs[name]||null;}
  setAttribute(name,value){this._attrs[name]=value;}
  removeAttribute(name){delete this._attrs[name];}
  hasAttribute(name){return name in this._attrs;}
  appendChild(node){this.insertBefore(node,null);}
  insertBefore(node,before){node.remove();const at=before?this._children.indexOf(before):this._children.length;this._children.splice(at,0,node);node.parentNode=this;}
  remove(){if(this.parentNode){const parent=this.parentNode;parent._children.splice(parent._children.indexOf(this),1);this.parentNode=null;}}
  replaceWith(next){const parent=this.parentNode;parent.insertBefore(next,this);this.remove();}
  getBoundingClientRect(){if(!this.parentNode)return {top:0,bottom:100};const top=this.parentNode.children.indexOf(this)*100-this.parentNode.scrollTop;return {top,bottom:top+100};}
  focus(){focusCalls++;}
}
const text=value=>new Node('#text',{},value);
function row(id,elapsed){const node=new Node('ARTICLE',{'data-row-key':id});const button=new Node('BUTTON',{'data-detail':id});button.appendChild(text('查看推理'));node.appendChild(button);const metric=new Node('SPAN');metric.appendChild(text(elapsed));node.appendChild(metric);return node;}
const document={createElement(name){assert.equal(name,'template');const result={content:{children:[]}};Object.defineProperty(result,'innerHTML',{set(value){const [tick,extra]=value.split(':');result.content.children=[...(extra?[row('new','0')]:[]),row('one',tick),row('two',tick),row('three',tick)];}});return result;}};
const context={document,Map,Set,Array,Math};vm.createContext(context);
vm.runInContext(script.slice(script.indexOf('function morphNode'),script.indexOf('function groupRunning')),context);
const view=new Node('SECTION');
context.renderMarkup(view,'0');view.scrollTop=130;
const readingRow=view.children[1],focusedButton=readingRow.children[0];
for(let tick=1;tick<=200;tick++)context.renderMarkup(view,String(tick));
assert.equal(view.scrollTop,130,'200 timer/stream updates preserve the reading position');
assert.equal(view.children[1],readingRow,'do not replace the row touched by the user');
assert.equal(view.children[1].children[0],focusedButton,'do not replace its focused button');
assert.equal(focusCalls,0,'refreshing never focuses and scrolls a request button');
assert.equal(readingRow.children[1].childNodes[0].data,'200','elapsed text still updates');
context.renderMarkup(view,'201:new');assert.equal(view.children[2],readingRow);assert.equal(view.scrollTop,230,'newer rows keep the same content anchored in view');
assert.equal(readingRow.getBoundingClientRect().top,-30);
console.log('PASS: real DOM patch branch preserves row/button identity and scrolling over 200 updates and newly inserted requests');
