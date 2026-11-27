// From the package root: bun Tests/camera-ui.test.cjs [path/to/FL-Camera-Review.html]
// Also runs with Node >=18. No package install, browser profile, server or network.
const fs=require('node:fs'), path=require('node:path'), assert=require('node:assert/strict');
const {boot}=require('./camera-ui-dom.cjs');
const file=path.resolve(process.argv[2]??path.join(__dirname,'..','FL-Camera-Review.html'));
const html=fs.readFileSync(file,'utf8');
// These are synthetic bridge reports, not a matrix of supported iPhone models.
const state=(patch={})=>({ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],lenses:[.5,1,2],zoom:1,live:true,flash:true,...patch});
function ready(patch={}){const t=boot(html);t.report(state(patch));return t}
const cases=[];const test=(name,check)=>cases.push([name,check]);
function eq(actual,expected,label){assert.deepEqual(actual,expected,label)}
function controls(t,names,on){for(const name of names){const b=t.run(name);eq(b.getAttribute('aria-pressed'),String(on),name+' aria-pressed')}}
const live=(t,on)=>controls(t,['motionButton','liveShortcut'],on);
const flash=(t,on)=>controls(t,['flashTile','topFlash'],on);
function startLive(t){t.close();t.run('liveShortcut').click();live(t,true)}
function badge(t,codec,mp){const b=t.run('formatTile.firstElementChild'),shortcut=t.run('formatShortcut');eq(shortcut.textContent,codec+' '+mp,'format shortcut');eq(shortcut.getAttribute('aria-label'),'拍摄格式 '+codec+' '+mp+' MP','accessible format');eq(b.textContent,codec,'drawer codec');eq(String(b.dataset.mp),String(mp),'drawer MP')}
const labels=buttons=>buttons.map(b=>b.textContent);
const selected=buttons=>buttons.filter(b=>b.getAttribute('aria-pressed')==='true').map(b=>b.textContent);
function pick(t,group,name){const b=t.row(group).find(b=>b.textContent===name);assert.ok(b,group+': '+name+' not listed');b.click();return b}
function pickChoice(t,name){const b=t.run('selector').querySelectorAll('div button').find(b=>b.textContent===name);assert.ok(b,'picker choice '+name);b.click()}
function shot(t,expected){const m=t.capture();assert.ok(m,'missing capture message');for(const [k,v] of Object.entries(expected))eq(m[k],v,'capture.'+k)}
function lens(t,step){const b=t.run('tools').querySelectorAll('[data-step]').find(b=>Number(b.dataset.step)===step);assert.ok(b,'lens '+step);return b}
function last(t,type){return t.messages.filter(m=>m.type===type).at(-1)}

