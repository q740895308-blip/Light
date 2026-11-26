const assert = require('node:assert/strict');

async function verifyMenuGlass(page) {
    const panel = page.locator('#panel');
    const picker = page.locator('.bottom-selector');
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
        const bytes = await page.screenshot({clip,scale:'css'});
        return page.evaluate(async base64 => {
            const img = new Image();
            img.src = 'data:image/png;base64,' + base64;
            await img.decode();
            const canvas = document.createElement('canvas');
            canvas.width = img.width;
            canvas.height = img.height;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img,0,0);
            const pixels = ctx.getImageData(0,1,canvas.width,1).data;
            const values = channel => Array.from({length:canvas.width},(_,i)=>pixels[i*4+channel]);
            const rgb = [0,1,2].map(values);
            return {
                mean:rgb.map(row=>row.reduce((a,b)=>a+b,0)/row.length),
                ripple:Math.max(...rgb.flatMap(row=>row.slice(1).map((v,i)=>Math.abs(v-row[i]))))
            };
        }, bytes.toString('base64'));
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
            assert.ok(Math.max(red.ripple,blue.ripple)<12,
                kind+' transmitted sharp background stripes '+JSON.stringify({red,blue}));
            await page.touchscreen.tap(2,8);
            await sheet.waitFor({state:'hidden'});
        }
    } finally {
        await page.evaluate(()=>document.getElementById('glass-test-scene').remove());
    }
    console.log('PASS iPhone 14 Pro drawer and seven submenus transmit scene colours and blur fine stripes');
}
module.exports = {verifyMenuGlass};
