import Foundation
import AVFoundation
import VideoToolbox

private enum FixtureError: Error { case data(OSStatus), invalidBuffer }
private func check(_ code:OSStatus) throws { guard code == noErr else { throw FixtureError.data(code) } }

private func verifyDolbyMetadataChecks() throws {
    var configuration = Data(repeating:0,count:23)
    configuration[0] = 1; configuration[1] = 2; configuration[16] = 0xfd
    configuration[17] = 0xfa; configuration[18] = 0xfa
    precondition(DolbyMovie.main10(configuration))
    configuration[17] = 0xf8
    precondition(!DolbyMovie.main10(configuration))
    precondition(DolbyMovie.profile84(Data([1,0,16,29,64])))
    precondition(!DolbyMovie.profile84(Data([1,0,16,29,16])))

    func containsRPU(_ bytes:[UInt8]) throws -> Bool {
        var buffer:CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:bytes.count,
            blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,
            dataLength:bytes.count,flags:0,blockBufferOut:&buffer))
        guard let buffer else { throw FixtureError.invalidBuffer }
        try bytes.withUnsafeBytes {
            try check(CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:buffer,
                    offsetIntoDestination:0,dataLength:$0.count))
        }
        return DolbyMovie.hasRPU(buffer,lengthBytes:4)
    }
    let idr:[UInt8] = [0,0,0,3,38,1,0]
    let rpu:[UInt8] = [0,0,0,3,124,1,25]
    let negative = try containsRPU(idr), positive = try containsRPU(idr+rpu)
    let truncated = try containsRPU(idr+Array(rpu.dropLast()))
    precondition(!negative && positive && !truncated)
    print("PASS Main10 and Dolby Vision 8.4 configuration, RPU NAL presence and truncation")
}

private func image(_ width:Int,_ height:Int,_ level:UInt16) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs:[String:Any] = [kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
    try check(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,attrs as CFDictionary,&pixelBuffer))
    guard let buffer = pixelBuffer else { throw FixtureError.invalidBuffer }
    try check(CVPixelBufferLockBaseAddress(buffer,[]))
    for plane in 0..<2 {
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)/2
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.assumingMemoryBound(to:UInt16.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer,plane) {
            for x in 0..<width { base[y*row+x] = (plane == 0 ? (x < width/2 ? level : 800) : 512) << 6 }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer,[])
    for (key,value) in [(kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020),
                        (kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_2100_HLG),
                        (kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020)] {
        CVBufferSetAttachment(buffer,key,value,.shouldPropagate)
    }
    CVBufferSetAttachment(buffer,kCVImageBufferAmbientViewingEnvironmentKey,Data([0,47,233,160,61,19,64,66]) as CFData,.shouldPropagate)
    return buffer
}
private func video(_ buffer:CVPixelBuffer,_ index:Int) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
    try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescriptionOut:&format))
    var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),
               presentationTimeStamp:CMTime(value:Int64(index),timescale:30),decodeTimeStamp:.invalid)
    try check(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,
                  formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample))
    guard let sample else { throw FixtureError.invalidBuffer }; return sample
}
private func sound(_ index:Int) throws -> CMSampleBuffer {
    let samples = 1600
    var pcm = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,
        mFormatFlags:kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,mBytesPerPacket:2,
        mFramesPerPacket:1,mBytesPerFrame:2,mChannelsPerFrame:1,mBitsPerChannel:16,mReserved:0)
    var format:CMAudioFormatDescription?, block:CMBlockBuffer?, sample:CMSampleBuffer?
    try check(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&pcm,layoutSize:0,layout:nil,
        magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format))
    try check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:samples*2,
        blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:samples*2,flags:0,blockBufferOut:&block))
    let phaseStep = 2.0 * Double.pi * 440.0 / 48000.0
    let values:[Int16] = (0..<samples).map { i in Int16(4000.0*sin(Double(index*samples+i)*phaseStep)) }
    try values.withUnsafeBytes {
        try check(CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:$0.count))
    }
    var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),
        presentationTimeStamp:CMTime(value:Int64(index*samples),timescale:48000),decodeTimeStamp:.invalid)
    var bytes = 2
    try check(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format!,
        sampleCount:samples,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&bytes,
        sampleBufferOut:&sample))
    guard let sample else { throw FixtureError.invalidBuffer }; return sample
}

private func verifyRenderedChart(_ asset:AVAsset,_ track:AVAssetTrack) throws {
    let reader = try AVAssetReader(asset:asset)
    let frames = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    reader.add(frames)
    guard reader.startReading(), let sample = frames.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
        throw reader.error ?? FixtureError.invalidBuffer
    }
    defer { reader.cancelReading() }
    try check(CVPixelBufferLockBaseAddress(pixels,.readOnly))
    defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw FixtureError.invalidBuffer }
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    let middle = base.advanced(by:height/2*CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to:UInt8.self)
    let dark = Int(middle[(width/4)*4+1]), bright = Int(middle[(width*3/4)*4+1])
    precondition(bright-dark > 25,"Encoded FL2 chart collapsed to \(dark) and \(bright)")
    print("PASS decoded FL2 MOV center scanline dark \(dark), bright \(bright)")
}

