import AVFoundation
import CoreImage
import Photos
import VideoToolbox
import Metal

private struct MovieIssue: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

// Both capture outputs use the same camera clock. Start and resume on a video
// boundary, and apply the same offset to every audio presentation timestamp.
struct MovieClock {
    let frameDuration: CMTime
    private(set) var lastVideo = CMTime.invalid
    private var sourceStart = CMTime.invalid
    private var segmentStart = CMTime.zero
    private var audioEnd = CMTime.zero
    private(set) var paused = false

    init(fps: Int) { frameDuration = CMTime(value:1,timescale:Int32(fps)) }
    var end: CMTime { lastVideo.isNumeric ? CMTimeMaximum(lastVideo + frameDuration,audioEnd) : .zero }
    mutating func pause(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        if value { segmentStart = end; sourceStart = .invalid }
    }
    mutating func video(_ pts: CMTime) -> CMTime? {
        guard !paused, pts.isNumeric else { return nil }
        if !sourceStart.isNumeric { sourceStart = pts }
        let out = segmentStart + (pts-sourceStart)
        guard out >= .zero, !lastVideo.isNumeric || out > lastVideo else { return nil }
        lastVideo = out
        return out
    }
    mutating func audio(_ pts: CMTime, duration: CMTime) -> CMTime? {
        guard !paused, sourceStart.isNumeric, pts >= sourceStart, duration.isNumeric, duration > .zero else { return nil }
        let out = segmentStart + (pts-sourceStart)
        guard CMTimeGetSeconds(out-audioEnd) >= -0.00002 else { return nil }
        audioEnd = out+duration
        return out
    }
}

enum DolbyMovie {
    static func main10(_ record: Data) -> Bool {
        let bytes = [UInt8](record.prefix(23))
        // HEVCDecoderConfigurationRecord: profile_idc, chromaFormat and component depth.
        return bytes.count == 23 && bytes[0] == 1 && bytes[1] & 31 == 2 &&
            bytes[16] & 3 == 1 && bytes[17] & 7 == 2 && bytes[18] & 7 == 2
    }

    static func profile84(_ config: Data) -> Bool {
        let bytes = [UInt8](config.prefix(5))
        return bytes.count == 5 && bytes[0] == 1 && bytes[2] >> 1 == 8 &&
            bytes[3] & 7 == 5 && bytes[4] >> 4 == 4
    }

    static func hasRPU(_ data: CMBlockBuffer, lengthBytes: Int) -> Bool {
        guard (1...4).contains(lengthBytes) else { return false }
        let total = CMBlockBufferGetDataLength(data)
        var cursor = 0
        var header = [UInt8](repeating:0,count:lengthBytes+2)
        while total-cursor >= header.count {
            let status = header.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data,atOffset:cursor,dataLength:$0.count,destination:$0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { return false }
            let length = header.prefix(lengthBytes).reduce(0) { $0*256 + Int($1) }
            guard length >= 2, length <= total-cursor-lengthBytes else { return false }
            if ((header[lengthBytes] >> 1) & 63) == 62, length > 2 { return true }
            cursor += lengthBytes + length
        }
        return false
    }

