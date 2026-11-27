const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Camera.swift'), 'utf8');
// Run the app's photo renderer against its bundled LUT files on an Apple SDK.
const definitions = source.slice(source.indexOf('enum Look: String'), source.indexOf('final class Camera:'));
if (!definitions.includes('final class Renderer')) throw Error('Missing camera renderer');
const studio = fs.readFileSync(path.join(root, 'StudioApp.swift'), 'utf8');
for (const view of ['SharedCapture','CameraScreen']) {
    const body = studio.slice(studio.indexOf('struct '+view+': View')).split('\n}')[0];
    if (!body.includes('LiveCameraPreview(camera:camera,') || /\b(GPUPreview|CameraFeed)\(/.test(body)) {
        throw Error(view+' must keep one viewfinder across look changes');
    }
}
const program = String.raw`
import Foundation
import CoreImage
import CoreVideo
import Metal

struct TestResources {
    static let main = TestResources()
    func url(forResource name: String, withExtension suffix: String) -> URL? {
        URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(name+"."+suffix)
    }
}
` + definitions.replace('Bundle.main.url(forResource:', 'TestResources.main.url(forResource:') + String.raw`
let renderer = Renderer()
var buffer: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil,160,120,kCVPixelFormatType_32BGRA,nil,&buffer) == kCVReturnSuccess)
let target = CGSize(width:80,height:60)
let projected = PreviewFraming(buffer:buffer!,target:target,outputRect:CGRect(x:24,y:12,width:80,height:60))!
precondition(projected.crop == CGRect(x:24,y:48,width:80,height:60))
precondition(PreviewFraming(buffer:buffer!,target:target,outputRect:.null)!.crop == CGRect(x:0,y:0,width:160,height:120))
print("PASS filtered video uses the system viewfinder's rectangle and falls back to the clean aperture")
let looks = Look.allCases.filter { $0.rawValue.hasPrefix("Fuji-") || $0.rawValue.hasPrefix("Leica-") }
precondition(looks.count == 15)
for look in looks {
    let n = look.cubeDimension
    let raw = try Data(contentsOf: TestResources.main.url(forResource:look.rawValue, withExtension:"rgba")!)
    precondition(raw.count == n*n*n*16)
    var recipe = Recipe()
    recipe.look = look
    for (r,g,b) in [(n / 4 + 1,n / 3,n / 2 + 3), (n / 2 + 1,n / 2 - 3,n / 2), (n-5,n / 3 + 1,n / 4 + 3)] {
        let rgba = [Float(r)/Float(n-1),Float(g)/Float(n-1),Float(b)/Float(n-1),1]
        let sample = CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) }, bytesPerRow:16,
                             size:CGSize(width:1,height:1), format:.RGBAf, colorSpace:renderer.space)
        let image = try renderer.image(sample, recipe)
        var out = [Float](repeating:0,count:4)
        out.withUnsafeMutableBytes {
            renderer.context.render(image, toBitmap:$0.baseAddress!, rowBytes:16,
                                    bounds:sample.extent, format:.RGBAf, colorSpace:renderer.space)
        }
        let first = 4*(r+n*(g+n*b))
        let expected = raw.withUnsafeBytes { Array($0.bindMemory(to:Float.self)[first..<first+4]) }
        for i in 0..<4 {
            precondition(abs(out[i]-expected[i]) < 0.015, "\(look): \(out) vs LUT node \(expected)")
        }
    }
    print("PASS \(look.rawValue) \(n)^3 Core Image colour nodes")
}

let clean = CGRect(x:8,y:4,width:64,height:48)
let mask = CIImage(color:CIColor(red:0.08,green:0.08,blue:0.08)).cropped(to:CGRect(x:0,y:0,width:80,height:60))
let ink = CIImage(color:CIColor(red:0.88,green:0.88,blue:0.88))
let pattern = [CGRect(x:15,y:10,width:30,height:4),CGRect(x:30,y:10,width:5,height:28),
               CGRect(x:47,y:28,width:6,height:9)].reduce(mask) { ink.cropped(to:$1).composited(over:$0) }
func markerMask(_ scene: CIImage, _ frame: PreviewFraming, _ look: Look) -> [Bool] {
    var recipe = Recipe(aspect:"1:1")
    recipe.look = look
    let image = renderer.viewfinder(scene,framing:frame,recipe:recipe)
    let w = Int(frame.target.width), h = Int(frame.target.height)
    precondition(image.extent == CGRect(origin:.zero,size:frame.target))
    var data = [UInt8](repeating:0,count:w*h*4)
    data.withUnsafeMutableBytes {
        renderer.context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*4,bounds:image.extent,format:.RGBA8,colorSpace:renderer.space)
    }
    let values = stride(from:0,to:data.count,by:4).map { Int(data[$0]) + Int(data[$0+1]) + Int(data[$0+2]) }
    let high = values.max()!, low = values.min()!
    precondition(high-low > 80)
    return values.map { $0 > (high+low)/2 }
}
let mirrored = pattern.transformed(by:CGAffineTransform(a:-1,b:0,c:0,d:1,tx:80,ty:0))
for size in [CGSize(width:64,height:48),CGSize(width:48,height:48),CGSize(width:64,height:36)] {
    let frame = PreviewFraming(clean:clean,display:clean.size,target:size)!
    precondition(frame.crop.midX == clean.midX && frame.crop.midY == clean.midY)
    let tap = frame.outputPoint(CGPoint(x:0.5,y:0.5),encodedHeight:60)
    precondition(tap.x == clean.midX && tap.y == 60-clean.midY)
    let original = markerMask(pattern,frame,.original), selfie = markerMask(mirrored,frame,.original)
    precondition(original != selfie, "asymmetric test pattern")
    for look in [Look.FL2,.astia,.leicaBWB] {
        precondition(markerMask(pattern,frame,look) == original && markerMask(mirrored,frame,look) == selfie,
                     "Spatial shift at \(size), \(look)")
    }
}
print("PASS original and 33/65-cube looks preserve every marker pixel at 4:3, 1:1 and 16:9 for mirrored and rear frames")
`;
execFileSync('swift', ['-'], {input:program, cwd:root, stdio:['pipe','inherit','inherit']});
