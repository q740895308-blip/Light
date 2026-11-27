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
${method('struct PresetZoomMotion')}
${method('struct PresentedZoomFrame')}
${method('private struct ZoomFrameTimeline')}
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
enum Position { case back, front }
enum FocusMode { case continuousAutoFocus }
struct Part: Equatable {
    let deviceType:DeviceType
    var autofocus = true
    func isFocusModeSupported(_ mode:FocusMode) -> Bool { autofocus }
}
struct Session { var isRunning = true, isInterrupted = false }
final class AVCaptureDevice {
    var isVirtualDevice = true, isRampingVideoZoom = false
    var position = Position.back
    var supportedFallbackPrimaryConstituentDevices = [Part(deviceType:.builtInWideAngleCamera),Part(deviceType:.builtInUltraWideCamera),Part(deviceType:.builtInTelephotoCamera)]
    var activePrimaryConstituent:Part?
    var fallbackWrites = 0, locked = false
    var fallbackPrimaryConstituentDevices:[Part] = [] {
        didSet { precondition(locked); fallbackWrites += 1 }
    }
    var displayVideoZoomFactorMultiplier:CGFloat = 0.5
    var virtualDeviceSwitchOverVideoZoomFactors = [NSNumber(value:2),NSNumber(value:6)]
    var constituentDevices = [Part(deviceType:.builtInUltraWideCamera),Part(deviceType:.builtInWideAngleCamera),Part(deviceType:.builtInTelephotoCamera)]
    var maxAvailableVideoZoomFactor:CGFloat = 12, minAvailableVideoZoomFactor:CGFloat = 1
    var videoZoomFactor:CGFloat = 2
    var cancellations = 0, lockCount = 0
    func lockForConfiguration() throws { precondition(!locked); locked=true; lockCount += 1 }
    func unlockForConfiguration() { precondition(locked); locked=false }
    func cancelVideoZoomRamp() { isRampingVideoZoom = false; cancellations += 1 }
}
struct Input { let device:AVCaptureDevice }
final class Camera {
    var active=true, captureInFlight=false, currentInputRevision=7, inputRevision=7, capture=Queue(), autoMacroEnabled=true
    var macroVisible=false, macroEnabled=true, usingDedicatedWide=false, session=Session()
    var requestedDisplayZoom=1.0, lens=1.0, zoomTarget=1.0, zoomRequestID=0, zoomSettling=false
    var pinchZoom:(id:Int, revision:Int, device:ObjectIdentifier, base:Double)?
    var presetZoom: PresetZoomMotion?, starts=0, clock=0.0
    func cancelPresetZoom() { presetZoom=nil }
    func startPresetTicks() { starts += 1 }
    func zoomUptime() -> Double { clock }
    ${method('private func stepPresetZoom(')}
    ${method('private func finishPresetZoom(')}
    ${method('private func interruptPresetZoom(')}
    func advance(to time: Double) { clock = time; stepPresetZoom(at:time) }
    var sizesMP:[Int]=[], input:Input?
    func sizeChoices(_ d:AVCaptureDevice, highResolution:Bool)->[Int]{ [12] }
    func mainZoom(_ d:AVCaptureDevice)->Bool{ true }
    ${method('private func setFallbackLenses(')}
    ${method('private func applyZoomFactor(')}
    ${method('private func macroAvailable(')}
    ${method('private func macroControlVisible(')}
    ${method('private func refreshMacroState(')}
    ${method('func setAutoMacro(')}
    func cancelZoomFrames() {}
    func beginZoomFrames(_ device:AVCaptureDevice,base:CGFloat,target:Double,requestID:Int) {}
    func report(_ e:String){ fatalError(e) }
    ${method('private func wideFactor(')}
    ${method('private func resetZoom(')}
    ${method('private func advanceInputRevision(')}
    ${method('func selectLens(')}
    func checkMacro() {
        let rear = AVCaptureDevice()
        input = Input(device:rear)
        let all = rear.supportedFallbackPrimaryConstituentDevices
        let ordinary = all.filter { $0.deviceType != .builtInUltraWideCamera }
        let ultra = all.first { $0.deviceType == .builtInUltraWideCamera }!
        func reset(_ value:Double) {
            resetZoom(rear,displayZoom:value)
            refreshMacroState(rear)
        }
        for value in [0.5,0.99,1,2,3] {
            rear.activePrimaryConstituent = ultra
            reset(value)
            precondition(rear.fallbackPrimaryConstituentDevices == (value >= 1 ? all : ordinary))
            precondition(macroVisible == (value >= 1))
            rear.activePrimaryConstituent = all.first
            refreshMacroState(rear)
            precondition(!macroVisible)
        }
        rear.activePrimaryConstituent = ultra
        reset(2); setAutoMacro(false,inputRevision:6)
        precondition(autoMacroEnabled && rear.fallbackPrimaryConstituentDevices == all)
        setAutoMacro(false,inputRevision:7)
        precondition(!macroEnabled && rear.fallbackPrimaryConstituentDevices == ordinary)
        rear.activePrimaryConstituent = all.first
        reset(0.99); precondition(!macroVisible && !macroEnabled)
        reset(3); precondition(macroVisible && !macroEnabled)
        setAutoMacro(true,inputRevision:7)
        precondition(macroEnabled && rear.fallbackPrimaryConstituentDevices == all && !macroVisible)

        rear.activePrimaryConstituent = ultra
        reset(0.5); selectLens(3)
        precondition(rear.fallbackPrimaryConstituentDevices == ordinary && !macroVisible)
        advance(to:0.07)
        precondition(rear.videoZoomFactor < 2 && rear.fallbackPrimaryConstituentDevices == ordinary)
        selectLens(0.5); advance(to:0.40)
        precondition(rear.fallbackPrimaryConstituentDevices == ordinary && !macroVisible)
        selectLens(3); advance(to:0.60)
        precondition(rear.videoZoomFactor >= 2 && rear.fallbackPrimaryConstituentDevices == all && !macroVisible)
        advance(to:0.71); precondition(macroVisible)
        selectLens(0.5)
        precondition(rear.fallbackPrimaryConstituentDevices == ordinary && !macroVisible)
        selectLens(2); advance(to:1.02)
        precondition(rear.fallbackPrimaryConstituentDevices == all && macroVisible)
        for (front, physical) in [(true,false),(false,true)] {
            let device = AVCaptureDevice()
            device.position = front ? .front : .back
            device.isVirtualDevice = !physical
            usingDedicatedWide = physical; input = Input(device:device)
            device.activePrimaryConstituent = ultra
            resetZoom(device,displayZoom:2); refreshMacroState(device); setAutoMacro(false,inputRevision:7)
            precondition(!macroVisible && autoMacroEnabled && device.fallbackWrites==0)
        }
        input=Input(device:rear); usingDedicatedWide=false
        rear.supportedFallbackPrimaryConstituentDevices = ordinary
        rear.activePrimaryConstituent = ordinary.first
        reset(2); setAutoMacro(false,inputRevision:7)
        precondition(!macroVisible && autoMacroEnabled && rear.fallbackPrimaryConstituentDevices == ordinary)
        let fixedUltra = Part(deviceType:.builtInUltraWideCamera,autofocus:false)
        rear.supportedFallbackPrimaryConstituentDevices = ordinary + [fixedUltra]
        rear.activePrimaryConstituent = fixedUltra
        reset(2); setAutoMacro(false,inputRevision:7)
        precondition(!macroVisible && autoMacroEnabled)
        print("PASS macro availability, real fallback whitelist, crossing 1x, interrupted zoom, toggle, front and 48 MP")
    }
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
        precondition(zoomRequestID==1 && zoomTarget==3 && lens==1 && zoomSettling && presetZoom?.target==6)
        let locks = rear.lockCount
        selectLens(3,inputRevision:7,requestID:2)
        precondition(zoomRequestID==2 && starts==1 && rear.lockCount==locks)
        rear.videoZoomFactor=3.2
        selectLens(2,inputRevision:7,requestID:3)
        precondition(zoomRequestID==3 && lens==1.6 && zoomTarget==2 && presetZoom?.initial==3.2 && presetZoom?.target==4)
        selectLens(0.5,inputRevision:6,requestID:4)
        precondition(zoomRequestID==3 && presetZoom?.target==4)
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
        precondition(zoomTarget==6 && presetZoom?.target==12 && zoomRequestID==5)
        advance(to:0.15)
        let atReversal = rear.videoZoomFactor
        selectLens(1,inputRevision:8,requestID:6)
        precondition(zoomTarget==1 && presetZoom?.target==2 && presetZoom?.initial==atReversal)
        captureInFlight=true
        selectLens(0.5,inputRevision:8,requestID:7)
        precondition(zoomTarget==1 && zoomRequestID==7 && presetZoom?.target==2)
        captureInFlight=false
        resetZoom(rear)
        selectLens(3,inputRevision:8,requestID:8)
        rear.videoZoomFactor=3 // 1.5x visible, the 3x ramp is still moving
        let startsBeforePinch = starts
        selectLens(3.6,inputRevision:8,requestID:9,pinchID:21,pinchScale:1.2)
        precondition(abs(zoomTarget-1.8)<0.0001 && zoomRequestID==9 && !zoomSettling)
        precondition(abs(rear.videoZoomFactor-3.6)<0.0001 && starts==startsBeforePinch && presetZoom==nil)
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
        precondition(presetZoom?.target==6)
        selectLens(3,inputRevision:9,requestID:15,pinchID:23,pinchScale:1.5)
        precondition(rear.videoZoomFactor==6 && !zoomSettling && lens==3)
        let start = clock
        selectLens(1,inputRevision:9,requestID:16)
        var observed = [Double(rear.videoZoomFactor)]
        for ms in [50,100,150,200,250,299,300] {
            advance(to:start+Double(ms)/1000)
            observed.append(Double(rear.videoZoomFactor))
            precondition(zoomSettling == (ms < 300))
        }
        let increments = (1...5).map { abs(log(observed[$0]/observed[$0-1])) }
        precondition(increments[0] < increments[1] && increments[1] < increments[2])
        precondition(increments[4] < increments[3] && rear.videoZoomFactor==2 && lens==1 && presetZoom==nil)
        precondition(abs(observed[3] - sqrt(12.0)) < 0.0001)
        selectLens(2,inputRevision:9,requestID:17)
        advance(to:clock+0.15)
        let frozen = rear.videoZoomFactor
        interruptPresetZoom()
        advance(to:clock+0.40)
        precondition(!zoomSettling && presetZoom==nil && zoomTarget==Double(frozen/2) && rear.videoZoomFactor==frozen)
    }
}
Camera().check()
Camera().checkMacro()
private var timeline = ZoomFrameTimeline(inputRevision:8,requestID:15,target:2,started:5,samples:[(5,1)])
precondition(timeline.frame(at:4.99,now:5.01,actual:1,ramping:true)==nil)
let intermediate = timeline.frame(at:5.02,now:5.03,actual:2,ramping:false)!
precondition(abs(intermediate.zoom-sqrt(2.0))<0.001 && !intermediate.settled)
precondition(intermediate.inputRevision==8 && intermediate.zoomRequestID==15)
let finalFrame = timeline.frame(at:5.04,now:5.06,actual:2,ramping:false)!
precondition(finalFrame.settled && finalFrame.zoom==2)
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
            camera.advance(to:camera.clock+0.30)
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
