const assert = require('node:assert/strict');
const {verifyCoreImageGlass} = require('./menu-glass-core.cjs');

async function readPixels(page, clip) {
    const bytes = await page.screenshot({clip,scale:'css'});
    return page.evaluate(async base64 => {
        const img = new Image();
        img.src = 'data:image/png;base64,' + base64;
        await img.decode();
        const canvas = document.createElement('canvas');
        canvas.width = img.width; canvas.height = img.height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img,0,0);
        const pixels = ctx.getImageData(0,1,canvas.width,1).data;
        const rgb = [0,1,2].map(channel=>Array.from({length:canvas.width},(_,i)=>pixels[i*4+channel]));
        return {
            mean:rgb.map(row=>row.reduce((a,b)=>a+b,0)/row.length),
            ripple:Math.max(...rgb.flatMap(row=>row.slice(1).map((v,i)=>Math.abs(v-row[i]))))
        };
    },bytes.toString('base64'));
}

async function calibrateBackdrop(page) {
    const reference = await page.context().newPage();
    try {
        await reference.setContent('<meta name="viewport" content="width=device-width, initial-scale=1">' +
            '<style>body{margin:0}.scene{position:absolute;inset:0;background:repeating-linear-gradient(90deg,#ff1818 0 3px,#601818 3px 6px)}' +
            '.material{position:absolute;inset:40px;background:rgba(40,40,40,.4)}</style><div class="scene"></div><div class="material"></div>');
        const clip = {x:120,y:200,width:30,height:4};
        const sharp = await readPixels(reference,clip);
        await reference.addStyleTag({content:'.material{-webkit-backdrop-filter:blur(22px);backdrop-filter:blur(22px)}'});
        const frosted = await readPixels(reference,clip);
        assert.ok(sharp.ripple>30,'unable to resolve the reference stripes');
        console.log('Reference backdrop ripple (unfiltered, blurred):',sharp.ripple,frosted.ripple);
        return frosted.ripple < 12;
    } finally { await reference.close(); }
}

