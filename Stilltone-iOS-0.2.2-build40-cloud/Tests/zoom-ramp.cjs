// Exercise the actual zoom methods against a controllable AV capture device.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const src = fs.readFileSync(path.join(__dirname,'../Camera.swift'),'utf8');
const rendererTypes = src.slice(src.indexOf('enum Look: String'),src.indexOf('final class Camera:'))
    .replace('Bundle.main.url(forResource:', 'TestResources.main.url(forResource:');
function method(name) {
    const start = src.indexOf(name);
    if (start < 0) throw Error(name);
    let depth = 0;
    for (let p = src.indexOf('{',start); p < src.length; p++) {
        if(src[p] === '{') depth++;
        if(src[p] === '}' && --depth === 0) return src.slice(start,p+1);
    }
    throw Error(name);
}
const swift = `
import Foundation
import CoreVideo
import CoreImage
import Metal
struct TestResources {
    static let main = TestResources()
    func url(forResource name:String, withExtension ext:String) -> URL? {
        URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(name+"."+ext)
    }
}
${rendererTypes}
final class Queue { func async(_ job: () -> Void) { job() } }
enum DispatchQueue { static let main = Queue() }
enum DeviceType { case builtInWideAngleCamera, builtInTelephotoCamera, builtInUltraWideCamera }
struct Part { let deviceType:DeviceType }
final class AVCaptureDevice {
    var isVirtualDevice = true, isRampingVideoZoom = false
    var displayVideoZoomFactorMultiplier:CGFloat = 0.5
    var virtualDeviceSwitchOverVideoZoomFactors = [NSNumber(value:2),NSNumber(value:6)]
    var constituentDevices = [Part(deviceType:.builtInUltraWideCamera),Part(deviceType:.builtInWideAngleCamera),Part(deviceType:.builtInTelephotoCamera)]
    var maxAvailableVideoZoomFactor:CGFloat = 12, minAvailableVideoZoomFactor:CGFloat = 1
    var videoZoomFactor:CGFloat = 2
    var ramps:[CGFloat] = [], rates:[Float] = [], cancellations = 0, lockCount = 0
    func lockForConfiguration() throws { lockCount += 1 }
    func unlockForConfiguration() {}
    func cancelVideoZoomRamp() { isRampingVideoZoom = false; cancellations += 1 }
    func ramp(toVideoZoomFactor target:CGFloat, withRate rate:Float) {
        ramps.append(target); rates.append(rate); isRampingVideoZoom = true
    }
}
struct Input { let device:AVCaptureDevice }
final class Camera {
    var active=true, captureInFlight=false, currentInputRevision=7, inputRevision=7, capture=Queue(), autoMacroEnabled=true
    var requestedDisplayZoom=1.0, lens=1.0, zoomTarget=1.0, zoomRequestID=0, zoomSettling=false
    var pinchZoom:(id:Int, revision:Int, device:ObjectIdentifier, base:Double)?
    var sizesMP:[Int]=[], input:Input?
    func sizeChoices(_ d:AVCaptureDevice, highResolution:Bool)->[Int]{ [12] }
    func mainZoom(_ d:AVCaptureDevice)->Bool{ true }
    func setFallbackLenses(_ d:AVCaptureDevice,displayZoom:Double){}
    func refreshMacroState(_ d:AVCaptureDevice){}
    func report(_ e:String){ fatalError(e) }
    ${method('private func wideFactor(')}
    ${method('private func resetZoom(')}
    ${method('private func advanceInputRevision(')}
    ${method('func selectLens(')}
    func check(){
        let rear=AVCaptureDevice(); input=Input(device:rear)
        for (value,raw) in [(0.5,1.0),(1,2),(2,4),(3,6)] {
            resetZoom(rear,displayZoom:value)
            precondition(Double(rear.videoZoomFactor)==raw && zoomTarget==value && lens==value)
        }
        rear.displayVideoZoomFactorMultiplier=0.4
        precondition(wideFactor(rear)==2.5)
        rear.displayVideoZoomFactorMultiplier=0
        precondition(wideFactor(rear)==2)
        rear.displayVideoZoomFactorMultiplier=0.5
        resetZoom(rear)
        selectLens(3,inputRevision:7,requestID:1)
        precondition(zoomRequestID==1 && zoomTarget==3 && lens==1 && zoomSettling && rear.rates.last==16)
        let locks = rear.lockCount
        selectLens(3,inputRevision:7,requestID:2)
        precondition(zoomRequestID==2 && rear.ramps == [6] && rear.cancellations==0 && rear.lockCount==locks)
        rear.videoZoomFactor=3.2
        selectLens(2,inputRevision:7,requestID:3)
        precondition(zoomRequestID==3 && lens==1.6 && zoomTarget==2 && rear.ramps == [6,4] && rear.cancellations==0)
        selectLens(0.5,inputRevision:6,requestID:4)
        precondition(zoomRequestID==3 && rear.ramps.last==4)
        let parked=requestedDisplayZoom
        let front=AVCaptureDevice(); front.isVirtualDevice=false; input=Input(device:front); resetZoom(front)
        precondition(front.videoZoomFactor==1 && zoomTarget==1 && zoomRequestID==3)
        input=Input(device:rear); resetZoom(rear,displayZoom:parked)
        precondition(lens==2 && zoomTarget==2 && rear.videoZoomFactor==4 && zoomRequestID==3)
        advanceInputRevision()
        precondition(currentInputRevision==8 && inputRevision==8)
        selectLens(3,inputRevision:7,requestID:4)
        precondition(lens==2 && zoomRequestID==3)
        selectLens(40,inputRevision:8,requestID:5)
        precondition(zoomTarget==6 && rear.ramps.last==12 && zoomRequestID==5)
        let beforeReverse = rear.cancellations
        selectLens(1,inputRevision:8,requestID:6)
        precondition(rear.cancellations==beforeReverse+1 && zoomTarget==1 && rear.ramps.last==2)
        captureInFlight=true
        selectLens(0.5,inputRevision:8,requestID:7)
        precondition(zoomTarget==1 && zoomRequestID==7 && rear.ramps.count==4)
        captureInFlight=false
        resetZoom(rear)
        selectLens(3,inputRevision:8,requestID:8)
        rear.videoZoomFactor=3 // 1.5x visible, the 3x ramp is still moving
        let rampsBeforePinch = rear.ramps.count
        selectLens(3.6,inputRevision:8,requestID:9,pinchID:21,pinchScale:1.2)
        precondition(abs(zoomTarget-1.8)<0.0001 && zoomRequestID==9 && !zoomSettling)
        precondition(abs(rear.videoZoomFactor-3.6)<0.0001 && rear.ramps.count==rampsBeforePinch)
        selectLens(3.9,inputRevision:8,requestID:10,pinchID:21,pinchScale:1.3)
        precondition(abs(zoomTarget-1.95)<0.0001 && abs(rear.videoZoomFactor-3.9)<0.0001 && !zoomSettling)
        selectLens(3,inputRevision:8,requestID:11)
        precondition(pinchZoom==nil)
        rear.videoZoomFactor=4
        selectLens(4,inputRevision:8,requestID:12,pinchID:22,pinchScale:0.8)
        precondition(abs(zoomTarget-1.6)<0.0001)
        advanceInputRevision()
        precondition(pinchZoom==nil)
        input=Input(device:front); front.videoZoomFactor=1.25; front.isRampingVideoZoom=false
        selectLens(2,inputRevision:9,requestID:13,pinchID:22,pinchScale:1.2)
        precondition(abs(zoomTarget-1.5)<0.0001)
        // A gesture that lands exactly on a still-distant preset must take over immediately.
        input=Input(device:rear); resetZoom(rear,displayZoom:2)
        selectLens(3,inputRevision:9,requestID:14)
        precondition(rear.ramps.last==6 && rear.rates.last==16)
        selectLens(3,inputRevision:9,requestID:15,pinchID:23,pinchScale:1.5)
        precondition(rear.videoZoomFactor==6 && !zoomSettling && lens==3)
    }
}
Camera().check()
print("PASS display zoom, duplicate ramp, retarget, rejected stale input, rear restoration, clamped target and busy acknowledgment")

// Model the virtual device's optical field of view, then pass its output through
// the same CVPixelBuffer, clean-aperture, viewfinder and LUT path as real video.
func checkViewfinder() {
    let camera = Camera(), device = AVCaptureDevice(), renderer = Renderer()
    camera.input = Input(device:device)
    let sensor = CGRect(x:0,y:0,width:384,height:288)
    let size = CGSize(width:192,height:144), bounds = CGRect(origin:.zero,size:size)
    let black = CIImage(color:.black).cropped(to:sensor)
    let target = CGRect(x:sensor.midX+8,y:sensor.midY-12,width:8,height:24)
    let chart = CIImage(color:.white).cropped(to:target).composited(over:black)
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String:Any]]
    precondition(CVPixelBufferCreate(nil,192,144,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&pixelBuffer)==kCVReturnSuccess)
    let buffer = pixelBuffer!
    let framing = PreviewFraming(buffer:buffer,target:size)!
    var originalWhite = 0
    for look in [Look.original,.FL2] {
        var recipe = Recipe()
        recipe.look = look
        var measured: [Int] = []
        for display in [1,2,3,2] {
            camera.selectLens(Double(display))
            if device.isRampingVideoZoom {
                // Move the model to the endpoint actually passed to the device.
                device.videoZoomFactor = device.ramps.last!
                device.isRampingVideoZoom = false
            }
            let raw = device.videoZoomFactor
            let crop = CGRect(x:sensor.midX-sensor.width/(2*raw),y:sensor.midY-sensor.height/(2*raw),
                              width:sensor.width/raw,height:sensor.height/raw)
            let video = chart.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
                .transformed(by:CGAffineTransform(scaleX:size.width/crop.width,y:size.height/crop.height))
            renderer.context.render(video,to:buffer,bounds:bounds,colorSpace:renderer.space)
            let rendered = renderer.viewfinder(CIImage(cvPixelBuffer:buffer),framing:framing,recipe:recipe)
            var row = [UInt8](repeating:0,count:192*4)
            row.withUnsafeMutableBytes {
                renderer.context.render(rendered,toBitmap:$0.baseAddress!,rowBytes:192*4,
                    bounds:CGRect(x:0,y:72,width:192,height:1),format:.RGBA8,colorSpace:renderer.space)
            }
            let brightness = (0..<192).map { x in
                Int(row[4*x])+Int(row[4*x+1])+Int(row[4*x+2])
            }
            let lo = brightness.min()!, hi = brightness.max()!
            precondition(hi-lo > 300,"Calibration marker must remain visible")
            if look == .original { originalWhite = hi }
            else { precondition(hi < originalWhite-10, "FL2 must be applied to these pixels") }
            let mask = brightness.indices.filter { brightness[$0] > (lo+hi)/2 }
            let expectedFirst = 96+8*display, expectedWidth = 8*display
            precondition(abs(mask.first! - expectedFirst) <= 1 && abs(mask.last! + 1 - expectedFirst - expectedWidth) <= 1,
                         "Unexpected marker bounds at display " + String(display) + ", raw device " + String(Double(raw)))
            measured.append(mask.count)
        }
        print("PASS rendered synthetic sensor 1x/2x/3x/2x marker widths",look.rawValue,measured)
    }
}
checkViewfinder()
`;
if (!method('private func replaceBackInput(').includes('if accepted { advanceInputRevision() }') ||
    !method('func flip(inputRevision:').includes('self.advanceInputRevision()')) {
    throw Error('Each successful input replacement must invalidate commands for the old camera');
}
execFileSync('swift',['-'],{input:swift,cwd:path.join(__dirname,'..'),stdio:['pipe','inherit','inherit']});
