const assert=require('node:assert/strict'),vm=require('node:vm');
const {transpile}=require('../../../../../../../tests/ets-harness.cjs');
const files=new Map();let failRename=false;
const fileIo={OpenMode:{CREATE:1,READ_WRITE:2,TRUNC:4},
 readTextSync(path){if(!files.has(path))throw Error('missing');return files.get(path);},
 openSync(path){files.set(path,'');return {fd:path};},writeSync(fd,text){files.set(fd,text);},closeSync(){},
 renameSync(from,to){if(failRename)throw Error('disk error');files.set(to,files.get(from));files.delete(from);}};
function load(){const box={exports:{},require:()=>({fileIo})};vm.runInNewContext(transpile(__dirname+'/OutputSettings.ets'),box);return box.exports;}
const store=load(),path='/files/inference-output.json';
assert.equal(store.outputSettings('/files').streaming,true);
for(const invalid of ['broken','null','{}','{"streaming":"false"}']){
 files.set(path,invalid);assert.equal(store.outputSettings('/files').streaming,true);
}
files.set('/files/model-selection.json','{"model":"Qwen3.5"}');
assert.equal(store.saveOutputSettings('/files',{streaming:false}),'');
assert.equal(load().outputSettings('/files').streaming,false,'preference survives a module restart');
assert.equal(files.get('/files/model-selection.json'),'{"model":"Qwen3.5"}','model selection is independent');
failRename=true;assert.ok(store.saveOutputSettings('/files',{streaming:true}));
assert.equal(store.outputSettings('/files').streaming,false,'failed atomic save preserves the active preference');
failRename=false;assert.equal(store.saveOutputSettings('/files',{streaming:true}),'');
assert.ok(store.saveOutputSettings('/files',{streaming:'false'}));
assert.equal(store.outputSettings('/files').streaming,true);
console.log('PASS: persistent output mode, defaults, malformed values and failed atomic save');
