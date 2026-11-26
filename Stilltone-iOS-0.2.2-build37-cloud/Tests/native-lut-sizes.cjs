const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Camera.swift'), 'utf8');
// Run the app's photo renderer against its bundled LUT files on an Apple SDK.
const definitions = source.slice(source.indexOf('enum Look: String'), source.indexOf('final class Camera:'));
if (!definitions.includes('final class Renderer')) throw Error('Missing camera renderer');
const program = String.raw`
import Foundation
import CoreImage
import Metal

struct TestResources {
    static let main = TestResources()
    func url(forResource name: String, withExtension suffix: String) -> URL? {
        URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(name+"."+suffix)
    }
}
` + definitions.replace('Bundle.main.url(forResource:', 'TestResources.main.url(forResource:') + String.raw`
let renderer = Renderer()
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
`;
execFileSync('swift', ['-'], {input:program, cwd:root, stdio:['pipe','inherit','inherit']});
