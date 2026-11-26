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

    const pill=await page.evaluate(()=>window.renderedModeCapsule());
    const left=Math.floor(pill.x),top=Math.floor(pill.y);
    const clip={x:left,y:top,width:Math.ceil(pill.x+pill.width)-left,height:Math.ceil(pill.y+pill.height)-top};
    async function yellowPixels(){
        const shot=await page.screenshot({clip});
        return page.evaluate(async base64=>{
            const image=new Image();image.src='data:image/png;base64,'+base64;await image.decode();
            const canvas=document.createElement('canvas');
            canvas.width=image.width;canvas.height=image.height;
            const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);
            const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data,mask=[];
            for(let i=0;i<rgba.length;i+=4){
                if(rgba[i]>180&&rgba[i+1]>145&&rgba[i+2]<75)mask.push(i/4)
            }
            return mask
        },shot.toString('base64'))
    }
    const baseline=new Set(await yellowPixels());
    assert.ok(baseline.size>20,'visible yellow Photo glyph at rest');
    async function checkPhoto(location){
        const pixels=await yellowPixels();
        const common=pixels.filter(offset=>baseline.has(offset)).length;
        const similarity=common/(baseline.size+pixels.length-common);
        assert.ok(similarity>.75,location+' yellow glyph mask differs: '+JSON.stringify({common,
            original:baseline.size,rendered:pixels.length,similarity}))
    }
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
        const samplePixels=name==='六点'||name==='曝光';
        await page.evaluate(hold=>{
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
                if(hold)motion.currentTime=0;else motion.finish()
            }
        },samplePixels);
        await trigger();
        await page.waitForFunction(()=>window.menuSample!==null,null,{timeout:2500});
        const {samples,target,error}=await page.evaluate(()=>window.menuSample);
        assert.ok(!error,name+': '+error);
        if(samplePixels){
            for(const fraction of [0,.5,1]){
                await page.evaluate(t=>{sheetMotion.currentTime=sheetMotion.effect.getTiming().duration*t},fraction);
                await checkPhoto(name+' at '+fraction)
            }
            await page.evaluate(()=>sheetMotion.finish())
        }
        for(const sample of samples){
            assert.equal(sample.visible,null,name+' still drawing '+sample.visible+' at '+sample.progress);
            assert.ok(sample.opacity==='1'&&sample.visibility==='visible'&&!['transparent','rgba(0, 0, 0, 0)'].includes(sample.background),name+' empty shell disappeared');
        }
        const end=samples.at(-1);
        for(const key of ['x','y','width','height'])assert.ok(Math.abs(end.box[key]-target[key])<1.1,name+' dock '+key+' '+JSON.stringify({actual:end.box,target}));
        for(const corner of end.radii)for(const radius of corner)assert.ok(Math.abs(radius-target.height/2)<1.4,name+' flattened corner '+JSON.stringify({corner,target}));
        await (name==='六点'?drawer:picker).waitFor({state:'hidden'});
        await page.waitForFunction(()=>!modeStrip.classList.contains('dock-rebound'))
        if(samplePixels){
            await checkPhoto(name+' after closing');
            const hide=await page.addStyleTag({content:'.mode button[aria-pressed=true] .control-label{visibility:hidden!important}'});
            try{assert.equal((await yellowPixels()).length,0,name+' duplicated the Photo glyph')}
            finally{await hide.evaluate(node=>node.remove())}
        }
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
