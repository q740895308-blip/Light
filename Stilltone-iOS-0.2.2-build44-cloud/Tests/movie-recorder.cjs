const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

const root = path.resolve(__dirname,'..');
const camera = fs.readFileSync(path.join(root,'Camera.swift'),'utf8');
const filters = camera.slice(camera.indexOf('enum Look: String'),camera.indexOf('final class Camera:'));
if (!filters.includes('final class Renderer')) throw Error('Missing production LUT renderer');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(),'stilltone-movie-test-'));
try {
    const source = path.join(scratch,'Filters.swift');
    fs.writeFileSync(source,'import AVFoundation\nimport CoreImage\nimport Metal\n'+filters);
    fs.copyFileSync(path.join(root,'FL2.rgba'),path.join(scratch,'FL2.rgba'));
    const binary = path.join(scratch,'movie-test');
    execFileSync('xcrun',['swiftc','-O','-parse-as-library',source,path.join(root,'MovieRecorder.swift'),
        path.join(__dirname,'MovieRecordingFixture.swift'),'-o',binary],{stdio:'inherit'});
    execFileSync(binary,[],{cwd:scratch,stdio:'inherit',timeout:90000});
} finally {
    fs.rmSync(scratch,{recursive:true,force:true});
}
