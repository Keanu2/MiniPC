// Minimal DOM for the actual dashboard script; native bridge calls are inert.
const fs=require('node:fs'),vm=require('node:vm');
module.exports=function dashboardHarness(){
 const source=fs.readFileSync(__dirname+'/../../resources/rawfile/peer-chat.html','utf8'),elements={};
 const document={activeElement:null,handlers:{},getElementById:id=>elements[id],addEventListener(type,fn){this.handlers[type]=fn},createElement:()=>element()};
 function element(){return{handlers:{},style:{},attrs:{},hidden:true,value:'',textContent:'',scrollTop:0,scrollHeight:100,clientHeight:50,isConnected:true,classList:{add(){},remove(){}},_html:'',get innerHTML(){return this._html},set innerHTML(value){this._html=value;for(const match of value.matchAll(/\bid="([^"]+)"/g))if(!elements[match[1]])elements[match[1]]=element()},addEventListener(type,fn){this.handlers[type]=fn},getAttribute(name){return this.attrs[name]||null},setAttribute(name,value){this.attrs[name]=value},appendChild(){},blur(){},focus(){document.activeElement=this},querySelector(){return element()},querySelectorAll(){return[]}};}
 for(const match of source.matchAll(/\bid="([^"]+)"/g))elements[match[1]]=element();
 const window={chatBridge:{connect(){},pickImage(){},clear(){},prepare(){},send(){return''},stop(){}}};
 const timers=[];
 vm.runInNewContext(source.match(/<script>([\s\S]*?)<\/script>/)[1],{document,window,Date,setInterval:fn=>timers.push(fn)});
 function target(attrs){const el=element();el.attrs=attrs;el.closest=selector=>Object.keys(attrs).some(attr=>selector==='['+attr+']')?el:null;return el;}
 return{source,elements,document,window,target,timers};
};
