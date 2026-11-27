const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function sampleCube(buffer, size, pixel) {
    const position = pixel.map(v => v * (size - 1) / 255);
    const lower = position.map(v => Math.min(size - 2, Math.floor(v)));
    const fraction = position.map((v, i) => v - lower[i]);
    const output = [0,0,0];
    for (const r of [0,1]) for (const g of [0,1]) for (const b of [0,1]) {
        const weight = [r,g,b].reduce((v, high, i) => v * (high ? fraction[i] : 1 - fraction[i]), 1);
        const address = 16 * (lower[0] + r + size * (lower[1] + g + size * (lower[2] + b)));
        for (let c = 0; c < 3; c++) output[c] += 255 * weight * buffer.readFloatLE(address + c*4);
    }
    return Array.from(Uint8ClampedArray.from(output));
}

async function verifyLutPixels(page, checkCamera) {
    const samples = [[0,0,0],[1,254,255],[127,128,129],[51,172,249],[224,224,224],[240,240,240],[250,240,226],[254,255,253],[255,255,255]];
    for (const [name, size] of [['FL2',33],['FL3',33],['Classic-Chrome',65],['Classic-Negative',65],['Fuji-Eterna-Bypass',65],['Leica-M-Tone-V2',33]]) {
        const buffer = fs.readFileSync(path.join(__dirname,'..',name+'.rgba'));
        assert.equal(buffer.length,16*size**3);
        const expected = samples.flatMap(pixel=>[...sampleCube(buffer,size,pixel),255]);
        if (name === 'FL2' || name === 'FL3') {
            const highlights = [192,208,224,240,255].map(gray => sampleCube(buffer,size,[gray,gray,gray]));
            for (let i = 1; i < highlights.length; i++) {
                assert.ok(highlights[i].every((value, channel) => value - highlights[i-1][channel] >= 4),
                    name + ' merges distinct highlight levels: ' + JSON.stringify(highlights));
            }
        }
        const outputs = await page.evaluate(({name,samples,checkCamera}) => {
            const input = new ImageData(samples.length,1);
            input.data.set(samples.flatMap(pixel=>[...pixel,255]));
            const pixels = [];
            if (checkCamera) {
                const canvas = document.createElement('canvas');
                canvas.width=input.width;canvas.height=input.height;
                canvas.getContext('2d').putImageData(input,0,0);
                const result=renderPlain(canvas,name);
                pixels.push(Array.from(result.getContext('2d').getImageData(0,0,input.width,1).data));
            }
            pixels.push(Array.from(albumApplyLook(input,{look:name,strength:100}).data));
            return pixels;
        },{name,samples,checkCamera});
        for(const output of outputs) {
            assert.equal(output.length,expected.length);
            output.forEach((value,i)=>assert.ok(Math.abs(value-expected[i])<=1,
                name+' channel '+i+' got '+value+' expected '+expected[i]));
        }
    }
    console.log('PASS '+(checkCamera?'camera and embedded editor':'album editor')+' pixels match Sony, Fuji and Leica cubes, including Sony highlight steps');
}
module.exports = {verifyLutPixels};
