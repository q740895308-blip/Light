const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const {chromium,webkit}=require('playwright-core');
const {verifyMenuDismissal}=require('./menu-dismissal.cjs');
const {verifyFilterFirstFrame}=require('./filter-first-frame.cjs');
const {verifyMenuGlass}=require('./menu-glass.cjs');
const {verifyLutPixels}=require('./lut-pixels.cjs');
(async()=>{
    const engine=process.env.CHROME_EXE?chromium:webkit;
    const browser=await engine.launch({headless:true,...(process.env.CHROME_EXE?{executablePath:process.env.CHROME_EXE}:{})});
    try {
        const viewports=[[393,852],[852,393]];
        if(process.env.ALL_IPHONE_PROFILES==='1')viewports.push([402,874],[440,956]);
        for(const [width,height] of viewports){
            const context=await browser.newContext({viewport:{width,height},deviceScaleFactor:3,isMobile:true,hasTouch:true});
            const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
            await page.addInitScript(()=>{window.posts=[];Object.defineProperty(window,'webkit',{configurable:true,value:{messageHandlers:{camera:{postMessage:m=>window.posts.push(m)}}}})});
            await page.goto(pathToFileURL(path.join(__dirname,'..','FL-Camera-Review.html')).href);
            if(width===393){await verifyLutPixels(page,true);await verifyFilterFirstFrame(page);await page.reload()}
            await page.evaluate(()=>window.receiveCamera({ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],lenses:[.5,1,2,3],zoom:1,zoomTarget:1,zoomSettling:false,inputRevision:1,zoomRequestID:0,flash:true,live:true,biasLimits:[-3,3]}));
            if(width===393)await verifyMenuGlass(page);
            await verifyMenuDismissal(page);
            if(width===402||width===440){assert.deepEqual(errors,[]);await context.close();continue}
            if(width<height){
                const positions=await page.evaluate(()=>{
                    const geometry=()=>[stage.dataset.pose,stage.getBoundingClientRect().toJSON(),get('shutter').getBoundingClientRect().toJSON()];
                    const states=[geometry()];
                    for(const [gamma,beta] of [[90,0],[-90,0],[0,0],[0,90]]){
                        const event=new Event('deviceorientation');
                        Object.assign(event,{gamma,beta});
                        window.dispatchEvent(event);states.push(geometry())
                    }
                    return states
                });
                for(const position of positions)assert.deepEqual(position,positions[0],'device pose moved native camera controls');
                assert.equal(positions[0][0],'portrait')
            }
            async function checkZoom(value){
                await page.locator('[data-step="'+value+'"]').tap();
                const command=await page.evaluate(()=>posts.filter(m=>m.type==='zoom').at(-1));
                assert.equal(command.value,value);
                assert.equal(command.inputRevision,1);assert.ok(Number.isSafeInteger(command.zoomRequestID));
                assert.equal(await page.evaluate(()=>tools.style.getPropertyValue('--active-slot')),String([.5,1,2,3].indexOf(value)));
                await page.evaluate(({value,zoomRequestID})=>window.receiveCamera({...window.nativeCameraState,zoom:value,zoomTarget:value,zoomRequestID}),command);
                await page.waitForFunction(()=>{
                    const active=document.querySelector('.capture-tools [aria-pressed=true]').getBoundingClientRect();
                    const anchor=innerWidth>innerHeight?'.stage':'#shutter';
                    const shutter=document.querySelector(anchor).getBoundingClientRect();
                    return Math.abs(active.x+active.width/2-shutter.x-shutter.width/2)<1
                },null,{timeout:2500}).catch(async error=>{
                    const geometry=await page.evaluate(()=>Object.fromEntries(['.phone','.stage','.shootrow','#shutter','.capture-tools','.capture-tools [aria-pressed=true]'].map(s=>[s,document.querySelector(s).getBoundingClientRect().toJSON()])));
                    throw Error(error.message+' '+JSON.stringify(geometry))
                })
            }
            const controlBoxes=()=>page.evaluate(()=>['#shutter','.capture-tools'].map(s=>{const r=document.querySelector(s).getBoundingClientRect();return [r.x,r.y,r.width,r.height]}));
            const geometry=await page.locator('.phone').boundingBox();
            assert.ok(Math.abs(geometry.width-width)<1&&Math.abs(geometry.height-height)<1,JSON.stringify(geometry));
            const macro=page.getByRole('button',{name:'自动微距',exact:true});
            assert.equal(await macro.isVisible(),false);
            const reportMacro=patch=>page.evaluate(patch=>window.receiveCamera({...window.nativeCameraState,...patch}),patch);
            await reportMacro({macroVisible:true,macroEnabled:true});
            const flowerBox=await macro.boundingBox(),shutterBox=await page.locator('#shutter').boundingBox();
            assert.ok(flowerBox.width>=44&&flowerBox.height>=44&&flowerBox.x+flowerBox.width<=shutterBox.x);
            assert.ok(Math.abs(flowerBox.y+flowerBox.height/2-shutterBox.y-shutterBox.height/2)<1);
            assert.equal(await macro.evaluate(b=>getComputedStyle(b).color),'rgb(255, 214, 10)');
            await macro.tap();
            await reportMacro({macroEnabled:false});
            assert.equal(await macro.getAttribute('aria-pressed'),'false');await macro.tap();
            assert.deepEqual(await page.evaluate(()=>posts.filter(m=>m.type==='macro').map(m=>m.enabled)),[false,true]);
            assert.equal(await page.evaluate(()=>posts.filter(m=>m.type==='capture'||m.type==='focus').length),0);
            await reportMacro({busy:true});assert.equal(await macro.isVisible(),true);assert.equal(await macro.isDisabled(),true);
            await reportMacro({macroEnabled:true,busy:false});
            if(width===393){
                await page.emulateMedia({reducedMotion:'reduce'});
                const anchors=()=>page.evaluate(()=>['.stage','#shutter','#toggle','#album','.capture-tools [aria-pressed=true]'].map(s=>document.querySelector(s).getBoundingClientRect().toJSON()));
                const before=await anchors();
                for(const angle of [90,-90,180,0]){
                    await reportMacro({controlRotation:angle});
                    const rotations=await page.evaluate(()=>['.top .icon svg','.mode .control-label','.format-shortcut .control-label','#toggle svg','#flip svg','.macro-glyph','.capture-tools [aria-pressed=true] .control-label'].map(s=>parseFloat(getComputedStyle(document.querySelector(s)).rotate)||0));
                    for(const actual of rotations)assert.equal((actual+720)%360,(angle+720)%360);
                    assert.deepEqual(await anchors(),before,'rotation preserves touch regions and preview');
                    if(Math.abs(angle)!==90)continue;
                    await page.locator('#filters').tap();
                    await page.locator('.filter-brands button[data-brand="sony"]').tap();
                    const picker=page.locator('.bottom-selector'),surface=picker.locator('.picker-surface');
                    const outer=await picker.boundingBox(),inner=await surface.boundingBox();
                    assert.ok(Math.abs(outer.width-inner.width)<3&&Math.abs(outer.height-inner.height)<3,'rotated menu fits glass');
                    const rail=surface.locator('.rail-window'),rect=await rail.boundingBox();
                    const x=rect.x+rect.width/2,y=rect.y+rect.height/2;
                    await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x,y-Math.sign(angle)*rect.height*.4,{steps:8});await page.mouse.up();
                    assert.ok(await page.evaluate(()=>get('look').selectedIndex>0),'sideways filter swipe');
                    await surface.getByRole('button',{name:'返回滤镜品牌'}).tap();
                    await surface.getByRole('button',{name:'返回拍摄控制'}).tap();
                    const timer=page.locator('.tilegrid button').filter({hasText:'计时器'});
                    const tileAngle=await timer.locator('i').evaluate(i=>parseFloat(getComputedStyle(i).rotate));
                    assert.equal((tileAngle+720)%360,(angle+720)%360);
                    await timer.tap();
                    const choice=picker.getByRole('button',{name:'3 秒',exact:true});await choice.tap();assert.equal(await choice.getAttribute('aria-pressed'),'true');
                    await picker.getByRole('button',{name:'关闭',exact:true}).tap();
                    await page.evaluate(()=>{leavePicker();get('look').selectedIndex=0;mark();refresh()})
                }
                await page.emulateMedia({reducedMotion:'no-preference'});
                await page.locator('#filters').tap();
                await page.evaluate(()=>Promise.all(selector.getAnimations().map(a=>a.finished)));
                const turned=await page.evaluate(async()=>{
                    const anchor=get('shutter').getBoundingClientRect();
                    window.receiveCamera({...window.nativeCameraState,controlRotation:90});
                    const surface=selector.querySelector('.picker-surface');
                    const rotation=surface.getAnimations().find(a=>a.transitionProperty==='rotate');
                    if(!rotation)return false;
                    rotation.pause();rotation.currentTime=110;
                    const mid=parseFloat(getComputedStyle(surface).rotate);
                    window.receiveCamera({...window.nativeCameraState,controlRotation:0});
                    const same=selector.querySelector('.picker-surface')===surface;
                    await Promise.allSettled(surface.getAnimations().map(a=>a.finished));
                    const end=surface.getBoundingClientRect(),button=get('shutter').getBoundingClientRect();
                    return mid%360!==0&&mid%90!==0&&same&&end.width>0&&anchor.x===button.x&&anchor.y===button.y
                });
                assert.equal(turned,true,'turning controls keep the same surface through a reversal');
                await page.evaluate(()=>leavePicker())
            }
            await page.touchscreen.tap(2,8);await page.touchscreen.tap(2,8);
            assert.equal(await page.evaluate(()=>visualViewport.scale),1);
            for(const value of [.5,3,2,1])await checkZoom(value);
            const controlsUnderSheet=()=>page.evaluate(()=>{
                const buttons=[get('shutter'),tools.querySelector('[aria-pressed=true]'),get('toggle'),document.querySelector('.macro-control')];
                return buttons.map(b=>{
                    const {x,y,width,height}=b.getBoundingClientRect();
                    for(let el=b;el&&el!==footer;el=el.parentElement){
                        const style=getComputedStyle(el);
                        if(style.opacity!=='1'||style.visibility!=='visible'||style.display==='none')throw Error('camera control faded or hidden: '+el.className);
                        if(el.getAnimations().some(a=>a.effect.getKeyframes().some(k=>'opacity' in k)))throw Error('opacity animation on camera control');
                    }
                    return {rect:[x,y,width,height],hit:b.contains(document.elementFromPoint(x+width/2,y+height/2))}
                })
            });
            await page.evaluate(()=>{aspect='1:1';syncFrame();refresh()});
            await page.evaluate(()=>Promise.all(tools.getAnimations().map(a=>a.finished)));
            const home=await controlsUnderSheet();assert.ok(home.every(b=>b.hit&&b.rect[2]>0));
            for(const [shortcut,panelId] of [['#toggle','#panel'],['#filters','.bottom-selector']]){
                const assertCovered=async()=>{
                    const controls=await controlsUnderSheet();
                    assert.deepEqual(controls.map(b=>b.rect),home.map(b=>b.rect));
                    assert.ok(controls.every(b=>!b.hit),'open sheet blocks touch on all four underlying controls');
                    const cover=await page.evaluate(id=>{
                        const el=document.querySelector(id),panel=getComputedStyle(el);
                        return {id,inert:shootRow.inert,opacity:panel.opacity,background:panel.backgroundColor,
                            retracting:el.classList.contains('retracting'),panelLayer:Number(panel.zIndex),rowLayer:Number(getComputedStyle(shootRow).zIndex)}
                    },panelId);
                    assert.ok(cover.inert&&cover.opacity==='1'&&cover.panelLayer>cover.rowLayer,
                        'panel stays ahead of the inert camera controls '+JSON.stringify(cover));
                    if(cover.retracting)assert.match(cover.background,/^rgb\(/,'closing shell must be opaque');
                };
                for(const opening of [true,false]){
                    await page.evaluate(({opening,shortcut,panelId})=>{
                        const panel=document.querySelector(panelId);
                        if(opening)document.querySelector(shortcut).click();else foldControls(panel);
                        const motion=panel.getAnimations()[0];motion.pause();motion.currentTime=0
                    },{opening,shortcut,panelId});
                    for(const progress of [0,.5,.99]){
                        await page.evaluate(({id,progress})=>{
                            const motion=document.querySelector(id).getAnimations()[0];
                            motion.currentTime=motion.effect.getTiming().duration*progress
                        },{id:panelId,progress});
                        await assertCovered()
                    }
                    await page.evaluate(id=>document.querySelector(id).getAnimations()[0].finish(),panelId);
                    if(opening)await assertCovered()
                }
                await page.locator(panelId).waitFor({state:'hidden'});assert.deepEqual(await controlsUnderSheet(),home);
            }
            const jumps=await page.evaluate(()=>{
                function reversedDelta(panel,open,reopen,target){
                    open();panel.getAnimations().forEach(a=>a.finish());foldControls(panel);
                    sheetMotion.pause();sheetMotion.currentTime=sheetMotion.effect.getTiming().duration*.7;
                    const before=panel.getBoundingClientRect();
                    reopen();
                    const opening=target.getAnimations()[0];opening.pause();opening.currentTime=0;
                    const after=target.getBoundingClientRect();
                    const label=target.querySelector(target===drawer?'.tilegrid button>span':'small');
                    if(!label.getClientRects().length||getComputedStyle(label).visibility!=='visible'||getComputedStyle(label).opacity==='0')throw Error('interrupted close left the menu text hidden');
                    stopSheetMotion();leavePicker();
                    return Math.max(...['x','y','width','height'].map(k=>Math.abs(after[k]-before[k])))
                }
                return [
                    reversedDelta(drawer,()=>controlsButton.onclick(),()=>controlsButton.onclick(),drawer),
                    reversedDelta(selector,()=>chooseBottom('滤镜',true),()=>toggleShortcut('格式'),selector)
                ]
            });
            assert.ok(jumps.every(n=>n<1),'interrupted panel changed bounds on its first frame: '+jumps);
            const dock=await page.evaluate(async()=>{
                const results=[];
                for(const [slot,name] of [[0,''],[2,'宽高比']]){
                    modeStrip.classList.add('sliding');setMode(slot);
                    const target=window.renderedModeCapsule();
                    modeStrip.classList.remove('sliding');
                    if(name)chooseBottom(name,true);else controlsButton.onclick();
                    const panel=name?selector:drawer;
                    panel.getAnimations().forEach(a=>a.finish());foldControls(panel);
                    const close=sheetMotion;close.pause();close.currentTime=close.effect.getTiming().duration;
                    const end=panel.getBoundingClientRect();
                    const edgeError=Math.max(...['x','y','width','height'].map(k=>Math.abs(end[k]-target[k])));
                    close.finish();
                    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                    const pulse=modeButtons[slot].getAnimations().find(a=>a.animationName==='capsule-label-rebound');
                    const targetStyle=getComputedStyle(modeStrip,'::before');
                    if(targetStyle.animationName!=='capsule-rebound')throw Error('missing visible capsule rebound');
                    const duration=parseFloat(targetStyle.animationDuration)*1000;
                    const probe=document.createElement('style');document.head.append(probe);
                    const pillSelector='.native-camera .mode.dock-rebound[role=group]::before';
                    const frames=[.19,.51,.79,1].map(fraction=>{
                        // Restart paused so time spent rendering earlier frames never enters the sample.
                        probe.textContent=pillSelector+'{animation-name:none!important}';
                        if(getComputedStyle(modeStrip,'::before').animationName!=='none')throw Error('capsule clock did not reset');
                        probe.textContent=pillSelector+'{animation-play-state:paused!important;animation-delay:-'+duration*fraction+'ms!important}';
                        const matrix=new DOMMatrixReadOnly(getComputedStyle(modeStrip,'::before').transform);
                        return [matrix.a,matrix.d]
                    });
                    probe.remove();
                    const [[wide,flat],[narrow,tall],[dampedX,dampedY],[restX,restY]]=frames;
                    if(!(wide>1.06&&flat<.92&&narrow<.97&&tall>1.05&&dampedX>1&&dampedX<wide&&dampedY<1&&dampedY>flat&&Math.abs(restX-1)<.001&&Math.abs(restY-1)<.001))
                        throw Error('unexpected capsule rebound keyframes '+JSON.stringify(frames));
                    results.push([edgeError,modeStrip.classList.contains('dock-rebound'),pulse?.effect.getTiming().iterations]);
                    if(!pulse)break;
                    pulse.finish();await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                    if(modeStrip.classList.contains('dock-rebound'))throw Error('capsule rebound did not settle');
                }
                setMode(1);return results
            });
            assert.ok(dock.length===2&&dock.every(([error,pulse,iterations])=>error<1&&pulse&&iterations===1),'capsule dock '+JSON.stringify(dock));
            await page.evaluate(()=>{aspect='4:3';syncFrame();refresh()});
            await page.evaluate(()=>Promise.all(tools.getAnimations().map(a=>a.finished)));
            await page.evaluate(()=>Promise.all(tools.getAnimations().map(a=>a.finished)));const baseline=await controlBoxes();await page.locator('#toggle').tap();const grip=page.locator('.drawer-grip');await grip.waitFor();
            await page.evaluate(()=>Promise.all(document.querySelector('#panel').getAnimations().map(a=>a.finished)));
            assert.equal(await page.evaluate(()=>shootRow.inert&&document.querySelector('.macro-control').offsetWidth>0),true);
            const closing=await page.evaluate(()=>{
                foldControls(drawer);const animation=sheetMotion;animation.pause();animation.currentTime=animation.effect.getTiming().duration;
                for(const progress of [0,.5,1]){
                    animation.currentTime=animation.effect.getTiming().duration*progress;
                    if(getComputedStyle(modeButtons[1].firstElementChild).webkitTextFillColor!=='rgb(255, 214, 10)')throw Error('photo label lost its yellow fill');
                    if(getComputedStyle(tools).visibility!=='visible'||!shootRow.inert)throw Error('underlying row removed or interactive')
                }
                const box=drawer.getBoundingClientRect(),target=window.renderedModeCapsule();
                const distance=Math.hypot(box.x+box.width/2-target.x-target.width/2,box.y+box.height/2-target.y-target.height/2);
                stopSheetMotion();return distance
            });assert.ok(closing<2,'menu close target: '+closing);
            const box=await grip.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
            const openBox=await page.locator('#panel').boundingBox();
            await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x,y+16,{steps:4});
            const pulled=await page.locator('#panel').boundingBox();
            assert.ok(pulled.height<openBox.height && pulled.height>openBox.height*.96,'light vertical compression');
            assert.ok(Math.abs(pulled.y+pulled.height-openBox.y-openBox.height)<1,'bottom stays anchored');
            await page.mouse.move(x,y+32,{steps:3});
            await page.locator('#panel').waitFor({state:'hidden'});
            await page.mouse.up();
            await page.locator('.format-shortcut').tap();assert.deepEqual(await page.locator('[aria-label="格式"] button').allTextContents(),['HEIF','RAW']);
            assert.equal(await macro.isVisible(),false);
            await reportMacro({macroVisible:false});
            const panel=page.locator('.bottom-selector'),shutter=page.locator('#shutter');
            await page.evaluate(()=>Promise.all(selector.getAnimations().map(a=>a.finished)));
            const panelBox=await panel.boundingBox(),shotBox=await shutter.boundingBox();
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            const menuControls=await controlBoxes();
            assert.ok(menuControls[0][1]+menuControls[0][3]<panelBox.y&&panelBox.y+panelBox.height>height-48,JSON.stringify({menuControls,panelBox}));
            await checkZoom(2);await checkZoom(1);
            await page.evaluate(()=>window.receiveCamera({...window.nativeCameraState,mode48:false}));
            await panel.locator('.format-row button').filter({hasText:'48'}).tap();
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            const lifted=await controlBoxes();assert.ok(lifted[0][1]<menuControls[0][1]-8);
            await page.evaluate(()=>{window.receiveCamera({...window.nativeCameraState,mode48:true});window.finishWide48(true)});
            const duration=await page.evaluate(()=>parseFloat(getComputedStyle(shootRow).transitionDuration));
            assert.ok(duration>=.6);await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            assert.deepEqual(await controlBoxes(),menuControls);
            await panel.locator('.format-row button').filter({hasText:'12'}).tap();
            await page.evaluate(()=>{window.receiveCamera({...window.nativeCameraState,mode48:false});window.finishWide48(true)});
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            const initialShots=await page.evaluate(()=>posts.filter(p=>p.type==='capture').length);
            await shutter.tap();
            await panel.waitFor({state:'hidden'});
            assert.equal(await page.evaluate(()=>posts.filter(p=>p.type==='capture').length),initialShots+1);
            await page.locator('#toggle').tap();
            await page.locator('[data-aspect-tile]').tap();
            assert.equal(await panel.getAttribute('data-picker'),'宽高比');
            const positions=()=>page.evaluate(()=>['#shutter','.capture-tools'].map(s=>document.querySelector(s).getBoundingClientRect().y));
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));const beforeAspect=await positions();
            async function checkOffset(delta){await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));const next=await positions();next.forEach((y,i)=>assert.ok(Math.abs(y-beforeAspect[i]-delta)<1,JSON.stringify({next,beforeAspect,delta}))) }
            async function checkFrame(top,bottom){
                await page.evaluate(()=>Promise.all(stage.getAnimations().map(a=>a.finished)));
                const [box,native]=await page.evaluate(()=>[stage.getBoundingClientRect().toJSON(),posts.filter(m=>m.type==='frame').at(-1)]);
                for(const [a,b] of [[box.x,native.x],[box.y,native.y],[box.width,native.w],[box.height,native.h]])assert.ok(Math.abs(a-b)<1);
                if(width===393){assert.ok(Math.abs(box.y*3-top)<1);assert.ok(Math.abs(box.bottom*3-bottom)<1)}
            }
            const frameCount=await page.evaluate(()=>posts.filter(m=>m.type==='frame').length);
            await panel.getByRole('button',{name:'1:1',exact:true}).tap();
            await checkOffset(0);
            assert.equal(await panel.locator('strong').textContent(),'1:1');
            await page.evaluate(()=>Promise.all(stage.getAnimations().map(a=>a.finished)));
            await checkFrame(503,1682);
            assert.equal(await page.evaluate(()=>posts.filter(m=>m.type==='frame').length),frameCount+1);
            await panel.getByRole('button',{name:'16:9',exact:true}).tap();await checkOffset(0);await checkFrame(166,2262);
            await panel.getByRole('button',{name:'4:3',exact:true}).tap();await checkOffset(0);
            for(const name of ['宽高比','曝光','格式','计时器','滤镜','夜间模式','闪光灯']){
                if(name==='计时器')await page.evaluate(()=>setControlRotation(90));
                if(name!=='宽高比')await page.evaluate(name=>chooseBottom(name,true),name);
                await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
                await page.evaluate(()=>{
                    const close=foldControls;window.closeSample=null;
                    foldControls=(...args)=>{
                        close(...args);
                        const motion=sheetMotion;
                        const time=motion.currentTime;
                        for(const progress of [0,.5,.99]){
                            motion.currentTime=motion.effect.getTiming().duration*progress;
                        }
                        motion.currentTime=motion.effect.getTiming().duration;
                        const end=selector.getBoundingClientRect(),photo=window.renderedModeCapsule();
                        const matches=['x','y','width','height'].every(k=>Math.abs(end[k]-photo[k])<1);
                        motion.currentTime=time;
                        window.closeSample=[footer.classList.contains('settling-home'),getComputedStyle(shootRow).getPropertyValue('--control-lift').trim(),matches];
                        foldControls=close
                    }
                });
                await page.touchscreen.tap(2,8);
                await page.waitForFunction(()=>window.closeSample!==null,null,{timeout:2000});
                assert.deepEqual(await page.evaluate(()=>window.closeSample),[true,'0px',true],name+' must collapse into Photo while controls return');
                await panel.waitFor({state:'hidden'});
                await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
                assert.deepEqual(await controlBoxes(),baseline,name+' blank-tap return')
            }
            await page.evaluate(()=>setControlRotation(0));
            for(const entry of ['selected filter','shortcut','hardware']){
                const result=await page.evaluate(entry=>{
                    const count=()=>posts.filter(p=>p.type==='capture').length;
                    const before=count();
                    chooseBottom('滤镜',true);
                    if(entry==='selected filter'){
                        selector.querySelector('[data-brand="sony"]').click();
                        selector.querySelector('.rail-track [aria-pressed=true]').click()
                    }
                    else if(entry==='shortcut')filterShortcut.click();
                    else window.hardwareShutter();
                    return [folding,count()-before]
                },entry);
                assert.deepEqual(result,[true,entry==='hardware'?1:0],entry+' dismissal');
                await panel.waitFor({state:'hidden'})
            }
            await page.evaluate(()=>chooseBottom('宽高比',true));
            const hasExpansion=await page.evaluate(()=>{selector.querySelector('.return').click();return drawer.getAnimations().some(a=>a.effect.getKeyframes().length===25)});
            assert.equal(hasExpansion,true);
            await page.locator('.tilegrid button').filter({hasText:'格式'}).tap();
            console.log('PASS '+width+'pt: four zoom stops center within 1pt; panel at y='+panelBox.y+' h='+panelBox.height+'; shutter captures once');
            await page.locator('.format-row button').filter({hasText:'RAW'}).tap();
            await page.evaluate(()=>leavePicker());await page.locator('#filters').tap();
            await page.locator('.filter-brands button[data-brand="sony"]').tap();
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            assert.deepEqual(await controlBoxes(),baseline,'filter controls match original 4:3');
            assert.equal(await page.evaluate(()=>shootRow.inert&&Number(getComputedStyle(shootRow).opacity)===1),true);
            const filterBox=await panel.boundingBox();assert.ok(filterBox.y+filterBox.height>height-48);
            const railInfo=await page.evaluate(()=>{
                const tile=document.querySelector('.rail-track canvas'),request=posts.filter(p=>p.type==='rail').at(-1);
                return {edge:request.edge,expected:Math.min(384,Math.max(96,Math.ceil(tile.getBoundingClientRect().width*devicePixelRatio)))}
            });
            assert.equal(railInfo.edge,railInfo.expected);
            await page.evaluate(()=>{document.querySelector('#filters').click();document.querySelector('#filters').click()});
            await page.evaluate(()=>Promise.all(selector.getAnimations().map(a=>a.finished)));
            assert.equal(await panel.getAttribute('data-brand'),'sony','reversing an unfinished close preserves the open rail');
            assert.equal(await page.evaluate(()=>posts.filter(p=>p.type==='rail').at(-1).open),true,'reversed close resumes native previews');
            assert.equal(await page.locator('.rail-track').isVisible(),true);
            console.log('PASS rail requests '+railInfo.edge+'px at '+width+'pt and can reopen during dismissal');
            await page.locator('.rail-track button').nth(1).evaluate(button=>button.click());
            await page.evaluate(()=>{leavePicker();get('shutter').click()});
            const shot=await page.evaluate(()=>posts.filter(m=>m.type==='capture').at(-1));
            assert.ok(shot?.codec==='RAW'&&shot.mp===12&&shot.look==='FL2',JSON.stringify(shot));assert.deepEqual(errors,[]);
            if(process.env.UI_SCREEN_DIR)await page.screenshot({path:path.join(process.env.UI_SCREEN_DIR,'camera-'+width+'.png')});
            console.log('PASS '+width+'x'+height+' @3x, full viewport, zoom scale 1, elastic grip, RAW 12 MP + FL2');
            if(width===393){
                const feedback=await page.evaluate(async()=>{
                    function thumbnail(color){
                        const c=document.createElement('canvas');c.width=c.height=8;const ctx=c.getContext('2d');
                        ctx.fillStyle=color;ctx.fillRect(0,0,8,8);return c.toDataURL('image/jpeg').split(',')[1]
                    }
                    const first=thumbnail('red'),second=thumbnail('blue'),album=get('album'),flash=document.querySelector('.save-flash');
                    await window.receiveSavedThumbnail('restored',first,false);
                    const quiet=flash.getAnimations().length===0&&album.getAnimations().length===0;
                    const older=window.receiveSavedThumbnail('saved-1',first,true);
                    const newer=window.receiveSavedThumbnail('saved-2',second,true);
                    const exposure=flash.getAnimations().at(-1);
                    if(exposure?.effect.getTiming().duration!==320)throw Error('save flash duration');
                    const during=flash.getAnimations().length>0&&album.getAnimations().length===0&&album.style.backgroundImage.includes(first);
                    await Promise.all([older,newer]);
                    const pulse=album.getAnimations()[0];
                    await window.receiveSavedThumbnail('saved-2',second,true);
                    return [quiet,during,!!pulse&&album.getAnimations()[0]===pulse,album.style.backgroundImage.includes(second),flash.getAnimations().length===0]
                });
                assert.deepEqual(feedback,[true,true,true,true,true]);
                await page.emulateMedia({reducedMotion:'reduce'});
                assert.ok(await page.evaluate(async()=>{await window.receiveSavedThumbnail('reduced','',true);return !get('album').getAnimations().length&&!document.querySelector('.save-flash').getAnimations().length}));
                console.log('PASS save feedback order, latest photo wins, no replay after restore or duplicate, reduced motion');
                await page.evaluate(()=>{get('toggle').click();get('toggle').click()});
                assert.equal(await page.locator('#panel').isVisible(),false);
                await page.goto(pathToFileURL(path.join(__dirname,'..','Stilltone-Album.html')).href);
                await verifyLutPixels(page,false);
                const png=await page.evaluate(()=>{
                    const c=document.createElement('canvas');c.width=1600;c.height=1200;
                    const ctx=c.getContext('2d');ctx.fillStyle='rgb(144,72,32)';ctx.fillRect(0,0,c.width,c.height);
                    return c.toDataURL().split(',')[1]
                });
                const chooser=page.waitForEvent('filechooser');
                await page.getByRole('button',{name:'＋ 导入'}).click();
                await (await chooser).setFiles({name:'photo.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});
                await page.waitForFunction(()=>document.querySelector('.viewer canvas')?.width===1179);
                await page.getByRole('button',{name:'滤镜',exact:true}).click();
                await page.waitForFunction(()=>[...document.querySelectorAll('.look-track canvas')].length===31&&[...document.querySelectorAll('.look-track canvas')].every(c=>c.height>=Math.ceil(c.clientWidth*devicePixelRatio)-1));
                assert.deepEqual(errors,[]);
                console.log('PASS 1600x1200 photo settles to 1179px, all 31 editor choices have Retina backing');
            }
            await context.close()
        }
    }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
