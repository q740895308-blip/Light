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
            const geometry=await page.locator('.phone').boundingBox();
            assert.ok(Math.abs(geometry.width-width)<1&&Math.abs(geometry.height-height)<1,JSON.stringify(geometry));
            await page.touchscreen.tap(2,8);await page.touchscreen.tap(2,8);
            assert.equal(await page.evaluate(()=>visualViewport.scale),1);
            await page.locator('#toggle').tap();const grip=page.locator('.drawer-grip');await grip.waitFor();
            await page.evaluate(()=>Promise.all(document.querySelector('#panel').getAnimations().map(a=>a.finished)));
            const box=await grip.boundingBox();const x=box.x+box.width/2,y=box.y+box.height/2;
            const before=(await page.locator('#panel').boundingBox()).y;
            await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x,y+50,{steps:5});
            const delta=(await page.locator('#panel').boundingBox()).y-before;
            assert.ok(Math.abs(delta-50)<2,'drawer delta '+delta);await page.mouse.up();
            await page.evaluate(()=>{stopSheetMotion();drawer.style.transform='';leavePicker()});
            await page.locator('.format-shortcut').tap();assert.deepEqual(await page.locator('[aria-label="格式"] button').allTextContents(),['HEIF','RAW']);
            await page.locator('.format-row button').getByText('RAW',{exact:true}).count();
            await page.locator('.format-row button').filter({hasText:'RAW'}).tap();
            await page.evaluate(()=>leavePicker());await page.locator('#filters').tap();
            await page.locator('.rail-track button').nth(1).evaluate(button=>button.click());
            await page.evaluate(()=>{leavePicker();get('shutter').click()});
            const shot=await page.evaluate(()=>posts.filter(m=>m.type==='capture').at(-1));
            assert.ok(shot?.codec==='RAW'&&shot.mp===48&&shot.look==='FL2',JSON.stringify(shot));assert.deepEqual(errors,[]);
            if(process.env.UI_SCREEN_DIR)await page.screenshot({path:path.join(process.env.UI_SCREEN_DIR,'camera-'+width+'.png')});
            console.log('PASS '+width+'x'+height+' @3x, full viewport, zoom scale 1, 50pt drawer drag, RAW 48 MP + FL2');
            await context.close()
        }
    }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