    static func verify(_ url: URL) async throws {
        let asset = AVURLAsset(url:url)
        guard let video = try await asset.loadTracks(withMediaType:.video).first,
              let audio = try await asset.loadTracks(withMediaType:.audio).first,
              let description = try await video.load(.formatDescriptions).first,
              let sound = try await audio.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(sound) == kAudioFormatMPEG4AAC else {
            throw MovieIssue("视频文件缺少画面或麦克风音轨。")
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        let atoms = CMFormatDescriptionGetExtension(description,extensionKey:kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String:Any]
        guard codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_DolbyVisionHEVC,
              let hvcC = atoms?["hvcC"] as? Data, main10(hvcC),
              let config = (atoms?["dvvC"] ?? atoms?["dvcC"]) as? Data, profile84(config),
              CMFormatDescriptionGetExtension(description,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
              CMFormatDescriptionGetExtension(description,extensionKey:kCMFormatDescriptionExtension_ColorPrimaries) as? String == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String else {
            throw MovieIssue("编码器未生成 HEVC 杜比视界 8.4 视频。")
        }
        // Read real compressed samples. HLG color tags alone do not establish DV.
        let reader = try AVAssetReader(asset:asset)
        let images = AVAssetReaderTrackOutput(track:video,outputSettings:nil)
        let sounds = AVAssetReaderTrackOutput(track:audio,outputSettings:nil)
        images.alwaysCopiesSampleData = false
        sounds.alwaysCopiesSampleData = false
        guard reader.canAdd(images), reader.canAdd(sounds) else { throw MovieIssue("无法验证视频和音轨。") }
        reader.add(images); reader.add(sounds)
        guard reader.startReading() else { throw reader.error ?? MovieIssue("读取视频失败。") }
        defer { reader.cancelReading() }
        guard let packet = sounds.copyNextSampleBuffer(), CMSampleBufferGetNumSamples(packet) > 0 else {
            throw MovieIssue("麦克风音轨为空。")
        }
        let lengthBytes = Int(hvcC[hvcC.startIndex+21] & 3) + 1
        for _ in 0..<120 {
            guard let sample = images.copyNextSampleBuffer() else { break }
            if let data = CMSampleBufferGetDataBuffer(sample), hasRPU(data,lengthBytes:lengthBytes) { return }
        }
        throw MovieIssue("视频帧缺少杜比视界动态元数据。")
    }
}

final class MovieRecorder {
    private let queue = DispatchQueue(label:"stilltone.movie.writer",qos:.userInitiated)
    private let videoSlots = DispatchSemaphore(value:3)
    private let audioSlots = DispatchSemaphore(value:32)
    private let writer: AVAssetWriter
    private let picture: AVAssetWriterInput
    private var sound: AVAssetWriterInput?
    private let buffers: AVAssetWriterInputPixelBufferAdaptor
    private let file: URL
    private let size: CGSize
    private let fps: Int
    private let transform: CGAffineTransform
    private let recipe: Recipe
    private let renderer = Renderer()
    private let context: CIContext
    private let hlg = CGColorSpace(name:CGColorSpace.itur_2100_HLG)!
    private let onFailure: (Error)->Void
    private var clock: MovieClock
    private let durationLock = NSLock()
    private var durationSeconds = 0.0
    private var latest: CVPixelBuffer?
    private var receivedSound = false
    private var failure: Error?
    private var stopping = false
    private var cadenceStart = CMTime.invalid
    private var cadenceCount = 0

    init(width:Int,height:Int,fps:Int,recipe:Recipe,transform:CGAffineTransform,onFailure:@escaping(Error)->Void) throws {
        guard width > 0, height > 0, [24,30,60].contains(fps) else { throw MovieIssue("不支持所选录像规格。") }
        self.size = CGSize(width:width,height:height)
        self.fps = fps; self.recipe = recipe; self.transform = transform; self.onFailure = onFailure
        clock = MovieClock(fps:fps)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StilltoneRecording",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        file = directory.appendingPathComponent(UUID().uuidString+".mov")
        writer = try AVAssetWriter(outputURL:file,fileType:.mov)
        let hdr: [String:Any] = [AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_2020,
                                 AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_2100_HLG,
                                 AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_2020]
        let compression: [String:Any] = [
            AVVideoProfileLevelKey:kVTProfileLevel_HEVC_Main10_AutoLevel,
            AVVideoExpectedSourceFrameRateKey:fps, AVVideoMaxKeyFrameIntervalKey:fps,
            AVVideoAverageBitRateKey:Int(Double(width*height*fps)*0.14),
            kVTCompressionPropertyKey_HDRMetadataInsertionMode as String:kVTHDRMetadataInsertionMode_Auto,
            kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String:false
        ]
        let settings: [String:Any] = [AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:width,AVVideoHeightKey:height,
                                      AVVideoColorPropertiesKey:hdr,AVVideoCompressionPropertiesKey:compression]
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw MovieIssue("设备无法编码所选 HEVC 杜比视界规格。") }
        picture = AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        picture.expectsMediaDataInRealTime = true
        picture.transform = transform
        let attributes: [String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
        buffers = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:picture,sourcePixelBufferAttributes:attributes)
        guard writer.canAdd(picture) else { throw MovieIssue("无法创建杜比视界视频轨。") }
        writer.add(picture)
        let options:[CIContextOption:Any] = [.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB)!,
                                                .workingFormat:CIFormat.RGBAh.rawValue,.cacheIntermediates:false]
        if let gpu = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice:gpu,options:options) }
        else { context = CIContext(options:options) }
        queue.asyncAfter(deadline:.now()+5) { [weak self] in
            guard let self, !self.stopping, !self.clock.paused, !self.receivedSound else { return }
            self.fail(MovieIssue("没有收到麦克风和相机的同步数据，请检查设备权限。"))
        }
    }

    var elapsed: Double {
        durationLock.lock(); defer { durationLock.unlock() }; return durationSeconds
    }
    func setPaused(_ paused:Bool) { queue.async { self.clock.pause(paused); self.cadenceStart = .invalid } }
    private func fail(_ error:Error) {
        guard failure == nil, !stopping else { return }
        failure = error
        DispatchQueue.main.async { self.onFailure(error) }
    }

    func appendVideo(_ sample:CMSampleBuffer) {
        guard videoSlots.wait(timeout:.now()) == .success else { return }
        queue.async {
            defer { self.videoSlots.signal() }
            autoreleasepool { self.writeVideo(sample) }
        }
    }
    func appendAudio(_ sample:CMSampleBuffer) {
        guard audioSlots.wait(timeout:.now()) == .success else {
            queue.async { self.fail(MovieIssue("录音处理速度不足，已停止录像。")) }
            return
        }
        queue.async {
            defer { self.audioSlots.signal() }
            autoreleasepool { self.writeAudio(sample) }
        }
    }

    private func writeAudio(_ sample:CMSampleBuffer) {
        guard !stopping, failure == nil, !clock.paused, CMSampleBufferGetNumSamples(sample)>0,
              let format = CMSampleBufferGetFormatDescription(sample),
              let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        if sound == nil {
            let channels = max(1,min(2,Int(audio.mChannelsPerFrame)))
            let settings: [String:Any] = [AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,
                                          AVNumberOfChannelsKey:channels,AVEncoderBitRateKey:channels*96000]
            let input = AVAssetWriterInput(mediaType:.audio,outputSettings:settings,sourceFormatHint:format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { fail(MovieIssue("无法建立麦克风音轨。")); return }
            writer.add(input); sound = input
            guard writer.startWriting() else { fail(writer.error ?? MovieIssue("编码器无法开始录像。")); return }
            writer.startSession(atSourceTime:.zero)
        }
        guard let sound, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
        var next = clock
        guard let adjusted = next.audio(pts,duration:duration) else { return }
        if next.lastVideo.isNumeric && (adjusted-next.lastVideo).seconds > 1 {
            fail(MovieIssue("取景视频帧中断，已停止录像。")); return
        }
        guard sound.isReadyForMoreMediaData else { fail(MovieIssue("音频编码器无法及时写入麦克风数据。")); return }
        do {
            let retimed = try Self.retime(sample, offset:pts-adjusted)
            guard sound.append(retimed) else { throw writer.error ?? MovieIssue("录音写入失败。") }
            clock = next; receivedSound = true
        } catch { fail(error) }
    }

    private static func retime(_ sample:CMSampleBuffer,offset:CMTime) throws -> CMSampleBuffer {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:0,arrayToFill:nil,entriesNeededOut:&count) == noErr, count > 0 else {
            throw MovieIssue("录音时间信息不完整。")
        }
        var times = [CMSampleTimingInfo](repeating:CMSampleTimingInfo(),count:count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample,entryCount:count,arrayToFill:&times,entriesNeededOut:nil) == noErr else {
            throw MovieIssue("无法读取录音时间信息。")
        }
        for i in times.indices {
            if times[i].presentationTimeStamp.isNumeric { times[i].presentationTimeStamp = times[i].presentationTimeStamp-offset }
            if times[i].decodeTimeStamp.isNumeric { times[i].decodeTimeStamp = times[i].decodeTimeStamp-offset }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:sample,
            sampleTimingEntryCount:count,sampleTimingArray:&times,sampleBufferOut:&result) == noErr, let result else {
            throw MovieIssue("无法同步麦克风数据。")
        }
        return result
    }

    private func writeVideo(_ sample:CMSampleBuffer) {
        guard !stopping, failure == nil, !clock.paused, sound != nil else { return }
        guard writer.status == .writing else { fail(writer.error ?? MovieIssue("视频编码已中断。")); return }
        guard picture.isReadyForMoreMediaData, let input = CMSampleBufferGetImageBuffer(sample) else { return }
        var next = clock
        guard let pts = next.video(CMSampleBufferGetPresentationTimeStamp(sample)) else { return }
        do {
            let buffer = try encodedBuffer(input,description:CMSampleBufferGetFormatDescription(sample))
            guard buffers.append(buffer,withPresentationTime:pts) else { throw writer.error ?? MovieIssue("视频帧写入失败。") }
            clock = next; latest = buffer
            durationLock.lock(); durationSeconds = next.end.seconds; durationLock.unlock()
            if !cadenceStart.isNumeric { cadenceStart = pts; cadenceCount = 0 }
            else { cadenceCount += 1 }
            let span = (pts-cadenceStart).seconds
            if span >= 3 {
                guard Double(cadenceCount)/span >= Double(fps)*0.9 else {
                    throw MovieIssue("当前设备未能保持所选帧率，请选择 4K 30 或高清 60。")
                }
                cadenceStart = pts; cadenceCount = 0
            }
        } catch { fail(error) }
    }

    private func encodedBuffer(_ source:CVPixelBuffer,description:CMFormatDescription?) throws -> CVPixelBuffer {
        let pixelType = CVPixelBufferGetPixelFormatType(source)
        let transfer = CVBufferCopyAttachment(source,kCVImageBufferTransferFunctionKey,nil) as? String ??
            description.flatMap { CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String }
        guard [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr10BiPlanarFullRange].contains(pixelType),
              transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String else {
            throw MovieIssue("相机未输出十位 HLG 视频，请重新选择录像规格。")
        }
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        guard (sourceWidth >= sourceHeight) == (size.width >= size.height) else { throw MovieIssue("录像画面方向与编码规格不一致。") }
        if !recipe.requiresRenderedPreview && sourceWidth == Int(size.width) && sourceHeight == Int(size.height) { return source }
        guard let pool = buffers.pixelBufferPool else { throw MovieIssue("无法创建 HDR 帧缓冲区。") }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&output) == kCVReturnSuccess, let output else { throw MovieIssue("HDR 帧缓冲区不足。") }
        CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
        if #available(iOS 15.0,macOS 12.0,*) {
            let ambient = CVBufferCopyAttachment(source,kCVImageBufferAmbientViewingEnvironmentKey,nil) ??
                description.flatMap { CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_AmbientViewingEnvironment) }
            if let ambient { CVBufferSetAttachment(output,kCVImageBufferAmbientViewingEnvironmentKey,ambient,.shouldPropagate) }
        }
        let frame = CIImage(cvPixelBuffer:source,options:[.colorSpace:hlg])
        guard let framing = PreviewFraming(buffer:source,target:size) else { throw MovieIssue("无法确定视频帧的取景范围。") }
        let base = framing.frame(frame)
        var styled = base
        if recipe.requiresRenderedPreview {
            var color = recipe; color.aspect = "原始"
            // The photo cubes cover SDR. Apply their correction in that domain
            // and add the extended highlights back in the floating-point graph.
            let bounded = base.applyingFilter("CIColorClamp",parameters:["inputMinComponents":CIVector(x:0,y:0,z:0,w:0),
                                                                         "inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
            let excess = bounded.applyingFilter("CISubtractBlendMode",parameters:[kCIInputBackgroundImageKey:base])
            styled = try renderer.image(bounded,color).applyingFilter("CIAdditionCompositing",
                                                parameters:[kCIInputBackgroundImageKey:excess]).cropped(to:base.extent)
        }
        context.render(styled,to:output,bounds:CGRect(origin:.zero,size:size),colorSpace:hlg)
        return output
    }

    private func orientedImage(_ buffer:CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer:buffer).transformed(by:CGAffineTransform(a:transform.a,b:-transform.b,
                                                                      c:-transform.c,d:transform.d,tx:0,ty:0))
    }
    func requestThumbnail(_ completion:@escaping(CGImage?)->Void) {
        queue.async {
            guard let buffer = self.latest else { completion(nil); return }
            DispatchQueue.global(qos:.userInitiated).async {
                let image = self.orientedImage(buffer), bounds = image.extent
                let scale = min(1,240/max(bounds.width,bounds.height))
                let small = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                completion(self.context.createCGImage(small,from:small.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
            }
        }
    }
    func snapshot(_ completion:@escaping(Result<String,Error>)->Void) {
        queue.async {
            guard !self.stopping, let buffer = self.latest else { completion(.failure(MovieIssue("还没有可抓拍的视频帧。"))); return }
            // Keep still encoding off the movie queue during high-frame-rate recording.
            DispatchQueue.global(qos:.userInitiated).async {
                do {
                    let rotated = self.orientedImage(buffer)
                    let data = self.context.heifRepresentation(of:rotated,format:.RGBA8,
                                         colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,options:[:])
                    guard let data else { throw MovieIssue("无法生成抓拍照片。") }
                    Task {
                        do { completion(.success(try await Self.storePhoto(data))) }
                        catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            }
        }
    }

    func finishFile(_ completion:@escaping(Result<URL,Error>)->Void) {
        queue.async {
            guard !self.stopping else { completion(.failure(MovieIssue("录像正在保存。"))); return }
            self.stopping = true
            guard self.writer.status == .writing, self.clock.lastVideo.isNumeric, self.receivedSound else {
                let error = self.writer.error ?? self.failure ?? MovieIssue("没有足够的音视频数据可以保存。")
                if self.writer.status == .writing { self.writer.cancelWriting() }
                try? FileManager.default.removeItem(at:self.file)
                completion(.failure(error)); return
            }
            self.writer.endSession(atSourceTime:self.clock.end)
            self.picture.markAsFinished(); self.sound?.markAsFinished(); self.latest = nil
            self.writer.finishWriting {
                guard self.writer.status == .completed else {
                    try? FileManager.default.removeItem(at:self.file)
                    completion(.failure(self.writer.error ?? MovieIssue("录像文件未能完成。"))); return
                }
                completion(.success(self.file))
            }
        }
    }

    func stop(_ completion:@escaping(Result<String,Error>)->Void) {
        finishFile { result in
            Task {
                do {
                    let url = try result.get()
                    let manager = FileManager.default
                    let documents = try manager.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                    let folder = documents.appendingPathComponent("待检查录像",isDirectory:true)
                    try manager.createDirectory(at:folder,withIntermediateDirectories:true)
                    let recovery = folder.appendingPathComponent(url.lastPathComponent)
                    try manager.moveItem(at:url,to:recovery)
                    let pending: URL
                    do {
                        try await DolbyMovie.verify(recovery)
                        pending = try Self.pendingDirectory().appendingPathComponent(url.lastPathComponent)
                        try manager.moveItem(at:recovery,to:pending)
                    } catch {
                        throw MovieIssue("\(error.localizedDescription) 录像已保留在“文件”中的 Stilltone／待检查录像。")
                    }
                    completion(.success(try await Self.library.save(pending)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static let library = MovieLibrary()
    private static func pendingDirectory() throws -> URL {
        let support = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let folder = support.appendingPathComponent("PendingVideo",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder
    }
    static func retryPendingSaves(_ completion:@escaping(Result<[String],Error>)->Void) {
        Task {
            do {
                let files = try FileManager.default.contentsOfDirectory(at:pendingDirectory(),includingPropertiesForKeys:nil)
                var ids = [String]()
                for url in files where url.pathExtension == "mov" {
                    ids.append(try await library.save(url))
                }
                completion(.success(ids))
            } catch { completion(.failure(error)) }
        }
    }
    fileprivate static func authorizeSave() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for:.addOnly)
        guard status == .authorized || status == .limited else { throw MovieIssue("请在设置中允许添加到照片，然后重试保存。") }
    }
    private static func storePhoto(_ data:Data) async throws -> String {
        try await authorizeSave()
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let item = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions(); options.originalFilename = "Stilltone-"+UUID().uuidString+".heic"
            item.addResource(with:.photo,data:data,options:options); id = item.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id else { throw MovieIssue("未获得抓拍照片的相册标识。") }; return id
    }
}

// Share in-flight PhotoKit operations between the original save and a retry.
private actor MovieLibrary {
    private var inFlight = [URL:Task<String,Error>]()
    func save(_ url:URL) async throws -> String {
        if let saving = inFlight[url] { return try await saving.value }
        let saving = Task<String,Error> {
            try await MovieRecorder.authorizeSave()
            var id: String?
            try await PHPhotoLibrary.shared().performChanges {
                let item = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Stilltone-"+url.lastPathComponent
                options.shouldMoveFile = true
                item.addResource(with:.video,fileURL:url,options:options)
                id = item.placeholderForCreatedAsset?.localIdentifier
            }
            guard let id else { throw MovieIssue("未获得录像的相册标识。") }
            return id
        }
        inFlight[url] = saving
        defer { inFlight.removeValue(forKey:url) }
        return try await saving.value
    }
}
