const assert = require('node:assert/strict');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium, webkit} = require('playwright-core');

const profiles = [
    [320,568,0,0,0,0], [375,667,0,0,0,0], [414,736,0,0,0,0],
    [375,812,50,0,34,0], [390,844,47,0,34,0], [393,852,59,0,34,0],
    [402,874,62,0,34,0], [414,896,44,0,34,0], [430,932,59,0,34,0], [440,956,62,0,34,0],
    [852,393,0,59,21,59], [874,402,0,62,21,62], [956,440,0,62,21,62]
];

async function checkDevice(browser,[width,height,top,right,bottom,left]) {
    const context = await browser.newContext({
        viewport:{width,height},deviceScaleFactor:3,isMobile:true,hasTouch:true,reducedMotion:'reduce'
    });
    try {
        const page = await context.newPage();
        await page.addInitScript(()=>{
            window.framesSent=[];
            Object.defineProperty(window,'webkit',{configurable:true,value:{messageHandlers:{
                camera:{postMessage(message){if(message.type==='frame')framesSent.push(message)}}
            }}});
        });
        await page.goto(pathToFileURL(path.join(__dirname,'..','FL-Camera-Review.html')).href);
        await page.evaluate(values=>{
            const phone=document.querySelector('.phone');
            for(const [index,side] of ['top','right','bottom','left'].entries()){
                phone.style.setProperty('--safe-'+side,values[index]+'px');
            }
            receiveCamera({ready:true,busy:false,formats:['HEIF','RAW'],sizes:[12,48],lenses:[.5,1,2,3],zoom:1,flash:true,live:true});
        },[top,right,bottom,left]);
        async function verifyHits(selector){
            const misses=await page.locator(selector).evaluateAll(buttons=>buttons.filter(button=>{
                const r=button.getBoundingClientRect();
                if(button.disabled||!r.width||!r.height||getComputedStyle(button).visibility!=='visible')return false;
                return !button.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2))
            }).map(button=>button.getAttribute('aria-label')||button.id||button.textContent));
            assert.deepEqual(misses,[],width+'x'+height+' missed touch targets: '+selector)
        }
        await verifyHits('#shutter,#toggle,#album,#flip,.capture-tools button,.phone .top button');
        const format=await page.locator('.format-shortcut').boundingBox();
        assert.ok(format.width>=44&&format.height>=44);
        const label=await page.locator('.mode button[aria-pressed=true]>.control-label').evaluate(element=>{
            const style=getComputedStyle(element);
            return [element.textContent,style.color,style.fontSize];
        });
        assert.deepEqual(label,['照片','rgb(255, 214, 10)','15px']);
        for(const aspect of ['4:3','16:9','1:1']){
            await page.evaluate(aspect=>{
                chooseBottom('宽高比',true);
                [...selector.querySelectorAll('button')].find(button=>button.textContent===aspect).click();
                leavePicker();refresh()
            },aspect);
            const {rect,menu,frame,grid}=await page.evaluate(()=>({
                rect:stage.getBoundingClientRect().toJSON(),menu:modeStrip.getBoundingClientRect().toJSON(),
                frame:framesSent.at(-1),grid:stage.querySelector('.guides').getBoundingClientRect().toJSON()
            }));
            const [a,b]=aspect.split(':').map(Number);
            const expected=width<height?b/a:a/b;
            assert.ok(Math.abs(rect.width-rect.height*expected)<1,width+' '+aspect+' aspect');
            assert.ok(rect.left>=left-.1&&rect.right<=width-right+.1&&rect.bottom<=height-bottom+.1);
            if(width<height)assert.ok(rect.bottom<=menu.top+.1,width+' '+aspect+' overlaps mode buttons');
            for(const [key,nativeKey] of [['x','x'],['y','y'],['width','w'],['height','h']]){
                assert.ok(Math.abs(rect[key]-frame[nativeKey])<1,'native '+key);
                if(grid.width>0)assert.ok(Math.abs(rect[key]-grid[key])<1,'grid '+key);
            }
            if(width===393&&height===852&&aspect!=='4:3'){
                const bounds=aspect==='1:1'?[503,1682]:[166,2262];
                assert.ok(Math.abs(3*rect.top-bounds[0])<1&&Math.abs(3*rect.bottom-bounds[1])<1);
            }
        }
        await page.locator('#toggle').tap();await verifyHits('#panel .tilegrid button');
        await page.evaluate(()=>leavePicker());
        await page.locator('.format-shortcut').tap();await verifyHits('.format-row button,.bottom-selector .return,#shutter');
        await page.evaluate(()=>leavePicker());
        for(const rotation of [0,90,-90]){
            await page.evaluate(rotation=>receiveCamera({...window.nativeCameraState,controlRotation:rotation}),rotation);
            await page.locator('#filters').tap();await verifyHits('.bottom-selector .return');
            const panel=await page.locator('.bottom-selector').boundingBox();
            assert.ok(panel.x>=left-.1&&panel.x+panel.width<=width-right+.1&&panel.y+panel.height<=height-bottom+.1);
            await page.evaluate(()=>leavePicker());
        }
        console.log('PASS '+width+'x'+height+' preview, guide, controls, menus and safe insets');
    } finally { await context.close() }
}

(async()=>{
    const options=process.env.CHROME_EXE?{executablePath:process.env.CHROME_EXE}:{};
    const browser=await (options.executablePath?chromium:webkit).launch({headless:true,...options});
    try{for(const profile of profiles)await checkDevice(browser,profile)}finally{await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
