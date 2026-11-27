const assert=require('node:assert/strict');

async function verifyVideoLayout(page){
    const report=patch=>page.evaluate(p=>window.receiveCamera({...window.nativeCameraState,...p}),patch);
    const last=type=>page.evaluate(type=>posts.filter(m=>m.type===type).at(-1),type);
    const shutter=page.locator('#shutter'),mode=page.locator('.mode');
    const photo=mode.getByRole('button',{name:'照片',exact:true}),video=mode.getByRole('button',{name:'视频',exact:true});
    const base={ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],live:true,flash:true,
        lenses:[.5,1,2,3],zoom:1,zoomTarget:1,inputRevision:1,zoomRequestID:0,
        videoMode:false,videoChoices:{HD:[24,30,60],'4K':[24,30]},videoResolution:'HD',videoFPS:30,
        videoState:'idle',videoTorchAvailable:true,videoMotionAvailable:true,videoElapsed:0};
    const centered=()=>page.waitForFunction(()=>{
        const capsule=document.querySelector('.mode').getBoundingClientRect(),choice=document.querySelector('.mode button[aria-pressed=true]').getBoundingClientRect();
        return Math.abs(capsule.x+capsule.width/2-choice.x-choice.width/2)<1
    },null,{timeout:2500});
    await report(base);await centered();
    const photoBox=await photo.boundingBox(),cx=photoBox.x+photoBox.width/2,cy=photoBox.y+photoBox.height/2;
    await page.mouse.move(cx,cy);await page.mouse.down();await page.mouse.move(cx+35,cy,{steps:5});await page.mouse.up();
    assert.deepEqual(await last('videoMode'),{type:'videoMode',enabled:true});
    assert.equal(await photo.getAttribute('aria-pressed'),'true');
    await report({videoMode:true});await centered();assert.equal(await video.getAttribute('aria-pressed'),'true');
    assert.equal(await shutter.evaluate(b=>getComputedStyle(b,'::before').backgroundColor),'rgb(255, 69, 58)');
    assert.equal(await page.evaluate(()=>aspect),'16:9');
    const size=page.viewportSize(),portrait=size.height>size.width;
    const shotBox=await shutter.boundingBox();
    if(portrait){
        await page.waitForFunction(()=>{const r=stage.getBoundingClientRect();return Math.abs(r.width/r.height-9/16)<.003});
        const frame=await page.locator('.stage:not([aria-hidden])').boundingBox(),top=await page.locator('.format-shortcut').boundingBox();
        assert.ok(top.y>=frame.y-2&&top.y+top.height<frame.y+65,'format shortcut is at top of viewfinder')
    }
    await report({controlRotation:90});
    await page.waitForFunction(()=>{
        const icon=document.querySelector('.video-motion-shortcut');
        return [getComputedStyle(icon.querySelector('svg')).rotate,getComputedStyle(icon,'::after').rotate].every(a=>Math.abs(parseFloat(a)-90)<.1)
    });
    await report({controlRotation:0});
    await page.locator('.format-shortcut').tap();
    const picker=page.locator('.bottom-selector');
    await picker.getByRole('group',{name:'分辨率'}).getByRole('button',{name:'4K'}).tap();
    assert.deepEqual(await last('videoFormat'),{type:'videoFormat',resolution:'4K',fps:30});
    await report({videoResolution:'4K'});
    assert.equal(await picker.getByRole('group',{name:'帧速率'}).getByRole('button',{name:'60'}).isDisabled(),true);
    const fps=await picker.getByRole('group',{name:'帧速率'}).locator('button').evaluateAll(bs=>bs.map(b=>b.getBoundingClientRect().y));
    assert.ok(Math.max(...fps)-Math.min(...fps)<1,'all three frame rates share a row');
    await picker.getByRole('button',{name:'返回拍摄控制'}).tap();
    const tiles=await page.locator('#panel .tilegrid button:visible').evaluateAll(bs=>bs.map(b=>[b.dataset.movieTile,b.getBoundingClientRect().y]));
    assert.deepEqual(tiles.map(([name])=>name).sort(),['闪光灯','曝光','运动','格式','滤镜'].sort());
    const rowY=Object.fromEntries(tiles);
    assert.ok(Math.abs(rowY['闪光灯']-rowY['曝光'])<1&&Math.abs(rowY['闪光灯']-rowY['运动'])<1&&Math.abs(rowY['滤镜']-rowY['格式'])<1&&rowY['格式']>rowY['曝光'],'video controls occupy two rows');
    await page.locator('[data-movie-tile="滤镜"]').tap();
    await picker.getByRole('button',{name:'索尼',exact:true}).tap();
    await picker.getByRole('button',{name:'FL2',exact:true}).tap();
    await picker.getByRole('button',{name:'返回滤镜品牌'}).tap();
    await picker.getByRole('button',{name:'返回拍摄控制'}).tap();
    await page.evaluate(()=>foldControls(drawer));await page.waitForFunction(()=>drawer.hidden);
    await shutter.tap();assert.deepEqual(await last('videoStart'),{type:'videoStart'});
    await report({videoState:'authorizing'});assert.equal(await page.locator('.video-clock').isVisible(),false);
    await report({videoState:'recording',videoElapsed:62});assert.equal(await page.locator('.video-clock').innerText(),'00:01:02');
    const pause=page.getByRole('button',{name:'暂停录像'}),snapshot=page.getByRole('button',{name:'录像中抓拍照片'});
    const [left,center,right]=await Promise.all([pause.boundingBox(),shutter.boundingBox(),snapshot.boundingBox()]);
    assert.ok(Math.abs(shotBox.x-center.x)<1&&Math.abs(shotBox.y-center.y)<5,'stop button remains at the record button');
    const clock=await page.locator('.video-clock').boundingBox();
    assert.ok(Math.abs(clock.x+clock.width/2-size.width/2)<1,'elapsed time is centered');
    assert.ok(left.width>=44&&right.width>=44&&left.x+left.width<center.x&&right.x>center.x+center.width,'pause, stop and snapshot have separate hit regions');
    assert.ok(Math.abs(left.y+left.height/2-center.y-center.height/2)<2&&Math.abs(right.y+right.height/2-center.y-center.height/2)<2,'shoot row is aligned');
    await snapshot.tap();assert.deepEqual(await last('videoSnapshot'),{type:'videoSnapshot'});
    await pause.tap();assert.deepEqual(await last('videoPause'),{type:'videoPause',paused:true});
    await report({videoState:'paused'});await page.getByRole('button',{name:'继续录像'}).tap();
    assert.deepEqual(await last('videoPause'),{type:'videoPause',paused:false});
    await report({videoState:'recording'});await shutter.tap();assert.deepEqual(await last('videoStop'),{type:'videoStop'});
    await report({videoState:'idle'});await photo.tap();assert.deepEqual(await last('videoMode'),{type:'videoMode',enabled:false});
    await report({videoMode:false});await centered();
    assert.equal(await page.evaluate(()=>aspect),'4:3');assert.equal(await page.evaluate(()=>get('look').value),'FL2');
    console.log('PASS video viewport '+page.viewportSize().width+'x'+page.viewportSize().height+' switch, format, filter, pause, resume, snapshot and stop')
}
module.exports={verifyVideoLayout};
