const assert=require('node:assert/strict');

async function verifyMenuDismissal(page){
    const drawer=page.locator('#panel'), picker=page.locator('.bottom-selector');
    const toggle=page.locator('#toggle');
    await page.evaluate(()=>{
        window.receiveCamera({...window.nativeCameraState,autoFlash:true});
        window.renderedModeCapsule=()=>{
            const strip=modeStrip.getBoundingClientRect(),pill=getComputedStyle(modeStrip,'::before');
            const transform=new DOMMatrixReadOnly(pill.transform);
            return {x:strip.x+modeStrip.clientLeft+parseFloat(pill.left)+transform.m41,
                y:strip.y+modeStrip.clientTop+parseFloat(pill.top)+transform.m42,
                width:parseFloat(pill.width),height:parseFloat(pill.height)}
        }
    });

    async function open(name){
        await toggle.tap();
        await drawer.waitFor({state:'visible'});
        if(!name)return drawer;
        await drawer.locator('.tilegrid button').filter({hasText:name}).tap();
        assert.equal(await picker.getAttribute('data-picker'),name);
        return picker
    }
    async function inspectClose(name,trigger){
        // Pause the animation synchronously on the input path, before the next paint.
        await page.evaluate(()=>{
            const original=foldControls;
            window.menuSample=null;
            foldControls=(...args)=>{
                foldControls=original;
                original(...args);
                const motion=sheetMotion;
                if(!motion){window.menuSample={error:'no close animation'};return}
                motion.pause();
                const panel=motion.effect.target;
                const originalWidth=panel.offsetWidth,originalHeight=panel.offsetHeight;
                const samples=[];
                for(const progress of [0,.45,.82,1]){
                    motion.currentTime=motion.effect.getTiming().duration*progress;
                    const style=getComputedStyle(panel), box=panel.getBoundingClientRect();
                    const visible=[...panel.querySelectorAll('*')].find(el=>{
                        if(!el.getClientRects().length||getComputedStyle(el).visibility!=='visible')return false;
                        for(let node=el;node!==panel;node=node.parentElement)if(getComputedStyle(node).opacity==='0')return false;
                        return true
                    });
                    const radii=['borderTopLeftRadius','borderTopRightRadius','borderBottomLeftRadius','borderBottomRightRadius'].map(key=>{
                        const [x,y=x]=style[key].split(' ').map(parseFloat);
                        return [x*box.width/originalWidth,y*box.height/originalHeight]
                    });
                    samples.push({progress,opacity:style.opacity,visibility:style.visibility,background:style.backgroundColor,
                        visible:visible?.tagName||null,box:box.toJSON(),radii});
                }
                window.menuSample={samples,target:window.renderedModeCapsule()};
                motion.finish()
            }
        });
        await trigger();
        await page.waitForFunction(()=>window.menuSample!==null,null,{timeout:2500});
        const {samples,target,error}=await page.evaluate(()=>window.menuSample);
        assert.ok(!error,name+': '+error);
        for(const sample of samples){
            assert.equal(sample.visible,null,name+' still drawing '+sample.visible+' at '+sample.progress);
            assert.ok(sample.opacity==='1'&&sample.visibility==='visible'&&!['transparent','rgba(0, 0, 0, 0)'].includes(sample.background),name+' empty shell disappeared');
        }
        const end=samples.at(-1);
        for(const key of ['x','y','width','height'])assert.ok(Math.abs(end.box[key]-target[key])<1.1,name+' dock '+key+' '+JSON.stringify({actual:end.box,target}));
        for(const corner of end.radii)for(const radius of corner)assert.ok(Math.abs(radius-target.height/2)<1.4,name+' flattened corner '+JSON.stringify({corner,target}));
        await (name==='六点'?drawer:picker).waitFor({state:'hidden'});
        await page.waitForFunction(()=>!modeStrip.classList.contains('dock-rebound'))
    }
    for(const name of ['六点','宽高比','曝光','格式','计时器','夜间模式','闪光灯','滤镜']){
        await open(name==='六点'?null:name);
        await inspectClose(name,()=>page.touchscreen.tap(2,8))
    }
    for(const [id,name] of [['#filters','滤镜'],['.format-shortcut','格式']]){
        await page.locator(id).tap();
        await inspectClose(name,()=>page.locator(id).tap())
    }
    await open('格式');await picker.locator('.return').tap();
    await drawer.waitFor({state:'visible'});
    assert.ok(await picker.isHidden());
    assert.equal(await page.evaluate(()=>modeStrip.classList.contains('dock-rebound')),false);
    await page.touchscreen.tap(2,8);await drawer.waitFor({state:'hidden'});
    await page.emulateMedia({reducedMotion:'reduce'});
    await open('宽高比');await page.touchscreen.tap(2,8);
    assert.ok(await picker.isHidden());assert.equal(await page.evaluate(()=>!!sheetMotion||modeStrip.classList.contains('dock-rebound')),false);
    await page.emulateMedia({reducedMotion:'no-preference'});
    console.log('PASS actual menu and shortcut dismissals, hidden contents, opaque shell, capsule radii, return and reduced motion')
}
module.exports={verifyMenuDismissal};
