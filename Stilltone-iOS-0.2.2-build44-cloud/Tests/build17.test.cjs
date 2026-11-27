// Run from any directory with Node 18+.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {boot,lutEntries} = require('./camera-ui-dom.cjs');
const read = file => fs.readFileSync(path.join(__dirname,'..',file),'utf8');
{
    const page = boot(read('FL-Camera-Review.html'));
    const camera = {ready:true,busy:false,formats:['HEIF'],sizes:[12],zoom:1};
    page.report({...camera,lenses:[0.5,1,2,5],opticalZoomStops:[0.5,1,5],zoomRange:[0.5,30],inputRevision:1});
    page.run('reviewZoom(25)');
    assert.equal(page.messages.filter(m=>m.type==='zoom').at(-1).value,15);
    const stops=page.run('tools').querySelectorAll('[data-step]');
    assert.ok(stops.find(b=>Number(b.dataset.step)===2).getAttribute('aria-label').includes('数码'));
    assert.ok(stops.find(b=>Number(b.dataset.step)===5).getAttribute('aria-label').includes('镜头'));
    page.report({...camera,lenses:[1,2],opticalZoomStops:[1],zoomRange:[1,2],inputRevision:2});
    page.run('reviewZoom(5)');
    assert.equal(page.messages.filter(m=>m.type==='zoom').at(-1).value,2);
    console.log('PASS handset-specific zoom range and digital/optical shortcut labels');
}
const t = boot(read('FL-Camera-Review.html'));
const state = {ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],lenses:[1,2],zoom:1,flash:true,live:true,savedID:''};
t.report(state);
const pick = label => t.run('selector').querySelectorAll('button').find(b=>b.textContent===label).click();
function choose(panel,label) {t.open(panel);pick(label);t.close()}
choose('计时器','3 秒');
t.run('setMode(0)');t.shutter();assert.equal(t.run('countdown'),null);
t.run('setMode(1)');t.shutter();assert.ok(t.run('countdown'));t.run('setMode(2);setMode(1)');t.tick(1000,4);
assert.equal(t.messages.filter(m=>m.type==='capture').length,0);
console.log('PASS: no delayed request across unsupported modes');
t.report({...state,zoomSettling:true});
t.run('requestAnimationFrame=callback=>{window.nextFrame=callback;return 1}');
assert.equal(t.capture(),undefined);t.run('reviewZoom(1.5)');
assert.equal(t.messages.filter(m=>m.type==='zoom').at(-1).value,1.5);
t.run('reviewZoom(1.6);reviewZoom(1.8)');
assert.deepEqual(t.messages.filter(m=>m.type==='zoom').map(m=>m.value),[1.5]);
t.host.nextFrame();
assert.deepEqual(t.messages.filter(m=>m.type==='zoom').map(m=>m.value),[1.5,1.8]);
t.report({...state,inputRevision:4});
t.run('reviewZoom(2);reviewZoom(1.6)');
assert.equal(t.messages.filter(m=>m.type==='zoom').at(-1).inputRevision,4);
t.doc.getElementById('flip').click();
assert.equal(t.messages.filter(m=>m.type==='flip').at(-1).inputRevision,4);
const beforeFront=t.messages.filter(m=>m.type==='zoom').length;
t.report({...state,inputRevision:5,lenses:[1]});t.host.nextFrame();
assert.equal(t.messages.filter(m=>m.type==='zoom').length,beforeFront);
t.report({...state,inputRevision:6,zoom:3,lenses:[.5,1,2,3]});
t.report({...state,inputRevision:5,zoom:1,lenses:[1]});
assert.equal(t.run('window.nativeCameraState.zoom'),3);
t.run('glideZoom(2)');assert.equal(t.messages.filter(m=>m.type==='zoom').at(-1).inputRevision,6);
console.log('PASS a front camera flip cancels the rear pending pinch and tags input commands');
t.report(state);assert.ok(t.capture());console.log('PASS: ramp blocks shutter and allows continued zoom');
t.open('滤镜');t.brand('sony');t.run('selector').querySelector('.rail-track').children[1].click();
const slider=t.run('selector').querySelector('input');slider.value=57;slider.dispatch('input');t.close();
choose('宽高比','1:1');t.open('曝光');const light=t.run('selector').querySelector('input');light.value='1';light.dispatch('input');t.close();
choose('格式','RAW');let shot=t.capture();assert.equal(shot.look,'FL2');assert.equal(shot.strength,.57);assert.equal(shot.aspect,'4:3');assert.equal(shot.mp,12);
assert.ok(t.run('!filterShortcut.disabled && aspectControl.disabled'));
t.open('滤镜');t.brand('sony');t.run('selector').querySelector('.rail-track').children[2].click();t.close();
assert.equal(t.capture().look,'FL3');choose('格式','HEIF');shot=t.capture();assert.equal(shot.look,'FL3');assert.equal(shot.aspect,'1:1');
console.log('PASS: RAW 12 MP retains filter, accepts another look and restores crop on HEIF');
choose('夜间模式','开启');assert.equal(t.messages.filter(m=>m.type==='night').at(-1).mode,'开启');
t.run('topFlash').click();assert.equal(t.messages.filter(m=>m.type==='night').at(-1).mode,'关闭');
t.report({...state,savedID:'asset1'});assert.equal(t.doc.getElementById('state').textContent,'已保存到系统照片');
console.log('PASS: night changes before shutter and confirmed save updates status');
const html=read('Stilltone-Album.html');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const assets=lutEntries(html);
const Element=t.doc.constructor;
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const records=new Map();
let failDraft=false,failExport=false,writes=0;
function page(){
    const doc=new Element('document');doc.body=new Element('body');doc.body.setAttribute('data-album','');
    doc.head=new Element('head');doc.append(doc.head,doc.body);
    doc.head.appendChild=n=>{doc.head.append(n);return n};
    const payloads=new Map(assets.map(([id,textContent])=>[id,{textContent}]));
    doc.getElementById=id=>payloads.get(id);
    let picker;
    doc.createElement=tag=>{
        const el=new Element(tag);
        if(tag==='input'&&!picker)picker=el;
        if(tag==='select')el.add=n=>el.append(n);
        if(tag==='canvas'){
            el.getContext=()=>({scale(){},translate(){},rotate(){},drawImage(){},clearRect(){},setTransform(){},
                getImageData:()=>({width:1,height:1,data:new Uint8ClampedArray(4)}),putImageData(){}});
            el.toDataURL=()=>'thumbnail';el.toBlob=cb=>cb({});
        }return el;
    };
    const db={transaction(){
        const tx={objectStore:()=>({
            put(record){setImmediate(()=>{if(failDraft){tx.error=Error('quota');tx.onabort()}else{records.set(record.id,structuredClone(record));tx.oncomplete()}})},
            getAll(){const req={};setImmediate(()=>{req.result=[...records.values()];req.onsuccess()});return req}
        })};return tx
    }};
    const host={document:doc,crypto:{randomUUID:()=>'stable-photo'},indexedDB:{open(){const req={};setImmediate(()=>{req.result=db;req.onsuccess()});return req}},
        URL:{createObjectURL:()=>'blob:fixture'},Option:class extends Element{constructor(n,v){super('option');this.textContent=n;this.value=v}},
        Image:class extends Element{constructor(){super('img');this.naturalWidth=4;this.naturalHeight=4}async decode(){}},
        ResizeObserver:class {observe(){} disconnect(){}},requestAnimationFrame:()=>1,cancelAnimationFrame(){},setTimeout:cb=>setImmediate(cb),clearTimeout:clearImmediate,
        FileReader:class{readAsDataURL(){this.result='data:image/jpeg;base64,fixture';this.onload()}},
        webkit:{messageHandlers:{editorState:{postMessage(){}},savePhoto:{async postMessage(){writes++;if(failExport)throw Error('denied')}}}}};
    host.window=host;vm.runInNewContext(script,host);
    return {doc,picker,button:name=>doc.querySelectorAll('button').find(b=>b.textContent===name)};
}
async function check(){
    const p=page();await tick();await tick();
    p.picker.files=[{name:'sample.jpg',size:4,lastModified:1}];await p.picker.onchange();await tick();
    const slider=p.doc.querySelector('.params input');slider.value='1';slider.oninput();slider.onchange();
    failDraft=true;await p.button('保存草稿').onclick();assert.equal(records.size,0);assert.ok(p.button('保存草稿'));assert.match(p.doc.querySelector('.workspace').textContent,/草稿未保存/);
    failExport=true;const exportPhoto=p.button('导出 HEIF');await Promise.all([exportPhoto.onclick(),exportPhoto.onclick()]);assert.equal(writes,1);assert.match(p.doc.querySelector('.workspace').textContent,/导出失败/);
    failExport=false;await exportPhoto.onclick();assert.equal(writes,2);assert.match(p.doc.querySelector('.workspace').textContent,/已存入系统照片/);
    failDraft=false;await p.button('保存草稿').onclick();assert.equal(records.size,1);assert.equal(records.get('stable-photo').settings.ev,1);
    const fresh=page();await tick();await tick();await tick();
    assert.equal(fresh.doc.querySelectorAll('.strip img').length,1);await fresh.doc.querySelector('.strip button').onclick();await tick();
    assert.equal(fresh.doc.querySelector('.params input').value,'1');
    console.log('PASS: failed draft keeps edits; saved draft restores recipe in a new page');
    console.log('PASS: duplicate export coalesces; failed PhotoKit reply is visible and retry succeeds');
}
check().catch(e=>{console.error(e);process.exitCode=1});
