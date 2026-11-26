// Run the production scheduler with a controllable clock, capture samples and render queues.
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const camera = fs.readFileSync(path.join(__dirname, '../Camera.swift'), 'utf8');
function method(signature) {
    const start = camera.indexOf(signature);
    if (start < 0) throw Error('Missing ' + signature);
    let depth = 0;
    for (let i = camera.indexOf('{', start); i < camera.length; ++i) {
        if (camera[i] === '{') ++depth;
        if (camera[i] === '}' && --depth === 0) return camera.slice(start, i + 1);
    }
    throw Error('Unclosed ' + signature);
}
const program = `
import Foundation
import CoreMedia
var now = 1.0
func CACurrentMediaTime() -> Double { now }
typealias CVPixelBuffer = Int
struct Sample { let buffer: Int; let pts: CMTime }
typealias CMSampleBufferStub = Sample
func CMSampleBufferGetImageBuffer(_ sample: Sample) -> Int? { sample.buffer }
func CMSampleBufferGetPresentationTimeStamp(_ sample: Sample) -> CMTime { sample.pts }
struct AVCaptureOutput {}
enum Media { case video }
enum Position { case back, front, unspecified }
enum Look { case original, fl2, fl3, cineG }
struct Port { let mediaType = Media.video; let sourceDevicePosition: Position }
struct AVCaptureConnection { let inputPorts: [Port] }
final class Queue {
    static let main = Queue()
    var jobs: [() -> Void] = []
    func async(_ job: @escaping () -> Void) { jobs.append(job) }
    func run() { precondition(jobs.count == 1); jobs.removeFirst()() }
}
typealias DispatchQueue = Queue
final class Camera {
    let lock = NSLock(), thumbnailQueue = Queue()
    var acceptingPreviewFrames = true, thumbnailRendering = false, nativeThumbnails = false
    var requestedThumbnailEdge: CGFloat = 224
    var nativeThumbnailLooks: [Look] = [], requestedThumbnailLooks: [Look] = []
    var renderedLooks: [[Look]] = []
    var atlasRequest: ((String?) -> Void)?
    var thumbnailGeneration: UInt64 = 0, previewSourceGeneration: UInt64 = 0
    var lastDisplayTime = -Double.infinity, nextThumbnailTime = 0.0
    var lastDisplayPTS = CMTime.invalid, lastThumbnailPTS = CMTime.invalid, earliestPreviewTime = CMTime.invalid
    var expectedPreviewPosition: Position?
    var selected = 0, waitingForPreview: UUID?, latest: Int?, lastDisplayBuffer: Int?
    var thumbnails: [Int:Int] = [:]
    func clearPreviewTransition(_ id: UUID, after: Double) {}
    func renderThumbnailBatch(_ buffer: Int, recipe: Int, generation: UInt64, source: UInt64, edge: CGFloat, looks: [Look], forWeb: Bool) -> (jpeg: String?, tiles: [Int:Int]) {
        precondition(forWeb && edge == 224)
        renderedLooks.append(looks)
        return (String(buffer), [:])
    }
    ${method('func requestThumbnailAtlas(')}
    ${method('func cancelThumbnailAtlas()')}
    ${method('private func scheduleThumbnailsLocked(')}
    ${method('private func suspendPreviewFrames()')}
    ${method('func captureOutput(').replace('sampleBuffer: CMSampleBuffer,', 'sampleBuffer: CMSampleBufferStub,')}
    func suspend() { suspendPreviewFrames() }
    func sample(_ id: Int, _ side: Position = .back) {
        captureOutput(AVCaptureOutput(),didOutput:Sample(buffer:id,pts:CMTime(value:Int64(id),timescale:30)),from:AVCaptureConnection(inputPorts:[Port(sourceDevicePosition:side)]))
    }
    func drain() { thumbnailQueue.run(); DispatchQueue.main.run() }
}
let c = Camera()
var first: [String?] = [], next: [String?] = []
let sony: [Look] = [.original,.fl2,.fl3], ricoh: [Look] = [.original,.cineG]
func open(_ looks:[Look] = sony) { c.requestThumbnailAtlas(edge:224,looks:looks,useLatest:true) { first.append($0) } }
func request() { c.requestThumbnailAtlas(edge:224,looks:sony) { next.append($0) } }
c.sample(1); precondition(c.thumbnailQueue.jobs.isEmpty); open()
c.sample(2); precondition(c.thumbnailQueue.jobs.count == 1); c.drain()
precondition(first == ["1"] && c.atlasRequest == nil)
now += 0.2; request(); precondition(c.thumbnailQueue.jobs.isEmpty)
c.sample(3); c.drain(); precondition(next == ["3"])
now += 0.2; open(); precondition(c.thumbnailQueue.jobs.isEmpty)
c.sample(3); precondition(c.thumbnailQueue.jobs.isEmpty)
c.sample(4); c.drain(); precondition(first == ["1","4"])
now += 0.2; c.sample(5); open(); c.suspend()
c.drain(); precondition(first == ["1","4",nil])
now += 0.2; open(); c.sample(6); precondition(c.thumbnailQueue.jobs.isEmpty)
c.acceptingPreviewFrames = true; c.expectedPreviewPosition = .front
c.earliestPreviewTime = CMTime(value:10,timescale:30)
c.sample(9,.front); c.sample(10,.back); precondition(c.thumbnailQueue.jobs.isEmpty)
c.sample(11,.front); c.drain(); precondition(first == ["1","4",nil,"11"])
now += 0.2; c.sample(12,.front); open(); c.cancelThumbnailAtlas()
open(ricoh); c.sample(13,.front); precondition(c.thumbnailQueue.jobs.count == 1)
c.drain(); precondition(first == ["1","4",nil,"11"])
now += 0.2; c.sample(14,.front); c.drain(); precondition(first.last! == "14")
precondition(Array(c.renderedLooks.suffix(2)) == [sony,ricoh])
now += 0.2; c.sample(15,.front); now += 0.5; open()
precondition(c.thumbnailQueue.jobs.isEmpty); c.sample(16,.front); c.drain()
precondition(first.last! == "16")
// The Web decode acknowledgement can reuse a newer camera frame which arrived while
// the previous atlas was being transferred. An identical PTS never renders twice.
now += 0.2; c.sample(17,.front); c.requestThumbnailAtlas(edge:224,looks:ricoh,useLatest:true){ next.append($0) }
c.drain(); precondition(next.last! == "17")
c.requestThumbnailAtlas(edge:224,looks:ricoh,useLatest:true){ next.append($0) }
precondition(c.thumbnailQueue.jobs.isEmpty)
print("PASS opening frame, backpressure, frame age/PTS, suspended input, in-flight cancellation and reconfiguration")
`;
execFileSync('swift', ['-'], {input:program, stdio:['pipe','inherit','inherit']});