async function verifyMenuGlass(page) {
    const panel = page.locator('#panel');
    const picker = page.locator('.bottom-selector');
    if (process.platform === 'darwin') verifyCoreImageGlass();
    const checksBlurPixels = await calibrateBackdrop(page);
    await page.evaluate(() => {
        // Use controlled scene colours in the same stacking context as the material.
        const scene = document.createElement('div');
        scene.id = 'glass-test-scene';
        scene.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:7';
        footer.prepend(scene);
        window.receiveCamera({...window.nativeCameraState, autoFlash:true});
    });
    async function sample(sheet, color) {
        const clip = await sheet.evaluate((el, color) => {
            const scene = document.getElementById('glass-test-scene');
            scene.style.zIndex = String(Number(getComputedStyle(el).zIndex) - 1);
            const bright = color === 'red' ? '#ff1818' : '#1818ff';
            const dark = color === 'red' ? '#601818' : '#181860';
            scene.style.background = 'repeating-linear-gradient(90deg,' + bright + ' 0 3px,' + dark + ' 3px 6px)';
            const rect = el.getBoundingClientRect();
            return {x:Math.round(rect.left + rect.width * 0.26), y:Math.round(rect.top + 9), width:30, height:4};
        }, color);
        return readPixels(page,clip);
    }
    try {
        for (const kind of ['六点','宽高比','曝光','格式','计时器','夜间模式','闪光灯','滤镜']) {
            await page.locator('#toggle').tap();
            const sheet = kind === '六点' ? panel : picker;
            if (sheet === picker) await panel.locator('.tilegrid button').filter({hasText:kind}).tap();
            await sheet.evaluate(el => Promise.all(el.getAnimations().map(a=>a.finished)));
            const blur = await sheet.evaluate(el => {
                const css = getComputedStyle(el);
                return css.backdropFilter || css.webkitBackdropFilter;
            });
            assert.match(blur, /blur\([1-9]/, kind+' lacks an effective backdrop blur');
            const red = await sample(sheet,'red'), blue = await sample(sheet,'blue');
            assert.ok(red.mean[0] > blue.mean[0]+8 && blue.mean[2] > red.mean[2]+8,
                kind+' material did not transmit the scene colour '+JSON.stringify({red,blue}));
            if (checksBlurPixels) assert.ok(Math.max(red.ripple,blue.ripple)<12,
                kind+' transmitted sharp background stripes '+JSON.stringify({red,blue}));
            await page.touchscreen.tap(2,8);
            await sheet.waitFor({state:'hidden'});
        }
    } finally {
        await page.evaluate(()=>document.getElementById('glass-test-scene').remove());
    }
    console.log('PASS iPhone 14 Pro drawer and seven submenus transmit scene colours; ' +
        (checksBlurPixels ? 'fine-stripe blur verified in pixels' : 'headless compositor does not blur the independent CSS reference'));
    await verifyNativeScene(page);
}

async function verifyNativeScene(page) {
    const native = await page.context().newPage();
    try {
        await native.addInitScript(() => {
            window.glassRequests = 0;
            Object.defineProperty(window,'webkit',{configurable:true,value:{messageHandlers:{
                camera:{postMessage(){}},
                cameraGlass:{postMessage() {
                    window.glassRequests++;
                    return new Promise(resolve=>{window.replyToGlass = resolve});
                }}
            }}});
        });
        await native.goto(page.url());
        await native.evaluate(()=>{
            window.receiveCamera({ready:true,busy:false,formats:['HEIF'],sizes:[12],lenses:[1],zoom:1,flash:true,live:true});
            window.glassColor = color => {
                const canvas = document.createElement('canvas');
                canvas.width=16;canvas.height=16;
                const ctx = canvas.getContext('2d');
                ctx.fillStyle=color;ctx.fillRect(0,0,16,16);
                return canvas.toDataURL('image/jpeg').split(',')[1];
            };
        });
        const drawer = native.locator('#panel');
        await native.locator('#toggle').tap();
        await native.waitForFunction(()=>window.glassRequests===1);
        await drawer.evaluate(el=>Promise.all(el.getAnimations().map(a=>a.finished)));
        const clip = await drawer.evaluate(el=>{
            const rect=el.getBoundingClientRect(), bounds=document.querySelector('.stage[aria-hidden=true]').getBoundingClientRect();
            if(bounds.bottom < rect.top+12) throw Error('no viewfinder overlap for the native material test');
            return {x:Math.round(rect.left+rect.width*.26),y:Math.round(rect.top+9),width:30,height:4};
        });
        const colors=[];
        for (const [index,color] of ['red','blue'].entries()) {
            await native.waitForFunction(n=>window.glassRequests===n,index+1);
            await native.evaluate(color=>replyToGlass(glassColor(color)),color);
            await native.waitForFunction(color=>getComputedStyle(drawer).backgroundImage.includes(glassColor(color)),color);
            colors.push((await readPixels(native,clip)).mean);
        }
        const [red,blue]=colors;
        assert.ok(red[0]>blue[0]+12 && blue[2]>red[2]+12,'camera sample did not reach the displayed material '+JSON.stringify(colors));
        await native.waitForFunction(()=>window.glassRequests===3);
        await native.touchscreen.tap(2,8);
        await drawer.waitFor({state:'hidden'});
        await native.evaluate(()=>replyToGlass(glassColor('green')));
        await native.waitForTimeout(360); // More than two sampling periods.
        assert.deepEqual(await native.evaluate(()=>[glassRequests,drawer.style.getPropertyValue('--menu-scene')]),[3,'']);
        await native.locator('#toggle').tap();
        await native.waitForFunction(()=>window.glassRequests===4);
        await native.evaluate(()=>window.receiveCamera({...window.nativeCameraState,reduceTransparency:true}));
        await native.waitForFunction(()=>document.body.classList.contains('solid-menu-material'));
        await native.evaluate(()=>replyToGlass(glassColor('green')));
        await native.waitForTimeout(200);
        assert.deepEqual(await native.evaluate(()=>[glassRequests,drawer.style.getPropertyValue('--menu-scene')]),[4,'']);
        console.log('PASS live material bridge updates, rejects late samples, and stops when closed or transparency is reduced');
    } finally { await native.close(); }
}
module.exports = {verifyMenuGlass};
