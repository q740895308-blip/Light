// Run on macOS with Node and Xcode's Swift toolchain.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const camera = fs.readFileSync(path.join(__dirname, '../Camera.swift'), 'utf8');
const studio = fs.readFileSync(path.join(__dirname, '../StudioApp.swift'), 'utf8');
function method(source, signature) {
    const start = source.indexOf(signature);
    if (start < 0) throw Error('Missing method ' + signature);
    let depth = 0;
    for (let i = source.indexOf('{', start); i < source.length; ++i) {
        if (source[i] === '{') ++depth;
        if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
    }
    throw Error('Unclosed method ' + signature);
}
const program = `
import Foundation
${method(camera,'struct PresentedZoomFrame')}
final class Queue {
    static let main = Queue()
    var delayed: [() -> Void] = []
    func async(_ action: () -> Void) { action() }
    func asyncAfter(deadline: Clock, execute action: @escaping () -> Void) { delayed.append(action) }
}
typealias DispatchQueue = Queue
struct Clock {
    static func now() -> Clock { Clock() }
    static func +(lhs: Clock, rhs: Int) -> Clock { precondition(rhs == 5); return lhs }
}
struct Lock { func lock() {} ; func unlock() {} }
typealias CVPixelBuffer = Int
struct Recipe {}
final class Session {
    var isRunning = false, stops = 0
    func stopRunning() { isRunning = false; stops += 1 }
}
enum UIDeviceOrientation { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, unknown }
${method(camera,'struct HandheldPoseFilter')}
struct Acceleration { var x:Double, y:Double, z:Double }
struct MotionSample { let acceleration:Acceleration, timestamp:Double }
final class Motion {
    var isAccelerometerAvailable = true, accelerometerUpdateInterval = 0.0, balance = 0
    var callback:((MotionSample?,Error?)->Void)?
    func startAccelerometerUpdates(to:OperationQueue,withHandler callback:@escaping (MotionSample?,Error?)->Void) { self.callback=callback; balance+=1 }
    func stopAccelerometerUpdates() { callback=nil; balance-=1 }
}
final class Camera {
    let poseMotion = Motion()
    var handheldPose = HandheldPoseFilter(), poseGeneration:UInt64=0
    ${method(camera,'enum PoseSource')}
    var poseSource = PoseSource.stopped
    var poses:[UIDeviceOrientation]=[]
    ${method(camera,'func startPoseTracking()')}
    ${method(camera,'private func startDevicePoseFallback()')}
    ${method(camera,'func refreshFallbackPose()')}
    ${method(camera,'func stopPoseTracking()')}
    let session = Session(), capture = Queue(), lock = Lock()
    var active = false, ready = false, macroVisible = false
    var acceptingPreviewFrames = false, nativeThumbnails = false
    var hiddenStopGeneration: UInt64 = 0, thumbnailGeneration: UInt64 = 0
    var previewSourceGeneration: UInt64 = 0
    var latestZoomFrame: PresentedZoomFrame?
    func cancelZoomFrames() { latestZoomFrame = nil }
    func interruptPresetZoom() {}
    let selected = Recipe()
    var latest: Int?, lastDisplayBuffer: Int?, waitingForPreview: Int?, transitionImage: Int?, visibleTransition: Int?, atlasRequest: Int?, shotID: Int?
    var starts = 0
    func restorePending() {}
    func authorize() { starts += 1; ready = true; acceptingPreviewFrames = true; session.isRunning = true }
    func updatePhysicalPose(_ pose: UIDeviceOrientation) { poses.append(pose) }
    ${method(camera, 'func start()')}
    ${method(camera, 'func stop()')}
    ${method(camera, 'func pendingPreviewSource()')}
    ${method(camera, 'func previewFrame(for')}
    ${method(camera, 'func isPreviewSourceCurrent(')}
    ${method(camera, 'private func stopSessionIfHidden()')}
    func finishCameraCallback() { shotID = nil; stopSessionIfHidden() }
}
final class UIDevice {
    static let current = UIDevice()
    var balance = 0, orientation = UIDeviceOrientation.portrait
    func beginGeneratingDeviceOrientationNotifications() { balance += 1 }
    func endGeneratingDeviceOrientationNotifications() { balance -= 1 }
}
enum Phase { case active, inactive, background }
final class Page {
    let camera = Camera()
    var captureRequested = false, visible = false, album = false, phase = Phase.active
    ${method(studio, 'private var shooting: Bool')}
    ${method(studio, 'private func setCaptureRequested(')}
    func update() { setCaptureRequested(shooting) }
}
// Exercise the production WK handoff with manually delayed JS completions.
final class ZoomTestWeb {
    var calls:[[String:Any]] = []
    var completions:[(Any?,Error?) -> Void] = []
}
func STCallPageScript(_ web:ZoomTestWeb,_ script:String,_ args:[String:Any],_ completion:@escaping(Any?,Error?)->Void) {
    precondition(script == "window.receiveZoomFrame(frame)")
    web.calls.append(args["frame"] as! [String:Any]); web.completions.append(completion)
}
enum LiveCameraPreview { static var metal: Int? = 1 }
final class ZoomTestOwner {
    final class Device { var ready = true, inputRevision = 1, zoomRequestID = 2 }
    let camera = Device()
    var shootViewActive = true
}
final class ZoomTestBridge {
    let owner = ZoomTestOwner()
    var ready = true, web:ZoomTestWeb? = ZoomTestWeb()
    var queuedZoom:(frame:PresentedZoomFrame,time:Double)?, zoomDelivery:UUID?
    var lastZoomPresentation = 0.0
    ${method(studio,'private var presentsZoomFrames: Bool')}
    ${method(studio,'private func enqueueZoomFrame(')}
    ${method(studio,'private func sendQueuedZoomFrame()')}
    func frame(_ zoom:Double, at time:Double, settled:Bool = false) {
        let frame = PresentedZoomFrame(zoom:zoom,inputRevision:owner.camera.inputRevision,zoomRequestID:owner.camera.zoomRequestID,settled:settled)
        enqueueZoomFrame(frame,at:time)
    }
}
let bridge = ZoomTestBridge(), web = bridge.web!
bridge.frame(1,at:1); bridge.frame(1.5,at:2); bridge.frame(2,at:3,settled:true)
precondition(web.calls.count == 1)
web.completions.removeFirst()(nil,nil)
let finalReport = web.calls.last!
precondition(web.calls.count == 2 && finalReport["zoom"] as? Double == 2 && finalReport["settled"] as? Bool == true)
bridge.frame(1.75,at:2.5); precondition(bridge.queuedZoom == nil)
bridge.frame(2.2,at:4); bridge.owner.camera.inputRevision += 1
web.completions.removeFirst()(nil,nil)
bridge.owner.shootViewActive = false; bridge.frame(1,at:5)
LiveCameraPreview.metal = nil; bridge.owner.shootViewActive = true; bridge.frame(1,at:6)
precondition(web.calls.count == 2)
print("PASS presented zoom frames coalesce, preserve final report and reject stale or inactive surfaces")
let p = Page(), c = p.camera
let preview = Camera()
preview.start()
precondition(preview.pendingPreviewSource() == nil)
preview.latest = 1
let source = preview.pendingPreviewSource()!
preview.latest = 2; preview.latest = 3
precondition(preview.previewFrame(for:source)?.0 == 3 && preview.pendingPreviewSource() == nil)
preview.stop(); preview.start(); preview.latest = 4
precondition(!preview.isPreviewSourceCurrent(source) && preview.previewFrame(for:source) == nil)
precondition(preview.previewFrame(for:preview.pendingPreviewSource()!)?.0 == 4)
print("PASS newest frame after drawable wait, consumption once, stale source rejected after restart")
p.visible = true; p.update(); p.update()
precondition(c.starts == 1 && UIDevice.current.balance == 0 && c.poseMotion.balance == 1)
let previousCallback=c.poseMotion.callback!
var sampleTime=0.0
func feed(_ a:Acceleration,_ count:Int) {
    for _ in 0..<count {
        sampleTime+=0.1
        c.poseMotion.callback?(MotionSample(acceleration:a,timestamp:sampleTime),nil)
    }
}
feed(Acceleration(x:-1,y:0,z:0),3);c.refreshFallbackPose()
precondition(c.poses == [.landscapeLeft])
feed(Acceleration(x:0.70,y:0.71,z:0),5);feed(Acceleration(x:0.1,y:0.1,z:-0.98),6)
feed(Acceleration(x:1.5,y:-0.1,z:0.1),4);feed(Acceleration(x:1,y:0,z:0),1)
precondition(c.poses == [.landscapeLeft])
feed(Acceleration(x:1,y:0,z:0),3);feed(Acceleration(x:0,y:1,z:0),3);feed(Acceleration(x:0,y:-1,z:0),3)
precondition(c.poses == [.landscapeLeft,.landscapeRight,.portraitUpsideDown,.portrait])
for hiddenPhase in [Phase.inactive, Phase.background] {
    p.phase = hiddenPhase; p.update(); p.update()
    precondition(!c.session.isRunning && c.poseMotion.balance == 0 && UIDevice.current.balance == 0)
    previousCallback(nil,NSError(domain:"stale",code:1));precondition(UIDevice.current.balance == 0)
    p.phase = .active; p.update()
}
c.latest = 1; c.lastDisplayBuffer = 2; c.atlasRequest = 3; c.nativeThumbnails = true; c.shotID = 4
p.album = true; p.update()
precondition(!c.ready && !c.acceptingPreviewFrames && !c.nativeThumbnails && c.latest == nil && c.lastDisplayBuffer == nil && c.atlasRequest == nil)
precondition(c.session.isRunning && c.capture.delayed.count == 1)
let stale = c.capture.delayed.removeFirst()
p.album = false; p.update(); stale()
precondition(c.session.isRunning && c.shotID == 4 && c.acceptingPreviewFrames)
p.album = true; p.update(); c.finishCameraCallback()
precondition(!c.session.isRunning)
p.album = false; p.update(); c.shotID = 5; p.visible = false; p.update()
c.capture.delayed.removeFirst()()
precondition(c.session.isRunning && c.shotID == 5)
c.capture.delayed.removeFirst()()
precondition(!c.session.isRunning && c.shotID == 5 && UIDevice.current.balance == 0 && c.poseMotion.balance == 0)
let fallback=Camera()
fallback.startPoseTracking();fallback.poseMotion.callback?(nil,NSError(domain:"failed",code:1))
precondition(fallback.poseMotion.balance == 0 && UIDevice.current.balance == 1 && fallback.poses == [.portrait])
fallback.stopPoseTracking();fallback.poseMotion.isAccelerometerAvailable=false;fallback.startPoseTracking()
precondition(UIDevice.current.balance == 1 && fallback.poseMotion.balance == 0)
fallback.stopPoseTracking();precondition(UIDevice.current.balance == 0)
print("PASS orientation lock, gravity axes, near-flat holding, motion rejection, single active source, fallback and stale callbacks")
print("PASS camera lifecycle, background and inactive, balanced sensors, album dismissal, pending exposure drain, and stale stop")
typealias CGFloat = Double
${method(camera,'struct PresetZoomMotion')}
enum Facing { case front, back }
enum Kind { case builtInWideAngleCamera, builtInUltraWideCamera, builtInTelephotoCamera }
struct Part { let deviceType: Kind }
final class AVCaptureDevice {
    let position: Facing, multiplier: Double
    let deviceType = Kind.builtInWideAngleCamera
    var isVirtualDevice: Bool { multiplier != 1 }
    var displayVideoZoomFactorMultiplier: Double { multiplier }
    var constituentDevices: [Part] { isVirtualDevice ? [.init(deviceType:.builtInUltraWideCamera),.init(deviceType:.builtInWideAngleCamera),.init(deviceType:.builtInTelephotoCamera)] : [] }
    var switches: [NSNumber] = [2,6]
    var virtualDeviceSwitchOverVideoZoomFactors: [NSNumber] { isVirtualDevice ? switches : [] }
    var commandedFactor = 1.0
    func ramp(toVideoZoomFactor value:Double,withRate:Float) { commandedFactor=value;isRampingVideoZoom=true }
    var isRampingVideoZoom = false, videoZoomFactor = 1.0
    var minAvailableVideoZoomFactor = 1.0, maxAvailableVideoZoomFactor = 12.0
    init(_ side:Facing,_ multiplier:Double) { self.position=side; self.multiplier=multiplier }
    func lockForConfiguration() throws {}
    func unlockForConfiguration() {}
    func cancelVideoZoomRamp() { isRampingVideoZoom=false }
}
final class AVCaptureDeviceInput {
    let device: AVCaptureDevice
    init(_ side:Facing,_ multiplier:Double) { device=AVCaptureDevice(side,multiplier) }
}
final class InputSession {
    var input: AVCaptureDeviceInput?, rejectFront=false
    func removeInput(_ old:AVCaptureDeviceInput) { input=nil }
    func canAddInput(_ next:AVCaptureDeviceInput)->Bool { !(rejectFront && next.device.position == .front) }
    func addInput(_ next:AVCaptureDeviceInput) { input=next }
    func beginConfiguration() {}
    func commitConfiguration() { input!.device.videoZoomFactor=1 }
}
final class Flip {
    let capture=Queue(), session=InputSession()
    var active=true, captureInFlight=false, currentInputRevision=0, inputRevision=0, zoomSettling=false
    var requestedDisplayZoom=1.0, lens=1.0, usingDedicatedWide=false, input:AVCaptureDeviceInput?
    var zoomTarget=1.0, zoomRequestID=0, autoMacroEnabled=true
    var pinchZoom:(id:Int, revision:Int, device:ObjectIdentifier, base:Double)?
    var rearLensPresets: [Double] = []
    var parkedRear:(input:AVCaptureDeviceInput,zoom:Double,highResolution:Bool)?
    func deviceInput(_ facing:Facing)->AVCaptureDeviceInput? { AVCaptureDeviceInput(facing,1) }
    func rearInput()->AVCaptureDeviceInput? { AVCaptureDeviceInput(.back,0.5) }
    func preparePhotoFormat(_ device:AVCaptureDevice) {}
    ${method(camera, 'private func wideFactor(')}
    var sizesMP=[12]
    func mainZoom(_ device:AVCaptureDevice)->Bool { device.videoZoomFactor == wideFactor(device) }
    func sizeChoices(_ device:AVCaptureDevice,highResolution:Bool)->[Int] { [12] }
    func setFallbackLenses(_ device:AVCaptureDevice,displayZoom:Double) {}
    ${method(camera,'private func applyZoomFactor(')}
    func refreshMacroState(_ device:AVCaptureDevice) {}
    func cancelZoomFrames() {}
    var presetZoom: PresetZoomMotion?
    func cancelPresetZoom() { presetZoom=nil }
    func startPresetTicks() {}
    func zoomUptime() -> Double { 0 }
    ${method(camera,'private func stepPresetZoom(')}
    ${method(camera,'private func finishPresetZoom(')}
    func finishZoom() { stepPresetZoom(at:0.30) }
    func beginZoomFrames(_ device:AVCaptureDevice,base:CGFloat,target:Double,requestID:Int) {}
    ${method(camera, 'private func zoomCapabilities(')}
    func profile(_ device:AVCaptureDevice) -> (stops:[Double], optical:[Double], range:[Double]) { zoomCapabilities(device) }
    func report(_ error:String) {}
    func orient() {}
    func beginPreviewTransition()->UUID? { nil }
    func suspendPreviewFrames() {}
    func resumePreviewFrames(_ device:AVCaptureDevice,cover:UUID?) {}
    func updatePhotoCapabilities(restoringZoom:Double? = nil) {
        input!.device.videoZoomFactor = 1
        if let zoom=restoringZoom { resetZoom(input!.device,displayZoom:zoom) }
    }
    ${method(camera, 'func selectLens(')}
    func tapAfterReturn(_ requested:Double){ selectLens(requested,inputRevision:inputRevision) }
    ${method(camera, 'private func resetZoom(')}
    ${method(camera, 'private func advanceInputRevision(')}
    ${method(camera, 'func flip(inputRevision:')}
}
let profiles=Flip()
let composite=AVCaptureDevice(.back,0.5)
composite.maxAvailableVideoZoomFactor=60;composite.switches=[2,5]
precondition(profiles.profile(composite).stops == [0.5,1,2,2.5] && profiles.profile(composite).range == [0.5,30])
composite.switches=[2,10]
precondition(profiles.profile(composite).stops == [0.5,1,2,5])
let front=AVCaptureDevice(.front,1)
front.maxAvailableVideoZoomFactor=1
precondition(profiles.profile(front).stops == [1])
front.maxAvailableVideoZoomFactor=4
precondition(profiles.profile(front).stops == [1,2] && profiles.profile(front).optical == [1])
let physical=AVCaptureDevice(.back,1)
profiles.rearLensPresets=profiles.profile(composite).optical;profiles.usingDedicatedWide=true
precondition(profiles.profile(physical).stops == [1,2,5] && profiles.profile(physical).optical == [1])
profiles.rearLensPresets=[]
precondition(profiles.profile(physical).stops == [1,2])
print("PASS camera-specific zoom ranges, 2.5x/5x optical stops, physical and front limits, dedicated wide crop labels")
for high in [false,true] {
    for zoom in [2.0,3.0] {
        let f=Flip(), rear=AVCaptureDeviceInput(.back,high ? 1:0.5)
        f.input=rear; f.session.input=rear; f.usingDedicatedWide=high; f.requestedDisplayZoom=zoom
        f.flip(inputRevision:0)
        precondition(f.input!.device.position == .front && f.lens == 1 && !f.usingDedicatedWide)
        f.flip(inputRevision:0)
        precondition(f.inputRevision == 1 && f.input!.device.position == .front)
        f.flip(inputRevision:1)
        precondition(f.input === rear && f.lens == zoom && f.usingDedicatedWide == high)
        precondition(f.input!.device.videoZoomFactor == zoom / rear.device.multiplier)
        f.session.rejectFront=true; f.flip(inputRevision:2)
        precondition(f.input === rear && f.lens == zoom && f.inputRevision == 2)
        if !high {
            for tap in [2.0,3.0] {
                let actual=rear.device.videoZoomFactor
                f.tapAfterReturn(tap)
                precondition(f.lens == actual/2 && f.zoomTarget == tap)
                if actual == tap*2 {
                    precondition(!f.zoomSettling)
                } else {
                    precondition(f.zoomSettling && f.presetZoom?.target == tap*2)
                    f.finishZoom()
                    precondition(!f.zoomSettling && rear.device.videoZoomFactor==tap*2)
                }
            }
        }
    }
}
print("PASS native front/rear round trip restores original input, 2x/3x hardware factor and 12/48 MP mode after session commit")
`;
execFileSync('swift', ['-'], {input:program, stdio:['pipe','inherit','inherit']});
