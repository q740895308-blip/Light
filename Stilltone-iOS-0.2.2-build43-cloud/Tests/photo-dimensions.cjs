const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const source = fs.readFileSync(path.join(__dirname,'../Camera.swift'),'utf8');
function method(signature){
    const start=source.indexOf(signature);
    if(start<0)throw Error('Missing '+signature);
    let depth=0;
    for(let i=source.indexOf('{',start);i<source.length;i++){
        if(source[i]==='{')depth++;
        if(source[i]==='}'&&--depth===0)return source.slice(start,i+1);
    }
    throw Error('Unclosed '+signature)
}
const swift=`
import Foundation
struct CMVideoDimensions: Equatable { let width:Int32, height:Int32 }
func dim(_ width:Int32,_ height:Int32)->CMVideoDimensions { .init(width:width,height:height) }
func CMVideoFormatDescriptionGetDimensions(_ d:CMVideoDimensions)->CMVideoDimensions { d }
final class AVCaptureDevice {
    final class Format {
        let formatDescription:CMVideoDimensions, supportedMaxPhotoDimensions:[CMVideoDimensions]
        init(_ preview:CMVideoDimensions,_ sizes:[CMVideoDimensions]) { formatDescription=preview; supportedMaxPhotoDimensions=sizes }
    }
    var activeFormat:Format; let formats:[Format]
    init(_ formats:[Format]) { self.formats=formats; activeFormat=formats[0] }
    func lockForConfiguration() throws {}
    func unlockForConfiguration() {}
}
struct Output { var maxPhotoDimensions=dim(0,0) }
final class Camera {
    var usingDedicatedWide=false, photos=Output()
    func report(_ issue:String) { fatalError(issue) }
    ${method('private func mp(')}
    ${method('private func directSizes(')}
    ${method('private func captureSizes(')}
    ${method('private func preparePhotoFormat(')}
    ${method('private func sizeChoices(')}
    func check() {
        let seven=dim(3088,2320),eight=dim(3264,2448),twelve=dim(4032,3024)
        let eighteen=dim(4240,4240),deferred=dim(5712,4284),high=dim(8064,6048)
        let preview=dim(1920,1080),small=dim(640,480)
        let current=AVCaptureDevice.Format(preview,[eighteen,seven,eight,deferred])
        let front=AVCaptureDevice([current])
        preparePhotoFormat(front);precondition(front.activeFormat === current)
        photos.maxPhotoDimensions=directSizes(current.supportedMaxPhotoDimensions).last!
        precondition(sizeChoices(front,highResolution:false)==[7,8,18])
        photos.maxPhotoDimensions=eight
        precondition(captureSizes(front)==[seven,eight])
        let proxy=AVCaptureDevice.Format(preview,[deferred])
        let normal=AVCaptureDevice.Format(small,[seven]),best=AVCaptureDevice.Format(preview,[twelve])
        let full=AVCaptureDevice.Format(preview,[twelve,high])
        let device=AVCaptureDevice([proxy,normal,best,full])
        precondition(directSizes(proxy.supportedMaxPhotoDimensions).isEmpty)
        preparePhotoFormat(device);precondition(device.activeFormat === best)
        usingDedicatedWide=true;preparePhotoFormat(device);precondition(device.activeFormat === full)
        photos.maxPhotoDimensions=high;precondition(sizeChoices(device,highResolution:false)==[48])
        usingDedicatedWide=false;photos.maxPhotoDimensions=twelve
        precondition(sizeChoices(device,highResolution:true)==[12])
    }
}
Camera().check()
print("PASS exact output limits, normal 7/8/18 MP, deferred-only format fallback, and physical-wide 48 MP")
`;
execFileSync('swift',['-'],{input:swift,stdio:['pipe','inherit','inherit']});
