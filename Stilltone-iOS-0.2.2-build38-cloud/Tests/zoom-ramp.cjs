// Exercise the actual zoom methods against a controllable AV capture device.
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const src = fs.readFileSync(path.join(__dirname,'../Camera.swift'),'utf8');
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
    var ramps:[CGFloat] = [], cancellations = 0, lockCount = 0
    func lockForConfiguration() throws { lockCount += 1 }
    func unlockForConfiguration() {}
    func cancelVideoZoomRamp() { isRampingVideoZoom = false; cancellations += 1 }
    func ramp(toVideoZoomFactor target:CGFloat, withRate rate:Float) { ramps.append(target); isRampingVideoZoom = true }
}
struct Input { let device:AVCaptureDevice }
final class Camera {
    var active=true, captureInFlight=false, currentInputRevision=7, inputRevision=7, capture=Queue(), autoMacroEnabled=true
    var requestedDisplayZoom=1.0, lens=1.0, zoomTarget=1.0, zoomRequestID=0, zoomSettling=false
    var sizesMP:[Int]=[], input:Input?
    func sizeChoices(_ d:AVCaptureDevice, highResolution:Bool)->[Int]{ [12] }
    func mainZoom(_ d:AVCaptureDevice)->Bool{ true }
    func setFallbackLenses(_ d:AVCaptureDevice,displayZoom:Double){}
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
        precondition(zoomRequestID==1 && zoomTarget==3 && lens==1 && zoomSettling)
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
    }
}
Camera().check()
print("PASS display zoom, duplicate ramp, retarget, rejected stale input, rear restoration, clamped target and busy acknowledgment")
`;
if (!method('private func replaceBackInput(').includes('if accepted { advanceInputRevision() }') ||
    !method('func flip(inputRevision:').includes('self.advanceInputRevision()')) {
    throw Error('Each successful input replacement must invalidate commands for the old camera');
}
execFileSync('swift',['-'],{input:swift,stdio:['pipe','inherit','inherit']});
