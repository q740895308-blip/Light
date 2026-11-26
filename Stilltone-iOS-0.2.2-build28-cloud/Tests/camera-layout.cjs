const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const {chromium,webkit}=require('playwright-core');
(async()=>{
    const engine=process.env.CHROME_EXE?chromium:webkit;
    const browser=await engine.launch({headless:true,...(process.env.CHROME_EXE?{executablePath:process.env.CHROME_EXE}:{})});
    try {
        for(const [width,height] of [[393,852],[852,393]]){
            const context=await browser.newContext({viewport:{width,height},deviceScaleFactor:3,isMobile:true,hasTouch:true});
            const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
            await page.addInitScript(()=>{window.posts=[];Object.defineProperty(window,'webkit',{configurable:true,value:{messageHandlers:{camera:{postMessage:m=>window.posts.push(m)}}}})});
            await page.goto(pathToFileURL(path.join(__dirname,'..','FL-Camera-Review.html')).href);
            await page.evaluate(()=>window.receiveCamera({ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],lenses:[.5,1,2,3],zoom:1,flash:true,live:true,biasLimits:[-3,3]}));
            async function checkZoom(value){
                await page.locator('[data-step="'+value+'"]').tap();
                assert.equal(await page.evaluate(()=>posts.filter(m=>m.type==='zoom').at(-1).value),value);
                assert.equal(await page.evaluate(()=>tools.style.getPropertyValue('--active-slot')),String([.5,1,2,3].indexOf(value)));
                await page.evaluate(zoom=>window.receiveCamera({...window.nativeCameraState,zoom}),value);
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
            await page.touchscreen.tap(2,8);await page.touchscreen.tap(2,8);
            assert.equal(await page.evaluate(()=>visualViewport.scale),1);
            for(const value of [.5,3,2,1])await checkZoom(value);
            await page.evaluate(()=>Promise.all(tools.getAnimations().map(a=>a.finished)));const baseline=await controlBoxes();await page.locator('#toggle').tap();const grip=page.locator('.drawer-grip');await grip.waitFor();
            await page.evaluate(()=>Promise.all(document.querySelector('#panel').getAnimations().map(a=>a.finished)));
            const closing=await page.evaluate(()=>{
                foldControls(drawer);const animation=sheetMotion;animation.pause();animation.currentTime=animation.effect.getTiming().duration;
                for(const progress of [0,.5,1]){
                    animation.currentTime=animation.effect.getTiming().duration*progress;
                    if(getComputedStyle(tools).visibility!=='hidden')throw Error('zoom showing above drawer')
                }
                const box=drawer.getBoundingClientRect(),target=modeButtons[1].getBoundingClientRect();
                const distance=Math.hypot(box.x+box.width/2-target.x-target.width/2,box.y+box.height/2-target.y-target.height/2);
                stopSheetMotion();return distance
            });assert.ok(closing<2,'menu close target: '+closing);
            const box=await grip.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
            const before=(await page.locator('#panel').boundingBox()).y;
            await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x,y+50,{steps:5});
            const delta=(await page.locator('#panel').boundingBox()).y-before;
            assert.ok(Math.abs(delta-50)<2,'drawer delta '+delta);await page.mouse.up();
            await page.evaluate(()=>{stopSheetMotion();drawer.style.transform='';leavePicker()});
            await page.locator('.format-shortcut').tap();assert.deepEqual(await page.locator('[aria-label="格式"] button').allTextContents(),['HEIF','RAW']);
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
            await shutter.tap();assert.equal(await panel.isVisible(),false);
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
            for(const name of ['宽高比','曝光','格式']){
                if(name!=='宽高比')await page.evaluate(name=>chooseBottom(name,true),name);
                await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
                await page.evaluate(()=>{
                    const close=foldControls;window.closeSample=null;
                    foldControls=(...args)=>{
                        close(...args);
                        window.closeSample=[footer.classList.contains('settling-home'),getComputedStyle(shootRow).getPropertyValue('--control-lift').trim()];
                        foldControls=close
                    }
                });
                await page.touchscreen.tap(2,8);
                await page.waitForFunction(()=>window.closeSample!==null,null,{timeout:2000});
                assert.deepEqual(await page.evaluate(()=>window.closeSample),[true,'0px'],name+' begins returning immediately');
                await panel.waitFor({state:'hidden'});
                await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
                assert.deepEqual(await controlBoxes(),baseline,name+' blank-tap return')
            }
            await page.evaluate(()=>chooseBottom('宽高比',true));
            const hasExpansion=await page.evaluate(()=>{selector.querySelector('.return').click();return drawer.getAnimations().some(a=>a.effect.getKeyframes().length===25)});
            assert.equal(hasExpansion,true);
            await page.locator('.tilegrid button').filter({hasText:'格式'}).tap();
            console.log('PASS '+width+'pt: four zoom stops center within 1pt; panel at y='+panelBox.y+' h='+panelBox.height+'; shutter captures once');
            await page.locator('.format-row button').filter({hasText:'RAW'}).tap();
            await page.evaluate(()=>leavePicker());await page.locator('#filters').tap();
            await page.evaluate(()=>Promise.all(shootRow.getAnimations().map(a=>a.finished)));
            assert.deepEqual(await controlBoxes(),baseline,'filter controls match original 4:3');
            assert.equal(await shutter.isVisible(),false);assert.equal(await page.locator('.capture-tools').isVisible(),false);
            const filterBox=await panel.boundingBox();assert.ok(filterBox.y+filterBox.height>height-48);
            const railInfo=await page.evaluate(()=>{
                const tile=document.querySelector('.rail-track canvas'),request=posts.filter(p=>p.type==='rail').at(-1);
                return {edge:request.edge,expected:Math.min(384,Math.max(96,Math.ceil(tile.getBoundingClientRect().width*devicePixelRatio)))}
            });
            assert.equal(railInfo.edge,railInfo.expected);
            await page.evaluate(()=>{document.querySelector('#filters').click();document.querySelector('#filters').click()});
            await page.evaluate(()=>Promise.all(selector.getAnimations().map(a=>a.finished)));
            assert.equal(await page.locator('.rail-track').isVisible(),true);
            console.log('PASS rail requests '+railInfo.edge+'px at '+width+'pt and can reopen during dismissal');
            await page.locator('.rail-track button').nth(1).evaluate(button=>button.click());
            await page.evaluate(()=>{leavePicker();get('shutter').click()});
            const shot=await page.evaluate(()=>posts.filter(m=>m.type==='capture').at(-1));
            assert.ok(shot?.codec==='RAW'&&shot.mp===12&&shot.look==='FL2',JSON.stringify(shot));assert.deepEqual(errors,[]);
            if(process.env.UI_SCREEN_DIR)await page.screenshot({path:path.join(process.env.UI_SCREEN_DIR,'camera-'+width+'.png')});
            console.log('PASS '+width+'x'+height+' @3x, full viewport, zoom scale 1, 50pt drawer drag, RAW 12 MP + FL2');
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
                await page.waitForFunction(()=>[...document.querySelectorAll('.look-track canvas')].length===7&&[...document.querySelectorAll('.look-track canvas')].every(c=>c.height>=Math.ceil(c.clientWidth*devicePixelRatio)-1));
                assert.deepEqual(errors,[]);
                console.log('PASS 1600x1200 photo settles to 1179px, all seven editor filters have Retina backing');
            }
            await context.close()
        }
    }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
