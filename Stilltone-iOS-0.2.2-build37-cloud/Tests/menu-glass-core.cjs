const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

function verifyCoreImageGlass() {
    const source = fs.readFileSync(path.join(__dirname,'../Camera.swift'),'utf8');
    const method = source.slice(source.indexOf('func sampleMenuGlass('));
    const crop = method.indexOf('let width =');
    const jpeg = method.indexOf('let jpeg =');
    if (crop < 0 || jpeg <= crop) throw Error('Cannot locate native menu sample renderer');
    // Use the production crop, resize, blur, and CGImage creation on a synthetic
    // input. A neutral recipe represents the camera's unfiltered setting.
    const program = `
import Foundation
import CoreImage
import CoreGraphics

let space = CGColorSpace(name: CGColorSpace.sRGB)!
struct NeutralRenderer {
    let context = CIContext(options:[.useSoftwareRenderer:true])
    func image(_ frame:CIImage, _ recipe:Int) throws -> CIImage { frame }
}
struct GlassProbe {
    let thumbnailRenderer = NeutralRenderer()
    func render(_ source:CIImage, aspect:CGFloat) -> CGImage {
        let extent = source.extent, recipe = 0
        ${method.slice(crop,jpeg)}
        return rgb!
    }
}
let width = 480, height = 640
var pixels = [UInt8](repeating:255,count:width*height*4)
for y in 0..<height { for x in 0..<width {
    let offset = (y*width+x)*4
    let stripe:UInt8 = (x/32)%2 == 0 ? 255 : 48
    pixels[offset] = y < height/2 ? stripe : 12
    pixels[offset+1] = 12
    pixels[offset+2] = y < height/2 ? 12 : stripe
} }
let frame = CIImage(bitmapData:Data(pixels),bytesPerRow:width*4,size:CGSize(width:width,height:height),format:.RGBA8,colorSpace:space)
let probe = GlassProbe()
let rendered = probe.render(frame,aspect:0.75)
precondition(rendered.width == 36 && rendered.height == 48, "wrong sample geometry")
let image = CIImage(cgImage:rendered)
var out = [UInt8](repeating:0,count:36*48*4)
out.withUnsafeMutableBytes {
    probe.thumbnailRenderer.context.render(image,toBitmap:$0.baseAddress!,rowBytes:36*4,bounds:image.extent,format:.RGBA8,colorSpace:space)
}
var dominance = [Int]()
for y in [10,37] {
    let red = (5..<31).map { Int(out[(36*y+$0)*4]) }
    let blue = (5..<31).map { Int(out[(36*y+$0)*4+2]) }
    dominance.append((red.reduce(0,+)-blue.reduce(0,+))/red.count)
    for channel in [red,blue] {
        precondition(channel.max()! - channel.min()! < 45, "sharp stripes still visible after material blur")
    }
}
precondition(dominance.min()! < -70 && dominance.max()! > 70, "material lost large scale scene colours")
print("PASS production Core Image menu sample suppresses sensor stripes and preserves scene colour")
`;
    execFileSync('swift',['-'],{input:program,stdio:['pipe','inherit','inherit']});
}
module.exports = {verifyCoreImageGlass};
