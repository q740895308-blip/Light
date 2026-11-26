const assert = require('node:assert/strict');

async function verifyFilterFirstFrame(page) {
    const names = ['original','FL2','FL3','GR-Positive','Classic-Negative','Nostalgic-Negative','Classic-Chrome'];
    const first = [[180,40,65],[55,160,110],[55,72,195],[192,162,68],[45,150,180],[162,65,165],[185,100,45]];
    const second = first.slice(2).concat(first.slice(0,2));
    await page.evaluate(({names,first,second}) => {
        const nativeDecode = HTMLImageElement.prototype.decode;
        let decodeGate;
        HTMLImageElement.prototype.decode = function() {
            const gate = decodeGate;
            return nativeDecode.call(this).then(() => gate);
        };
        const atlas = colors => {
            const canvas=document.createElement('canvas');
            canvas.width=96*colors.length;canvas.height=96;
            const drawing=canvas.getContext('2d');
            colors.forEach((rgb,index) => {
                drawing.fillStyle='rgb('+rgb.join(',')+')';drawing.fillRect(index*96,0,96,96);
            });
            return canvas.toDataURL('image/jpeg',.98).split(',')[1];
        };
        const inputs=[atlas(first),atlas(second)];
        let releaseDecode,delivery;
        window.filterProbe={
            version:() => window.posts.filter(p=>p.type==='rail'&&p.open).at(-1)?.version,
            deliver:(index,version) => window.receiveThumbs(inputs[index],names,version),
            start:(index,version) => {
                decodeGate=new Promise(resolve=>{releaseDecode=resolve});
                delivery=window.receiveThumbs(inputs[index],names,version);
            },
            finish:async() => {releaseDecode();decodeGate=undefined;await delivery},
            view:() => {
                const track=document.querySelector('.bottom-selector .rail-track');
                return {busy:track?.getAttribute('aria-busy'),tiles:[...(track?.querySelectorAll('canvas[data-look]')||[])].map(canvas=>{
                    const rgb=Array.from(canvas.getContext('2d').getImageData(canvas.width>>1,canvas.height>>1,1,1).data);
                    const holder=canvas.closest('.rail-image'),bounds=holder?.getBoundingClientRect();
                    const placeholder=holder&&bounds.width>0&&bounds.height>0&&getComputedStyle(holder).backgroundColor;
                    let visible=canvas.getClientRects().length>0&&getComputedStyle(canvas).visibility==='visible';
                    for(let el=canvas;visible&&el;el=el.parentElement)visible=getComputedStyle(el).opacity!=='0';
                    return {look:canvas.dataset.look,rgb,visible,placeholder};
                })};
            }
        };
        window.receiveCamera({ready:true,busy:false,inputRevision:1,formats:['HEIF'],sizes:[12],
            lenses:[1,2],zoom:1,flash:true,live:true,biasLimits:[-3,3]});
    },{names,first,second});
    const view=()=>page.evaluate(()=>window.filterProbe.view());
    const afterFade=()=>page.evaluate(async()=>{
        await new Promise(requestAnimationFrame);
        const canvases=document.querySelectorAll('.rail-track canvas');
        await Promise.allSettled([...canvases].flatMap(el=>el.getAnimations().map(a=>a.finished)));
        return window.filterProbe.view();
    });
    const version=()=>page.evaluate(()=>window.filterProbe.version());
    const deliver=(index,version)=>page.evaluate(([index,version])=>window.filterProbe.deliver(index,version),[index,version]);
    const start=(index,version)=>page.evaluate(([index,version])=>window.filterProbe.start(index,version),[index,version]);
    const finish=()=>page.evaluate(()=>window.filterProbe.finish());
    function waiting(state,reason) {
        assert.deepEqual(state.tiles.map(tile=>tile.look),names,reason+' still lays out all seven tiles');
        assert.ok(state.tiles.every(tile=>!tile.visible),reason+' exposed an empty or stale canvas');
        assert.ok(state.tiles.every(tile=>tile.placeholder==='rgb(72, 72, 74)'),reason+' missing opaque placeholder');
        assert.equal(state.busy,'true',reason+' missing loading state');
    }
    function showing(state,colors,reason) {
        assert.deepEqual(state.tiles.map(tile=>tile.look),names,reason+' filter order');
        state.tiles.forEach((tile,i)=>{
            assert.ok(tile.visible&&tile.rgb[3]===255&&colors[i].every((value,j)=>Math.abs(tile.rgb[j]-value)<=5),
                reason+' '+tile.look+' '+JSON.stringify(tile));
        });
        assert.equal(state.busy,'false',reason+' did not clear loading state');
    }
    const open=()=>page.evaluate(()=>{get('filters').click();return window.filterProbe.view()});
    const dismiss=()=>page.touchscreen.tap(2,8);
    const closed=()=>page.locator('.bottom-selector').waitFor({state:'hidden'});
    const setState=changes=>page.evaluate(changes=>window.receiveCamera({...window.nativeCameraState,...changes}),changes);
    const background=hidden=>page.evaluate(hidden=>{
        Object.defineProperty(document,'hidden',{configurable:true,get:()=>hidden});
        Object.defineProperty(document,'visibilityState',{configurable:true,get:()=>hidden?'hidden':'visible'});
        document.dispatchEvent(new Event('visibilitychange'));
    },hidden);

    waiting(await open(),'first opening');
    const initial=await version();
    await start(0,initial);waiting(await view(),'while decoding');await finish();
    showing(await afterFade(),first,'first decoded atlas');

    await start(1,initial);
    await dismiss();await finish();
    assert.ok((await view()).tiles.every(tile=>!tile.visible),'closing showed thumbnail content');
    await closed();
    showing(await open(),first,'warm opening before the next decode');
    const reopened=await version();assert.notEqual(reopened,initial);
    await deliver(1,initial);showing(await view(),first,'late delivery from the closed menu');
    await start(1,reopened);showing(await view(),first,'warm refresh decoding');
    await finish();showing(await view(),second,'refreshed atlas');

    for(const [changes,label] of [[{inputRevision:2,front:true},'front camera'],[{inputRevision:3,front:false},'return to rear camera']]){
        const old=await version();await start(0,old);await setState(changes);
        waiting(await view(),label);await finish();waiting(await view(),label+' late decode');
        const current=await version();assert.notEqual(current,old);
        await deliver(1,current);showing(await afterFade(),second,label+' new capture');
    }
    const foreground=await version();
    await start(0,foreground);await background(true);await finish();
    await background(false);waiting(await view(),'foreground return');
    const resumed=await version();assert.notEqual(resumed,foreground);
    await deliver(0,foreground);waiting(await view(),'previous foreground delivery');
    await deliver(0,resumed);showing(await afterFade(),first,'new foreground capture');
    await dismiss();await closed();await page.locator('#album').tap();
    assert.equal(await page.evaluate(()=>window.posts.filter(p=>p.type==='album').length),1);
    await setState({ready:false});await setState({ready:true});
    waiting(await open(),'native album dismissal');
    const afterAlbum=await version();assert.notEqual(afterAlbum,resumed);
    await deliver(1,resumed);waiting(await view(),'previous album delivery');
    await deliver(1,afterAlbum);showing(await afterFade(),second,'capture after album dismissal');
    await dismiss();await closed();
    await page.waitForTimeout(2600);
    waiting(await open(),'expired last capture');
    await dismiss();await closed();
    console.log('PASS filter opening, pending decode, warm re-entry, camera flips, foreground return and all seven decoded colors');
}

module.exports={verifyFilterFirstFrame};
