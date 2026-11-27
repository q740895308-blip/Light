const assert = require('node:assert/strict');

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
            window.glassMoves=[];
            Object.defineProperty(window,'webkit',{configurable:true,value:{messageHandlers:{
                camera:{postMessage(){}},
                cameraGlass:{postMessage(box) {
                    glassMoves.push(box);
                    if(window.holdGlass && box.w)return new Promise(resolve=>{window.resolveGlass=resolve});
                    return Promise.resolve(!!box.w)
                }}
            }}})
        });
        await native.goto(page.url());
        const drawer=native.locator('#panel');
        await native.emulateMedia({reducedMotion:'reduce'});
        await native.evaluate(()=>{window.holdGlass=true});
        await native.locator('#toggle').tap();
        await native.waitForFunction(()=>typeof window.resolveGlass==='function');
        assert.ok(!(await drawer.evaluate(el=>el.classList.contains('material-ready'))),'initial fallback holds until native acknowledgment');
        const box=await drawer.boundingBox(),sent=await native.evaluate(()=>glassMoves.at(-1));
        for(const [a,b] of [[box.x,sent.x],[box.y,sent.y],[box.width,sent.w],[box.height,sent.h]])assert.ok(Math.abs(a-b)<1);
        await native.evaluate(()=>{resolveGlass(true);window.holdGlass=false});
        await native.waitForFunction(()=>drawer.classList.contains('material-ready'));
        assert.ok(await native.evaluate(()=>CSS.supports('clip-path',shootRow.style.clipPath)&&shootRow.inert),'covered controls keep their original locations with a menu cutout');
        const count=await native.evaluate(()=>glassMoves.length);
        await native.waitForTimeout(480);
        assert.equal(await native.evaluate(()=>glassMoves.length),count,'stable glass must send no per-frame traffic');
        await native.locator('[data-aspect-tile]').tap();
        const picker=native.locator('.bottom-selector');
        await native.waitForFunction(()=>selector.classList.contains('material-ready'));
        assert.ok(await native.evaluate(n=>glassMoves.slice(n).every(box=>box.w>0),count),'handoff must not clear the live material');
        await native.evaluate(()=>receiveCamera({...window.nativeCameraState,reduceTransparency:true}));
        await native.waitForFunction(()=>document.body.classList.contains('solid-menu-material') && !selector.classList.contains('material-ready'));
        assert.deepEqual(await native.evaluate(()=>glassMoves.at(-1)),{});
        await native.evaluate(()=>{
            window.holdGlass=true;window.resolveGlass=null;
            receiveCamera({...window.nativeCameraState,reduceTransparency:false})
        });
        await native.waitForFunction(()=>typeof window.resolveGlass==='function');
        await native.touchscreen.tap(2,8);
        await picker.waitFor({state:'hidden'});
        await native.evaluate(()=>resolveGlass(true));
        assert.deepEqual(await native.evaluate(()=>[glassMoves.at(-1),selector.classList.contains('material-ready'),shootRow.style.clipPath]),[{},false,'']);
        console.log('PASS native glass shape, stable idle, handoff, reduced transparency, late replies and control masking');
    } finally { await native.close() }
}
module.exports = {verifyMenuGlass};