@main struct MovieRecordingFixture {
    static func main() async throws {
        try verifyDolbyMetadataChecks()
        var clock = MovieClock(fps:30)
        let t = CMTime(value:300,timescale:30)
        precondition(clock.audio(t,duration:clock.frameDuration) == nil)
        precondition(clock.video(t) == .zero)
        precondition(clock.audio(t,duration:clock.frameDuration) == .zero)
        clock.pause(true)
        precondition(clock.video(t + CMTime(value:1,timescale:1)) == nil)
        clock.pause(false)
        let after = t + CMTime(value:30,timescale:1)
        precondition(clock.video(after) == clock.frameDuration)
        precondition(clock.audio(after,duration:clock.frameDuration) == clock.frameDuration)
        print("PASS movie timeline removes paused duration and keeps audio/video aligned")
        let width = 1280, height = 720
        var hardware: VTCompressionSession?
        let hardwareStatus = VTCompressionSessionCreate(allocator:nil,width:Int32(width),height:Int32(height),codecType:kCMVideoCodecType_HEVC,
            encoderSpecification:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:true] as CFDictionary,
            imageBufferAttributes:nil,compressedDataAllocator:nil,outputCallback:nil,refcon:nil,compressionSessionOut:&hardware)
        if let hardware { VTCompressionSessionInvalidate(hardware) }
        let recorder = try MovieRecorder(width:width,height:height,fps:30,recipe:Recipe(aspect:"16:9",look:.FL2,strength:0.5),
            transform:.identity,onFailure:{
                FileHandle.standardError.write(Data("Encoder event: \($0.localizedDescription)\n".utf8))
            })
        let chart = try image(width,height,320)
        var acceptedFrames = 0
        recorder.appendAudio(try sound(0))
        for i in 0..<60 {
            if i == 30 {
                recorder.setPaused(true); recorder.appendAudio(try sound(60)); recorder.appendVideo(try video(chart,60)); recorder.setPaused(false)
            }
            let index = i >= 30 ? i+90 : i
            // CI shader warmup and encoder backpressure vary by runner. Step
            // the synthetic clock only after the specified exposure is written.
            let frame = try video(chart,index), expectedEnd = Double(i+1)/30
            let deadline = DispatchTime.now()+5
            repeat {
                recorder.appendVideo(frame)
                try await Task.sleep(nanoseconds:12_000_000)
            } while recorder.elapsed+0.000_001 < expectedEnd && DispatchTime.now() < deadline
            guard recorder.elapsed+0.000_001 >= expectedEnd else {
                FileHandle.standardError.write(Data("Input stalled at frame \(i), writer timeline \(recorder.elapsed)s\n".utf8))
                break
            }
            acceptedFrames += 1
            recorder.appendAudio(try sound(index))
            try await Task.sleep(nanoseconds:23_000_000)
        }
        let result: Result<URL,Error> = await withCheckedContinuation { continuation in
            recorder.finishFile { continuation.resume(returning:$0) }
        }
        if case .failure(let error) = result, hardwareStatus != noErr {
            let software = error as NSError
            // The writer queue also reports specific timing and sample errors.
            // Only AVFoundation/VideoToolbox availability failures are environmental.
            guard software.domain == AVFoundationErrorDomain || software.domain == NSOSStatusErrorDomain else { throw error }
            print("UNAVAILABLE production encode: hardware HEVC probe \(hardwareStatus), encoder \(software.domain) \(software.code): \(software.localizedDescription)")
            return
        }
        let url = try result.get()
        defer { try? FileManager.default.removeItem(at:url) }
        precondition(acceptedFrames == 60,"Writer accepted \(acceptedFrames) of 60 movie frames")
        let asset = AVURLAsset(url:url), duration = try await asset.load(.duration).seconds
        guard duration > 1.80 && duration < 2.15 else { fatalError("Incorrect output duration \(duration)") }
        let videoTracks = try await asset.loadTracks(withMediaType:.video), audioTracks = try await asset.loadTracks(withMediaType:.audio)
        guard let track = videoTracks.first, let microphone = audioTracks.first else { fatalError("Missing encoded track") }
        let videoTime = try await track.load(.timeRange), audioTime = try await microphone.load(.timeRange)
        precondition(abs(videoTime.end.seconds-audioTime.end.seconds) < 0.09 && audioTime.duration.seconds > 1.8)
        let format = try await track.load(.formatDescriptions)[0]
        let codec = CMFormatDescriptionGetMediaSubType(format)
        precondition(codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_DolbyVisionHEVC)
        precondition(CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        print("PASS production HEVC HLG 1280x720+AAC capture over pause/resume: duration \(duration), video \(videoTime.duration.seconds), audio \(audioTime.duration.seconds)")
        try verifyRenderedChart(asset,track)
        do {
            try await DolbyMovie.verify(url)
            print("PASS encoded HEVC Dolby Vision 8.4 with dvvC/dvcC, in-band RPU, BT.2020 HLG and AAC packets")
        } catch {
            guard hardwareStatus != noErr else { throw error }
            print("UNAVAILABLE positive DV hardware encode: HEVC hardware probe \(hardwareStatus); output correctly rejected: \(error.localizedDescription)")
        }
    }
}