test('macro control follows reported hardware state and never captures',()=>{
    const t=ready(),button=t.doc.querySelector('.macro-control');
    eq(button.hidden,true);
    t.report(state({macroVisible:true,macroEnabled:true}));
    eq(button.hidden,false);eq(button.disabled,false);button.click();button.click();
    eq(t.messages.filter(m=>m.type==='macro').map(m=>m.enabled),[false,false]);
    t.report(state({macroVisible:true,macroEnabled:false}));eq(button.getAttribute('aria-pressed'),'false');
    button.click();eq(last(t,'macro'),{type:'macro',enabled:true});
    for(const patch of [{busy:true},{zoomSettling:true},{ready:false},{macroVisible:false},{macroEnabled:undefined}]){
        t.report(state({macroVisible:true,macroEnabled:true,...patch}));eq(button.disabled,true);button.click()
    }
    eq(t.messages.filter(m=>m.type==='macro').length,3);eq(last(t,'capture'),undefined);eq(last(t,'focus'),undefined);
});
test('macro requires settled actual zoom of at least 1x and blocks old camera or gesture events',()=>{
    const snapshot=patch=>state({inputRevision:8,zoomRequestID:20,zoom:1,zoomTarget:1,zoomSettling:false,
        lenses:[.5,1,2,3],zoomRange:[.5,15],macroVisible:true,macroEnabled:true,...patch});
    const t=ready(snapshot({})),macro=t.doc.querySelector('.macro-control');
    const count=()=>t.messages.filter(m=>m.type==='macro').length;
    const check=visible=>{
        eq(macro.hidden,!visible);eq(macro.disabled,!visible);
        if(!visible){const before=count();macro.onclick({detail:0});eq(count(),before)}
    };
    check(true);macro.click();eq(last(t,'macro'),{type:'macro',enabled:false,inputRevision:8});
    lens(t,.5).click();check(false);
    t.report(snapshot({}));check(false); // A late report still describes the previous 1x lens.
    t.report(snapshot({zoomRequestID:21,zoom:.9999,zoomTarget:1}));check(false);
    t.report(snapshot({zoomRequestID:21,zoom:1,zoomTarget:.5}));check(false);
    t.report(snapshot({zoomRequestID:21,zoom:.5,zoomTarget:.5}));check(false);
    for(const z of [1,2,3]){t.report(snapshot({zoomRequestID:21,zoom:z,zoomTarget:z}));check(true)}
    t.run('reviewZoom(.75)');check(false);
    t.report(snapshot({zoomRequestID:21,zoom:3,zoomTarget:3}));check(false);
    t.report(snapshot({zoomRequestID:22,zoom:1.2,zoomTarget:.75,zoomSettling:true}));check(false);
    t.report(snapshot({zoomRequestID:22,zoom:.75,zoomTarget:.75}));check(false);
    t.report(snapshot({zoomRequestID:23}));check(true);
    macro.dispatch('pointerdown',{pointerId:9});t.report(snapshot({inputRevision:9,zoomRequestID:23}));check(true);
    macro.onclick({detail:1});eq(count(),1);
    macro.dispatch('pointerdown',{pointerId:10});t.report(snapshot({inputRevision:9,zoomRequestID:23,busy:true}));
    eq(macro.hidden,false);eq(macro.disabled,true);macro.onclick({detail:0});eq(count(),1);
    t.report(snapshot({inputRevision:9,zoomRequestID:23}));macro.onclick({detail:1});eq(count(),1);
});
test('unversioned zoom reports restore macro only at the requested settled endpoint',()=>{
    const snapshot=(zoom,patch={})=>state({zoom,lenses:[.5,1,2,3],macroVisible:true,macroEnabled:true,...patch});
    const t=ready(snapshot(2)),macro=t.doc.querySelector('.macro-control');
    lens(t,.5).click();t.report(snapshot(2));eq(macro.hidden,true);
    t.report(snapshot(.5));eq(macro.hidden,true);
    lens(t,1).click();t.report(snapshot(.8));eq(macro.hidden,true);
    t.report(snapshot(1,{zoomSettling:true}));eq(macro.hidden,true);
    t.report(snapshot(1));eq(macro.hidden,false);eq(macro.disabled,false);
});
test('RAW round trip preserves both HEIF Live preferences at 12 MP',()=>{
    for(const enabled of [true,false]){
        const t=ready();if(enabled)startLive(t);t.open('格式');pick(t,'格式','RAW');
        eq(t.run('liveShortcut.disabled'),true);shot(t,{codec:'RAW',mp:12,live:false});
        t.report(state());pick(t,'格式','HEIF');eq(t.run('liveShortcut.disabled'),false);
        live(t,enabled);shot(t,{codec:'HEIF',mp:12,live:enabled})
    }
});
test('cold start: no capability claims or hardware commands',()=>{
    const t=boot(html);eq(last(t,'ready'),{type:'ready'});eq(t.capture(),undefined,'cold capture');
    for(const id of ['shutter','flip'])eq(t.doc.getElementById(id).disabled,true,id);for(const n of ['formatTile','formatShortcut','flashTile','topFlash','motionButton','liveShortcut'])eq(t.run(n).disabled,true,n);
    eq(t.run('formatShortcut.textContent'),'…');eq(t.run('formatTile.firstElementChild.textContent'),'…');
    t.run("reviewZoom(2);glideZoom(2);get('flip').onclick()");eq(last(t,'zoom'),undefined);eq(last(t,'flip'),undefined);
});
test('lens press centers and highlights on contact; movement and old reports do not reverse the tap',()=>{
    const t=ready({lenses:[.5,1,2,3],zoom:1});
    const enter=(value,id)=>{const b=lens(t,value);b.dispatch('pointerdown',{pointerId:id,clientX:40,clientY:44});return b};
    const release=(button,id)=>{button.dispatch('pointerup',{pointerId:id,clientX:40,clientY:44});button.dispatch('click',{detail:1,pointerId:id})};
    const selected=()=>Number([...t.run('tools').querySelectorAll('[data-step]')].find(b=>b.getAttribute('aria-pressed')==='true')?.dataset.step);
    const three=enter(3,1);
    eq(selected(),3);eq(t.run("tools.style['--active-slot']"),'3');eq(last(t,'zoom').value,3);
    three.dispatch('touchend',{changedTouches:[{identifier:1}]});
    release(three,1);release(enter(2,2),2);
    t.report(state({lenses:[.5,1,2,3],zoom:3,zoomSettling:false}));
    eq(selected(),2);eq(t.messages.filter(m=>m.type==='zoom').map(m=>m.value),[3,2]);
    const half=enter(.5,3);
    half.dispatch('pointermove',{pointerId:3,clientX:65,clientY:44});release(half,3);
    eq(selected(),.5);eq(t.messages.filter(m=>m.type==='zoom').map(m=>m.value),[3,2,.5]);
});
test('lens touch commits once even when the release moves, is cancelled or follows a camera flip',()=>{
    const hardware=state({inputRevision:73,zoomRequestID:20,zoomTarget:1,lenses:[.5,1,2,3],zoomRange:[.5,15]});
    const t=ready(hardware),other=t.run('stage');
    const events={pointerId:17,clientX:152,clientY:621};
    const begin=()=>{const b=lens(t,.5);b.dispatch('pointerdown',events);b.dispatch('lostpointercapture',events)};
    const release=()=>other.dispatch('pointerup',events);
    const commands=()=>t.messages.filter(m=>m.type==='zoom');
    begin();other.dispatch('pointerup',{...events,pointerId:19});
    eq(commands().length,1);
    release();release();
    eq(commands(),[{type:'zoom',value:.5,inputRevision:73,zoomRequestID:21}]);
    eq(Number(t.run("tools.querySelector('[aria-pressed=true]').dataset.step")),.5);
    const ghost=other.dispatch('click',{...events,detail:1});
    assert.ok(ghost.defaultPrevented||ghost.stopped,'retargeted compatibility click must not reach the viewfinder');
    eq(last(t,'focus'),undefined);eq(commands().length,1);
    t.report({...hardware,zoom:.5,zoomTarget:.5,zoomRequestID:21});
    for(const cause of ['drag','cancel','flip']){
        const one=lens(t,1),before=commands().length;
        one.dispatch('pointerdown',events);
        one.dispatch('lostpointercapture',events);
        if(cause==='drag')other.dispatch('pointermove',{...events,clientX:163});
        if(cause==='cancel')other.dispatch('pointercancel',events);
        if(cause==='flip')t.report({...hardware,inputRevision:74,zoomRequestID:0});
        release();one.dispatch('click',{...events,detail:1});
        eq(commands().slice(before).map(m=>m.value),[1],cause);
        t.report({...hardware,inputRevision:cause==='flip'?74:73,zoomRequestID:commands().at(-1).zoomRequestID,zoom:.5,zoomTarget:.5});
    }
});
test('cancelling a preset touch sends no reverse command and respects a newer request',()=>{
    const t=ready({inputRevision:4,zoomRequestID:2,zoom:2.37,zoomRange:[.5,15],lenses:[.5,1,2,3]});
    const e={pointerId:5,clientX:120,clientY:610},three=lens(t,3),stage=t.run('stage');
    three.dispatch('pointerdown',e);eq(last(t,'zoom').value,3);
    stage.dispatch('pointercancel',e);eq(last(t,'zoom').value,3);
    three.dispatch('pointerdown',e);lens(t,2).click();stage.dispatch('pointercancel',e);
    eq(t.messages.filter(m=>m.type==='zoom').map(m=>m.value),[3,2]);
});
test('only the newest zoom acknowledgement settles rapid button taps',()=>{
    const snapshot=patch=>state({inputRevision:5,zoomRequestID:7,zoomTarget:1,lenses:[.5,1,2,3],...patch});
    const t=ready(snapshot({}));
    const selected=()=>Number(t.run("tools.querySelector('[aria-pressed=true]').dataset.step"));
    lens(t,3).click();lens(t,2).click();lens(t,2).click();
    const bridge=fs.readFileSync(path.join(path.dirname(file),'StudioApp.swift'),'utf8');
    const idKey=bridge.match(/case "zoom":\s*c\.selectLens\([^)]*\)[\s\S]*?requestID:\s*payload\["(\w+)"\]/)?.[1];
    assert.ok(idKey,'native zoom command must read the request identifier');
    eq(t.messages.filter(m=>m.type==='zoom').map(m=>[m.value,m[idKey]]),[[3,8],[2,9]]);
    t.report(snapshot({zoom:3,zoomRequestID:8,zoomTarget:3}));
    eq(selected(),2);
    t.report(snapshot({zoom:1.5,zoomSettling:true,zoomRequestID:9,zoomTarget:2}));
    eq(selected(),2);
    t.report(snapshot({zoom:2,zoomRequestID:9,zoomTarget:2}));
    t.report(snapshot({zoom:3,zoomRequestID:8,zoomTarget:3}));
    eq(t.run('zoom'),2);eq(selected(),2);
    lens(t,3).click();
    t.report(snapshot({zoom:2,zoomRequestID:10,zoomTarget:2}));
    eq(selected(),2);
    t.report(snapshot({inputRevision:6,zoomRequestID:0,lenses:[1],zoom:1}));
    eq(selected(),1);
});
test('preset rail follows presented frames through a reversal and ignores early device completion',()=>{
    const snapshot=patch=>state({inputRevision:5,zoomRequestID:4,zoom:2,zoomTarget:2,zoomSettling:false,
        presentedZoomFrames:true,lenses:[.5,1,2,3],zoomRange:[.5,15],...patch});
    const t=ready(snapshot({}));t.host.matchMedia=()=>({matches:false});
    const slot=()=>Number(t.run("tools.style['--active-slot']"));
    const frame=(id,zoom,settled,time,revision=5)=>t.host.receiveZoomFrame({inputRevision:revision,zoomRequestID:id,zoom,settled,presentedTime:time});
    const three=lens(t,3),two=lens(t,2),e={pointerId:3,clientX:85,clientY:100};
    three.dispatch('pointerdown',e);
    eq(last(t,'zoom').value,3);eq(slot(),2);eq(three.getAttribute('aria-pressed'),'true');
    three.dispatch('pointerup',e);
    t.report(snapshot({zoom:3,zoomTarget:3,zoomRequestID:5}));
    eq(slot(),2);
    frame(5,Math.sqrt(6),false,1);assert.ok(Math.abs(slot()-2.5)<1e-8);
    two.dispatch('pointerdown',e);eq(last(t,'zoom').value,2);
    two.dispatch('pointerup',e);eq(two.getAttribute('aria-pressed'),'true');
    frame(5,3,true,2);assert.ok(Math.abs(slot()-2.5)<1e-8);
    frame(6,2.22,false,3);const mid=slot();assert.ok(mid>2&&mid<2.5);
    frame(6,2.7,false,2);frame(6,2.8,false,4,4);eq(slot(),mid);
    t.report(snapshot({zoom:2,zoomTarget:2,zoomRequestID:6}));eq(slot(),mid);
    frame(6,2,true,4);eq(slot(),2);
    frame(6,2.5,false,5);eq(slot(),2);
});
test('reduced motion waits for the presented endpoint; absent frames recover and input changes reset',()=>{
    const s=p=>state({inputRevision:2,zoomRequestID:5,zoom:1,zoomTarget:1,zoomSettling:false,presentedZoomFrames:true,lenses:[.5,1,2,3],...p});
    const t=ready(s({})),slot=()=>Number(t.run("tools.style['--active-slot']"));
    lens(t,3).click();eq(slot(),1);
    t.host.receiveZoomFrame({inputRevision:2,zoomRequestID:6,zoom:2.25,settled:false});eq(slot(),1);
    t.report(s({zoomRequestID:6,zoom:2,zoomTarget:2}));eq(slot(),1);
    t.host.receiveZoomFrame({inputRevision:2,zoomRequestID:6,zoom:2,settled:true});eq(slot(),2);
    lens(t,1).click();t.report(s({zoomRequestID:7}));eq(slot(),2);t.fireTimeout(100);eq(slot(),1);
    lens(t,2).click();t.report(s({inputRevision:3,zoom:1,lenses:[1],zoomRequestID:8}));eq(slot(),0);
    t.host.receiveZoomFrame({inputRevision:2,zoomRequestID:8,zoom:2,settled:true});eq(slot(),0);
});
test('a missing presented endpoint uses only the current acknowledged actual zoom',()=>{
    const s=patch=>state({inputRevision:2,zoomRequestID:1,zoom:1,zoomTarget:1,zoomSettling:false,
        presentedZoomFrames:true,lenses:[.5,1,2,3],...patch});
    const t=ready(s({}));t.host.matchMedia=()=>({matches:false});
    const slot=()=>Number(t.run("tools.style['--active-slot']"));
    lens(t,2).click();
    t.report(s({zoomRequestID:2,zoom:2,zoomTarget:2}));
    lens(t,3).click();
    t.fireTimeout(100);eq(slot(),1);
    t.report(s({zoomRequestID:3,zoom:2.4,zoomTarget:3,zoomSettling:true}));
    t.fireTimeout(100);eq(slot(),1);
    t.report(s({zoomRequestID:3,zoom:2,zoomTarget:2}));
    t.fireTimeout(100);eq(slot(),2);eq(lens(t,2).getAttribute('aria-pressed'),'true');
});
test('pinch takes over an in-flight ramp by relative scale and cancels stale frames',()=>{
    const snapshot=patch=>state({inputRevision:7,zoomRequestID:20,zoom:1,zoomTarget:3,zoomSettling:true,lenses:[.5,1,2,3],...patch});
    const t=ready(snapshot({})),stage=t.run('stage'),jobs=new Map();let next=0;
    t.host.requestAnimationFrame=fn=>{jobs.set(++next,fn);return next};
    t.host.cancelAnimationFrame=id=>jobs.delete(id);
    const tick=()=>{const frames=[...jobs.values()];jobs.clear();frames.forEach(fn=>fn(1000))};
    const count=()=>t.messages.filter(m=>m.type==='zoom').length;
    const touch=(type,id,x)=>stage.dispatch(type,{pointerId:id,clientX:x,clientY:200,isPrimary:id===1});
    const start=()=>{touch('pointerdown',1,40);touch('pointerdown',2,140)};
    start();touch('pointermove',2,150);
    const first=last(t,'zoom');assert.ok(Number.isSafeInteger(first.pinchID));
    eq(first.pinchScale,1.1);eq(first.value,1.1);
    touch('pointermove',2,160);touch('pointermove',2,170);eq(count(),1);
    tick();eq(count(),1);
    const ack=()=>t.report(snapshot({zoomRequestID:last(t,'zoom').zoomRequestID}));
    ack();tick();eq(last(t,'zoom').pinchID,first.pinchID);eq(last(t,'zoom').pinchScale,1.3);
    touch('pointermove',2,180);touch('pointerup',2,180);
    eq(count(),2);ack();tick();
    eq(last(t,'zoom').pinchScale,1.4);eq(count(),3);ack();tick();eq(count(),3);
    touch('pointerup',1,40);start();touch('pointermove',2,155);
    assert.notEqual(last(t,'zoom').pinchID,first.pinchID);eq(count(),4);
    touch('pointermove',2,170);touch('pointercancel',2,170);tick();eq(count(),4);
    touch('pointerup',1,40);start();touch('pointermove',2,150);touch('pointermove',2,170);
    lens(t,2).click();eq(last(t,'zoom').value,2);eq(last(t,'zoom').pinchID,undefined);
    const stopped=count();touch('pointermove',2,200);tick();eq(count(),stopped);
    start();touch('pointermove',2,150);touch('pointermove',2,170);
    const beforeFlip=count();t.report(snapshot({inputRevision:8,zoom:1,zoomTarget:1,zoomSettling:false}));
    touch('pointermove',2,200);tick();eq(count(),beforeFlip);
    start();touch('pointermove',2,160);const beforeDrop=count();touch('pointermove',2,185);touch('pointerup',2,185);
    tick();eq(count(),beforeDrop);t.fireTimeout(300);tick();
    eq(count(),beforeDrop+1);eq(last(t,'zoom').pinchScale,1.45);
});
test('zoom-only updates avoid viewfinder layout and preserve shutter gating across a ramp',()=>{
    const snapshot=patch=>state({inputRevision:5,zoomRequestID:4,zoomTarget:1,zoomSettling:false,...patch});
    const t=ready(snapshot({}));
    const frame=t.doc.querySelector('.phone').children.find(e=>e.classList.contains('stage')&&e.getAttribute('aria-hidden')==='true');
    let geometryReads=0;
    const measure=frame.getBoundingClientRect.bind(frame);
    frame.getBoundingClientRect=()=>{geometryReads++;return measure()};
    t.report(snapshot({zoom:1.3,zoomTarget:1.3,zoomRequestID:5}));
    eq(geometryReads,0);eq(t.run('zoom'),1.3);
    t.report(snapshot({zoom:1.3,zoomTarget:2,zoomRequestID:6,zoomSettling:true}));
    eq(t.doc.getElementById('shutter').disabled,true);
    const reads=geometryReads;assert.ok(reads>0);
    t.report(snapshot({zoom:1.7,zoomTarget:2,zoomRequestID:6,zoomSettling:true}));
    eq(geometryReads,reads);eq(t.run('zoom'),1.7);
    t.report(snapshot({zoom:2,zoomTarget:2,zoomRequestID:6}));
    eq(t.doc.getElementById('shutter').disabled,false);
});
test('native report, not tools click/bubbling or requested zoom, owns MP',()=>{
    const t=ready({sizes:[8],zoom:2});badge(t,'HEIF',8);lens(t,1).click();eq(last(t,'zoom'),{type:'zoom',value:1});
    badge(t,'HEIF',8);shot(t,{mp:8,codec:'HEIF'});t.open('格式');eq(labels(t.row('分辨率')),['8MP']);
    t.report(state({zoom:1,sizes:[8]}));eq(labels(t.row('分辨率')),['8MP'],'ramp target is not a capability');
    t.report(state({zoom:1,sizes:[8,24]}));eq(labels(t.row('分辨率')),['8MP','24MP']);eq(selected(t.row('分辨率')),['8MP']);
    pick(t,'分辨率','24MP');badge(t,'HEIF',24);shot(t,{mp:24});
});
test('reentrant native report during zoom click survives the later bubble listener',()=>{
    const t=ready({sizes:[8],zoom:2});const bridge=t.host.webkit.messageHandlers.camera,post=bridge.postMessage;
    bridge.postMessage=m=>{post(m);if(m.type==='zoom')t.report(state({zoom:1,sizes:[24,48]}))};lens(t,1).click();
    badge(t,'HEIF',24);shot(t,{codec:'HEIF',mp:24});t.open('格式');eq(selected(t.row('分辨率')),['24MP']);
});
test('zoom-out and return: a reported list gains 48 only on the later callback',()=>{
    const t=ready();t.open('格式');pick(t,'分辨率','48MP');badge(t,'HEIF',48);t.close();
    lens(t,2).click();t.report(state({zoom:2,sizes:[12]}));badge(t,'HEIF',12);lens(t,1).click();t.report(state({zoom:1,sizes:[12]}));
    t.open('格式');eq(labels(t.row('分辨率')),['12MP']);t.report(state());eq(labels(t.row('分辨率')),['12MP','48MP']);eq(selected(t.row('分辨率')),['12MP']);
});
test('Only 12 MP enables HEIF Live',()=>{
    const t=ready({zoom:2,sizes:[8]});lens(t,2).click();live(t,false);shot(t,{mp:8,codec:'HEIF',live:false,flash:false});
});
test('EV slider disarms both Live icons immediately and does not auto-rearm',()=>{
    const t=ready();startLive(t);t.open('曝光');const slider=t.run('selector').querySelector('input');slider.value='.5';slider.dispatch('input');live(t,false);shot(t,{ev:.5,live:false});
    slider.value='0';slider.dispatch('input');live(t,false);t.close();startLive(t);shot(t,{ev:0,live:true});
});
test('direct input dispatch and focus-sun EV drag reconcile before the shutter',()=>{
    const t=ready();startLive(t);const ev=t.doc.getElementById('ev');ev.value='0.2';ev.dispatch('input');live(t,false);eq(last(t,'recipe').ev,.2);
    ev.value=0;ev.dispatch('input');startLive(t);const sun=t.run('sun');sun.dispatch('pointerdown',{clientY:45});sun.dispatch('pointermove',{clientY:0});sun.dispatch('pointerup',{clientY:0});live(t,false);shot(t,{live:false,ev:1});
});
test('filter rail drag retains pointer capture/selection through a hardware report',()=>{
    const t=ready();startLive(t);t.open('滤镜');t.brand('sony');const track=t.run('selector').querySelector('.rail-track'),view=track.parentNode;
    view.dispatch('pointerdown',{clientX:200});view.dispatch('pointermove',{clientX:98});eq(view.captured,1);live(t,false);eq(last(t,'recipe').look,'FL2');
    t.report(state({sizes:[8],flash:false}));eq(t.run('selector').querySelector('.rail-track')===track,true,'rail was rebuilt mid-gesture');
    view.dispatch('pointermove',{clientX:0});view.dispatch('pointerup',{clientX:0});eq(selected(track.children),['FL3']);shot(t,{look:'FL3',live:false,mp:8});
    track.children[2].click();eq(t.run('selector.hidden'),false,'trailing drag click must be swallowed');
});
test('new tap after a filter or aspect swipe is accepted immediately',()=>{
    for(const kind of ['滤镜','宽高比']){
        const t=ready();t.open(kind);if(kind==='滤镜')t.brand('sony');const panel=t.run('selector');
        const view=kind==='滤镜'?panel.querySelector('.rail-track').parentNode:panel;
        view.dispatch('pointerdown',{clientX:190});view.dispatch('pointermove',{clientX:90});view.dispatch('pointerup',{clientX:90});
        const back=panel.querySelector('.return');back.dispatch('pointerdown');back.dispatch('pointerup');back.click();
        if(kind==='滤镜'){
            eq(panel.querySelector('.rail-track'),null);
            panel.querySelector('.return').click()
        }
        eq(panel.hidden,true);eq(t.run('drawer.hidden'),false)
    }
});
test('sun drag holds temporary EV then restores the manual compensation',()=>{
    const t=ready({biasLimits:[-3,3]});t.doc.getElementById('ev').value='0.5';t.run('refresh()');
    const s=t.run('sun');s.dispatch('pointerdown',{clientY:50});s.dispatch('pointermove',{clientY:95});s.dispatch('pointerup',{clientY:95});
    eq(last(t,'bias').value,-.5);eq(t.doc.getElementById('ev').value,'0.5');eq(s.style['--sun-y'],'18px');
    t.fireTimeout(4000);eq(last(t,'bias').value,.5);eq(s.style['--sun-y'],'0px')
});
test('Live resumes in 12 MP; switching to 48 MP disables Live immediately',()=>{
    const t=ready();startLive(t);t.report(state({live:false,liveSuspended:true}));shot(t,{live:false});
    t.report(state({liveSuspended:false}));shot(t,{live:true});
    t.open('格式');pick(t,'分辨率','48MP');t.close();shot(t,{live:false,mp:48});eq(t.run('liveShortcut.disabled'),true);t.run('liveShortcut').click();shot(t,{live:false,mp:48})
});
test('aspect choice: both Live indicators and outgoing aspect change together',()=>{
    const t=ready();startLive(t);t.open('宽高比');pickChoice(t,'16:9');live(t,false);shot(t,{aspect:'16:9',live:false});pickChoice(t,'4:3');live(t,false);
});
test('RAW cannot be selected on an 8-only report',()=>{
    const t=ready({sizes:[8]});t.open('格式');pick(t,'格式','RAW');badge(t,'HEIF',8);live(t,false);eq(selected(t.row('格式')),['HEIF']);shot(t,{codec:'HEIF',mp:8,live:false});
    pick(t,'格式','HEIF');live(t,false);
});
test('HEIF 48 MP turns off Live; RAW offers 12 and 48 MP and disables Live',()=>{
    const t=ready();startLive(t);t.open('格式');pick(t,'分辨率','48MP');live(t,false);shot(t,{mp:48,live:false});
    pick(t,'格式','RAW');eq(labels(t.row('分辨率')),['12MP','48MP']);eq(t.run('liveShortcut.disabled'),true);t.report(state({sizes:[7],formats:['JPEG'],live:false}));badge(t,'JPEG',7);eq(selected(t.row('格式')),['JPEG']);eq(selected(t.row('分辨率')),['7MP']);shot(t,{codec:'JPEG',mp:7,live:false});
});
test('18 MP HEIF plus a physical-wide 48 MP mode returns to an actual normal size',()=>{
    const front=ready({sizes:[2,10,18]});shot(front,{codec:'HEIF',mp:10});
    const t=ready({mode48:false,alternate48:true,sizes:[7,18]});t.open('格式');
    eq(labels(t.row('分辨率')),['7MP','18MP','48MP']);pick(t,'分辨率','18MP');
    shot(t,{codec:'HEIF',mp:18,live:false});
    pick(t,'分辨率','48MP');
    t.report(state({mode48:true,sizes:[48],normalSizes:[7,18]}));t.host.finishWide48(true);
    eq(labels(t.row('分辨率')),['7MP','18MP','48MP']);
    pick(t,'分辨率','18MP');
    t.report(state({mode48:false,alternate48:true,sizes:[7,18]}));t.host.finishWide48(true);
    shot(t,{codec:'HEIF',mp:18,live:false})
});
test('dedicated 48 MP selection waits for confirmation and unlocks after failure',()=>{
    const t=ready({alternate48:true,sizes:[12]});t.open('格式');pick(t,'格式','RAW');shot(t,{codec:'RAW',mp:12});pick(t,'分辨率','48MP');
    eq(last(t,'prepare48').type,'prepare48');eq(t.capture(),undefined);
    t.host.finishWide48(false);shot(t,{codec:'RAW',mp:12});
    pick(t,'分辨率','48MP');t.report(state({sizes:[12,48]}));t.host.finishWide48(true);
    eq(labels(t.row('分辨率')),['12MP','48MP']);shot(t,{codec:'RAW',mp:48,live:false})
});
test('physical 48 MP keeps digital zoom and requires confirmation to return to optical 12 MP',()=>{
    const t=ready({mode48:false,alternate48:true});startLive(t);t.open('格式');pick(t,'分辨率','48MP');
    eq(last(t,'prepare48').enabled,true);eq(t.capture(),undefined);live(t,false);
    t.report(state({mode48:true,lenses:[1,2,3]}));t.host.finishWide48(true);
    t.report(state({mode48:true,zoom:3,lenses:[1,2,3]}));shot(t,{mp:48,live:false});
    pick(t,'分辨率','12MP');eq(last(t,'prepare48').enabled,false);eq(t.capture(),undefined);
    t.report(state({mode48:false}));t.host.finishWide48(true);shot(t,{mp:12,live:false});
    eq(t.doc.getElementById('shutter').disabled,false);t.close();t.run('liveShortcut').click();shot(t,{mp:12,live:true})
});
test('hardware report can invalidate Live without any user change',()=>{
    for(const patch of [{sizes:[24]},{formats:['JPEG']},{live:false}]){const t=ready();startLive(t);t.report(state(patch));live(t,false);shot(t,{live:false});t.report(state());live(t,false)}
});
test('flash and Live never coexist; losing flash support clears both flash indicators',()=>{
    const t=ready();startLive(t);t.run('topFlash').click();flash(t,true);live(t,false);shot(t,{flash:true,live:false});
    t.run('motionButton').click();shot(t,{flash:true,live:false});t.report(state({flash:false}));flash(t,false);eq(t.run('topFlash.disabled'),true);shot(t,{flash:false,live:false});
    startLive(t);t.report(state({live:false,flash:false}));live(t,false);eq(t.run('liveShortcut.disabled'),true);
});
test('forced night is exclusive with Live, flash and RAW on the wire',()=>{
    const t=ready();startLive(t);t.open('夜间模式');pickChoice(t,'开启');live(t,false);shot(t,{night:'开启',live:false,flash:false});
    t.close();t.run('topFlash').click();flash(t,true);shot(t,{night:'关闭',live:false,flash:true});t.open('夜间模式');pickChoice(t,'开启');flash(t,false);shot(t,{night:'开启',flash:false});
    t.open('格式');pick(t,'格式','RAW');shot(t,{codec:'RAW',night:'关闭',live:false});t.open('夜间模式');eq(t.run('selector').querySelectorAll('div button').at(-1).disabled,true);
});
test('busy disables/reenables the open format rows without changing the selection',()=>{
    const t=ready();t.open('格式');pick(t,'分辨率','48MP');const old=t.row('格式').find(b=>b.textContent==='RAW');t.report(state({busy:true}));
    eq(t.run('formatShortcut.disabled'),true);eq(t.row('格式').every(b=>b.disabled),true);eq(t.row('分辨率').every(b=>b.disabled),true);badge(t,'HEIF',48);
    old.onclick();eq(t.capture(),undefined);badge(t,'HEIF',48);t.report(state());eq(t.row('格式').some(b=>b.disabled),false);shot(t,{codec:'HEIF',mp:48});
});
test('unready/empty/partial lists cannot leak default format, sizes or shutter',()=>{
    const t=ready();t.open('格式');const previous=t.row('格式')[1];
    for(const patch of [{ready:false},{sizes:[]},{formats:[]},{sizes:undefined},{formats:undefined}]){t.report(state(patch));eq(t.capture(),undefined);eq(t.run('formatShortcut.textContent'),'…');eq(t.run('formatTile.firstElementChild.dataset.mp'),undefined);eq(t.doc.getElementById('shutter').disabled,true);eq(t.row('格式').length+t.row('分辨率').length,0);previous.onclick()}
    t.report(state({busy:undefined}));eq(t.capture(),undefined);t.report(state({formats:['JPEG'],sizes:[5]}));badge(t,'JPEG',5);shot(t,{codec:'JPEG',mp:5,live:false});
});
test('stale format button after a lens change cannot re-introduce the old size',()=>{
    const t=ready();t.open('格式');const old=t.row('分辨率').find(b=>b.textContent==='48MP');t.report(state({formats:['JPEG'],sizes:[9]}));old.onclick();
    badge(t,'JPEG',9);eq(selected(t.row('分辨率')),['9MP']);shot(t,{codec:'JPEG',mp:9});
});
test('busy after starting timer cancels it; direct/stale shutter/zoom/flip also gated',()=>{
    const t=ready();t.open('计时器');pickChoice(t,'3 秒');t.close();t.shutter();assert.ok(t.run('countdown!==null'));t.tick(1000);
    const oldLens=lens(t,2);t.report(state({busy:true}));t.tick(1000,3);eq(last(t,'capture'),undefined,'timer fired while busy');eq(t.capture(),undefined);
    oldLens.onclick();t.run("reviewZoom(2);get('flip').onclick()");eq(last(t,'zoom'),undefined);eq(last(t,'flip'),undefined);t.report(state());t.tick(1000,3);eq(last(t,'capture'),undefined,'cancelled timer resurrected');
});
test('delayed shutter uses current recipe and capability fallback, not timer-start values',()=>{
    const t=ready();startLive(t);t.open('计时器');pickChoice(t,'3 秒');t.close();t.shutter();t.tick(1000);t.report(state({formats:['JPEG'],sizes:[7],live:false}));
    t.tick(1000,2);eq(last(t,'capture').codec,'JPEG');eq(last(t,'capture').mp,7);eq(last(t,'capture').live,false);live(t,false);badge(t,'JPEG',7);
});
test('capture boundary reconciles an input change even if no event has fired',()=>{
    const t=ready();startLive(t);t.doc.getElementById('ev').value='1.3';shot(t,{live:false,ev:1.3});live(t,false);
});
test('non-photo mode sends no capture; ordinary native shutter still works',()=>{
    const t=ready();t.run('setMode(0)');t.shutter();eq(last(t,'capture'),undefined);t.run('setMode(1)');t.shutter();eq(last(t,'capture').type,'capture');
});
test('desktop (no bridge): zoom, format simulator and media recorder remain separate',()=>{
    const t=boot(html,{native:false,touch:false});eq(t.host.receiveCamera,undefined);t.open('格式');pick(t,'格式','RAW');badge(t,'RAW',12);t.close();lens(t,2).click();badge(t,'RAW',12);t.open('格式');eq(t.row('分辨率').at(-1).disabled,true);t.close();
    t.run('stream={}');t.run('liveShortcut').click();live(t,true);eq(t.messages.length,0);
});
test('desktop rail and repeated selected-filter tap retain their own behavior',()=>{
    const t=boot(html,{native:false,touch:false});t.open('滤镜');t.brand('sony');const track=t.run('selector').querySelector('.rail-track');
    track.children[1].click();eq(selected(track.children),['FL2']);track.children[1].click();eq(t.run('selector.hidden'),true);eq(t.messages.length,0);
});
test('brand browsing preserves the recipe and each tile captures with its own look',()=>{
    const t=ready(),panel=t.run('selector');
    const groups={
        sony:['original','FL2','FL3'],
        fuji:['original','Classic-Chrome','Classic-Negative','Nostalgic-Negative','Fuji-Astia','Fuji-Eterna','Fuji-Eterna-Bypass','Fuji-NOS','Fuji-ProNeg-Hi','Fuji-ProNeg-Std','Fuji-Provia','Fuji-Velvia'],
        ricoh:['original','GR-Positive','GR4-CineG','GR4-CineY'],
        hasselblad:['original','HABL1','HABL2','HACI1','HACI2','HAFM2','HSST2','HSST3'],
        leica:['original','Leica-M-BW-B','Leica-M-BW-Y','Leica-M-Smooth-V2','Leica-M-Tone','Leica-M-Tone-V2','Leica-M-Vivid','Leica-M-Vivid-V2']
    };
    t.open('滤镜');
    eq(labels(panel.querySelectorAll('.filter-brands button')),['索尼','富士','理光','哈苏','徕卡']);
    eq(panel.querySelector('.rail-track'),null);
    eq(t.messages.filter(m=>m.type==='rail'&&m.open).length,0);
    let active='original';
    for(const [brand,looks] of Object.entries(groups)){
        t.brand(brand);
        const track=panel.querySelector('.rail-track'),tiles=track.children;
        eq(last(t,'rail').looks,looks.slice(0,3));
        eq(track.querySelectorAll('canvas').map(c=>c.dataset.look),looks);
        eq(tiles[0].textContent,'原图');
        shot(t,{look:active});
        if(active!=='original'){
            eq(selected(tiles),[]);
            tiles[0].click();
            shot(t,{look:'original'});
            eq(panel.hidden,false);
        }
        for(let index=1;index<looks.length;index++){
            tiles[index].click();
            eq(last(t,'rail').looks,looks.slice(Math.max(0,index-2),index+3));
            active=looks[index];
            shot(t,{look:active});
        }
    }
    t.close();t.open('滤镜');eq(panel.querySelector('.rail-track'),null);
    t.brand('leica');eq(selected(panel.querySelector('.rail-track').children),['M Vivid V2']);
});
test('landscape startup/rotation proceeds through the actual script in both mobile paths',()=>{
    for(const native of [true,false]){const t=boot(html,{native,landscape:true});eq(t.run('stage.dataset.pose'),'landscape');eq(t.run('frameRatio()'),4/3);if(native)eq(last(t,'ready'),{type:'ready'});
        t.host.innerWidth=390;t.host.innerHeight=800;t.host.screen.orientation.type='portrait-primary';t.run('readScreenPose()');eq(t.run('stage.dataset.pose'),'portrait');eq(t.run('frameRatio()'),3/4)}
});
test('receiveThumbs paints the chosen brand at its requested resolution',async()=>{
    const t=ready();t.open('滤镜');t.brand('sony');t.run('refresh()');
    const request=last(t,'rail');eq(request.looks,['original','FL2','FL3']);eq(request.open,true);eq(request.edge,100);
    const thumb=t.run('selector').querySelector('canvas[data-look="FL2"]'),ctx=thumb.getContext();const draws=[];ctx.drawImage=(...args)=>draws.push(args);
    const looks=request.looks;
    t.host.Image=class {naturalHeight=8;naturalWidth=8*looks.length;async decode(){}};
    await t.host.receiveThumbs('sample',looks,request.version);eq(draws.length,1);eq(draws[0][0].src,'data:image/jpeg;base64,sample');eq(draws[0].slice(1),[8,0,8,8,0,0,8,8]);
    t.close();t.run('refresh()');await t.host.receiveThumbs('sample',['FL2']);eq(draws.length,1);
});
(async()=>{let failures=0;console.log(file);for(const [name,check] of cases){try{await check();console.log('PASS '+name)}catch(error){failures++;console.log('FAIL '+name+'\n  '+error.message);if(process.env.CAMERA_UI_STACK)console.log(error.stack)}}console.log(`${cases.length-failures}/${cases.length} passed; ${failures} failed`);if(failures)process.exitCode=1})();
