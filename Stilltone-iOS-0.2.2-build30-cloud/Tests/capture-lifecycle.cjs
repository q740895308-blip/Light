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
final class Session {
    var isRunning = false, stops = 0
    func stopRunning() { isRunning = false; stops += 1 }
}
final class Camera {
    let session = Session(), capture = Queue(), lock = Lock()
    var active = false, ready = false, macroVisible = false
    var acceptingPreviewFrames = false, nativeThumbnails = false
    var hiddenStopGeneration: UInt64 = 0, thumbnailGeneration: UInt64 = 0
    var latest: Int?, lastDisplayBuffer: Int?, waitingForPreview: Int?, transitionImage: Int?, visibleTransition: Int?, atlasRequest: Int?, shotID: Int?
    var starts = 0
    func restorePending() {}
    func authorize() { starts += 1; ready = true; session.isRunning = true }
    func updatePhysicalPose(_ pose: Int) {}
    ${method(camera, 'func start()')}
    ${method(camera, 'func stop()')}
    ${method(camera, 'private func stopSessionIfHidden()')}
    func finishCameraCallback() { shotID = nil; stopSessionIfHidden() }
}
final class UIDevice {
    static let current = UIDevice()
    var balance = 0, orientation = 1
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
let p = Page(), c = p.camera
p.visible = true; p.update(); p.update()
precondition(c.starts == 1 && UIDevice.current.balance == 1)
for hiddenPhase in [Phase.inactive, Phase.background] {
    p.phase = hiddenPhase; p.update(); p.update()
    precondition(!c.session.isRunning && UIDevice.current.balance == 0)
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
precondition(!c.session.isRunning && c.shotID == 5 && UIDevice.current.balance == 0)
print("PASS camera lifecycle, background and inactive, balanced sensors, album dismissal, pending exposure drain, and stale stop")
typealias CGFloat = Double
enum Facing { case front, back }
enum Kind { case builtInWideAngleCamera, builtInUltraWideCamera, builtInTelephotoCamera }
final class AVCaptureDevice {
    let position: Facing, multiplier: Double
    let deviceType = Kind.builtInWideAngleCamera
    var isVirtualDevice: Bool { multiplier != 1 }
    var isRampingVideoZoom = false, videoZoomFactor = 1.0
    let minAvailableVideoZoomFactor = 1.0, maxAvailableVideoZoomFactor = 12.0
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
    var parkedRear:(input:AVCaptureDeviceInput,zoom:Double,highResolution:Bool)?
    func deviceInput(_ facing:Facing)->AVCaptureDeviceInput? { AVCaptureDeviceInput(facing,1) }
    func rearInput()->AVCaptureDeviceInput? { AVCaptureDeviceInput(.back,0.5) }
    func preparePhotoFormat(_ device:AVCaptureDevice) {}
    func wideFactor(_ device:AVCaptureDevice)->CGFloat { 1/device.multiplier }
    func setFallbackLenses(_ device:AVCaptureDevice,displayZoom:Double) {}
    func teleBase()->Double? { 3 }
    func report(_ error:String) {}
    func orient() {}
    func updatePhotoCapabilities() {}
    ${method(camera, 'private func resetZoom(')}
    ${method(camera, 'func flip(inputRevision:')}
}
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
    }
}
print("PASS native front/rear round trip restores original input, 2x/3x hardware factor and 12/48 MP mode after session commit")
`;
execFileSync('swift', ['-'], {input:program, stdio:['pipe','inherit','inherit']});
