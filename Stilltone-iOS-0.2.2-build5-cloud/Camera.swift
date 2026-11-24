import SwiftUI
import AVFoundation
import CoreImage
import MetalKit
import Photos
import PhotosUI
import ImageIO
import Vision
import UniformTypeIdentifiers

enum Look: String, CaseIterable {
    case original, FL2, FL3, positive = "GR-Positive", negative = "Classic-Negative", nostalgic = "Nostalgic-Negative", chrome = "Classic-Chrome"
    var title: String {
        switch self { case .original: return "原图"; case .positive: return "GR 正片"; case .negative: return "富士NC"; case .nostalgic: return "富士NN"; case .chrome: return "富士 CC"; default: return rawValue }
    }
}

struct Recipe {
    var aspect = "原始"
    var look = Look.original
    var strength = 1.0
    var ev = 0.0
}

enum PhotoFormat: String, CaseIterable { case heif = "HEIF", jpeg = "JPEG", raw = "RAW" }
struct FileSettings {
    var live = false
    var night = false
    var format = PhotoFormat.heif
    var quality = 0.9
    var megapixels = 12
}

final class Renderer {
    private let gpu: MTLDevice?
    init(gpu: MTLDevice? = nil) { self.gpu = gpu }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false]
        if let gpu { return CIContext(mtlDevice: gpu, options: options) }; return CIContext(options: options)
    }()
    private var tables = [Look: Data]()
    func image(_ source: CIImage, _ recipe: Recipe) throws -> CIImage {
        var source = source
        if recipe.aspect != "原始" {
            let bounds = source.extent, landscape = bounds.width >= bounds.height
            let ratio: CGFloat = recipe.aspect == "1:1" ? 1 : recipe.aspect == "16:9" ? (landscape ? 16.0/9 : 9.0/16) : (landscape ? 4.0/3 : 3.0/4)
            let width = min(bounds.width,bounds.height*ratio), height = width/ratio
            let crop = CGRect(x:floor(bounds.midX-width/2),y:floor(bounds.midY-height/2),width:floor(width),height:floor(height))
            source = source.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        }
        let base = recipe.ev == 0 ? source : source.applyingFilter("CIColorMatrix", parameters: Dictionary(uniqueKeysWithValues: ["inputRVector", "inputGVector", "inputBVector"].enumerated().map { index, key in
            let gain = CGFloat(pow(2.0, recipe.ev / 2.2))
            return (key, CIVector(x: index == 0 ? gain : 0, y: index == 1 ? gain : 0, z: index == 2 ? gain : 0, w: 0))
        }))
        guard recipe.look != .original, recipe.strength > 0 else { return base }
        if tables[recipe.look] == nil {
            guard let url = Bundle.main.url(forResource: recipe.look.rawValue, withExtension: "rgba"), let data = try? Data(contentsOf: url), data.count == 33*33*33*16 else { throw CocoaError(.fileReadCorruptFile) }
            tables[recipe.look] = data
        }
        let filtered = base.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 33, "inputCubeData": tables[recipe.look]!])
        return recipe.strength == 1 ? filtered : base.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": filtered, "inputTime": recipe.strength]).cropped(to: base.extent)
    }
}

final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var lenses: [Double] = [1]
    @Published var lens: Double = 1
    @Published var still: UIImage?
    @Published var ready = false
    @Published var busy = false
    @Published var message: String?
    @Published var flashAvailable = false
    @Published var rawAvailable = false
    @Published var liveAvailable = false
    private var nightRequested = false
    private var nightFrames = [Data]()
    private var nightTemplate: AVCapturePhotoSettings?
    private var nightAttempts = 0
    func setNight(_ enabled: Bool) { capture.async { self.nightRequested = enabled; self.applyLowLightBoost() } }
    private func applyLowLightBoost() {
        guard let device = input?.device, device.isLowLightBoostSupported else { return }
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; device.automaticallyEnablesLowLightBoostWhenAvailable = nightRequested } catch { report(error.localizedDescription) }
    }
    private var liveStill: Data?, liveURL: URL?, liveError: Error?
    @Published var heifAvailable = false
    @Published var sizesMP: [Int] = []
    private func mp(_ size: CMVideoDimensions) -> Int { Int((Double(size.width) * Double(size.height) / 1_000_000).rounded()) }
    let session = AVCaptureSession()
    private let capture = DispatchQueue(label: "fl.capture")
    private let frames = DispatchQueue(label: "fl.frames")
    private let processing = DispatchQueue(label: "fl.photo")
    private let stillRenderer = Renderer()
    private let photos = AVCapturePhotoOutput(), video = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var selected = Recipe(), shot = Recipe()
    private var shotFile = FileSettings()
    @Published var thumbnails = [Look:UIImage]()
    private var capturePose: AVCaptureVideoOrientation = .portrait
    func setPose(_ pose: UIDeviceOrientation) { capture.async {
        switch pose { case .portrait: self.capturePose = .portrait; case .portraitUpsideDown: self.capturePose = .portraitUpsideDown; case .landscapeLeft: self.capturePose = .landscapeRight; case .landscapeRight: self.capturePose = .landscapeLeft; default: return }
        for output in [self.video as AVCaptureOutput,self.photos as AVCaptureOutput] { if let connection = output.connection(with:.video),connection.isVideoOrientationSupported { connection.videoOrientation = self.capturePose } }
    } }
    private var thumbnailMenu = false, thumbnailBusy = false, thumbnailTime = -Double.infinity
    private let thumbnailQueue = DispatchQueue(label:"fl.thumbnails",qos:.utility), thumbnailRenderer = Renderer()
    func enableThumbnails(_ enabled:Bool) { lock.lock(); thumbnailMenu = enabled; lock.unlock() }
    private var latest: CVPixelBuffer?
    private let lock = NSLock()
    func previewFrame() -> (CVPixelBuffer, Recipe)? {
        lock.lock(); defer { lock.unlock() }; guard let latest else { return nil }; self.latest = nil; return (latest, selected)
    }
    private var active = false
    private var captureInFlight = false
    func update(_ recipe: Recipe) { lock.lock(); selected = recipe; lock.unlock() }
    private func current() -> Recipe { lock.lock(); defer { lock.unlock() }; return selected }
    private func report(_ text: String) { DispatchQueue.main.async { self.message = text } }
    func start() {
        capture.async { self.active = true; self.authorize() }
    }
    private func authorize() {
        guard active else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if input == nil { configure() }
            guard input != nil else { return }
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            DispatchQueue.main.async { self.ready = running }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in self.capture.async { self.authorize() } }
        default: report("未获得相机权限。请在设置中允许访问相机，或从相册导入照片。")
        }
    }
    func stop() { capture.async { self.active = false; if self.session.isRunning { self.session.stopRunning() }; DispatchQueue.main.async { self.ready = false } } }
    private func deviceInput(_ position: AVCaptureDevice.Position, type: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(type, for: .video, position: position) else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }
    private func wideFactor(_ device: AVCaptureDevice) -> CGFloat {
        let factors = [CGFloat(1)] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        guard let index = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), index < factors.count else { return 1 }
        return factors[index]
    }
    private func rearInput() -> AVCaptureDeviceInput? {
        for type: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] {
            if let candidate = deviceInput(.back, type:type) { return candidate }
        }
        return nil
    }
    private func configure() {
        guard let newInput = rearInput() ?? deviceInput(.front) else { report("此设备没有可用摄像头。"); return }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(newInput) else { report("无法打开摄像头。"); return }; session.addInput(newInput)
        guard session.canAddOutput(photos) else { session.removeInput(newInput); report("无法启动照片输出。"); return }; session.addOutput(photos)
        guard session.canAddOutput(video) else { session.removeInput(newInput); session.removeOutput(photos); report("无法启动取景。"); return }
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.addOutput(video); video.setSampleBufferDelegate(self, queue: frames)
        photos.maxPhotoQualityPrioritization = .quality
        input = newInput; orient(); selectLens(1)
    }
    private func orient() {
        capture.async { self.applyLowLightBoost() }
        let front = input?.device.position == .front
        for output in [video as AVCaptureOutput, photos as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoOrientationSupported { connection.videoOrientation = capturePose }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = front }
        }
        let available = input?.device.hasFlash == true
        var options = [1.0]
        if !front {
            if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil { options.insert(0.5, at: 0) }
            if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), wide.activeFormat.videoMaxZoomFactor >= 2 { options.append(2) }
            if let base = teleBase(), !options.contains(base) { options.append(base) }
        }
        DispatchQueue.main.async { self.flashAvailable = available; self.lenses = options }
        capture.async {
            guard let device = self.input?.device else { return }
            if self.photos.isAppleProRAWSupported && !self.photos.isAppleProRAWEnabled { self.photos.isAppleProRAWEnabled = true }
            let sizes = device.activeFormat.supportedMaxPhotoDimensions.sorted { self.mp($0) < self.mp($1) }
            if let maximum = sizes.last { self.photos.maxPhotoDimensions = maximum }
            let choices = Array(Set(sizes.map { self.mp($0) }.filter { device.videoZoomFactor == 1 || $0 <= 12 })).sorted()
            let raw = !self.photos.availableRawPhotoPixelFormatTypes.isEmpty
            let live = self.photos.isLivePhotoCaptureSupported
            if live && !self.photos.isLivePhotoCaptureEnabled { self.photos.isLivePhotoCaptureEnabled = true }
            let supportsHEIFLive = live && self.photos.availablePhotoCodecTypes.contains(.hevc)
            DispatchQueue.main.async { self.liveAvailable = supportsHEIFLive }
            let heif = self.photos.availablePhotoCodecTypes.contains(.hevc)
            DispatchQueue.main.async { self.sizesMP = choices; self.rawAvailable = raw; self.heifAvailable = heif }
        }
    }
    private func teleBase() -> Double? {
        for type: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualCamera] {
            guard let unit = AVCaptureDevice.default(type, for: .video, position: .back) else { continue }
            let factors = [1.0] + unit.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
            let parts = unit.constituentDevices
            if let wide = parts.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), let tele = parts.firstIndex(where: { $0.deviceType == .builtInTelephotoCamera }), factors.count == parts.count { return (10 * factors[tele] / factors[wide]).rounded()/10 }
        }
        return nil
    }
    func selectLens(_ requested: Double) { capture.async {
        guard !self.captureInFlight, let old = self.input else { return }
        if old.device.isVirtualDevice && old.device.position == .back {
            let device = old.device, base = self.wideFactor(device)
            let factor = max(device.minAvailableVideoZoomFactor,min(device.maxAvailableVideoZoomFactor,CGFloat(min(requested,15))*base))
            do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; device.ramp(toVideoZoomFactor:factor,withRate:16); DispatchQueue.main.async { self.lens = Double(factor/base) } } catch { self.report(error.localizedDescription) }
            return
        }
        let rear = old.device.position == .back
        let minimum = rear && AVCaptureDevice.default(.builtInUltraWideCamera, for:.video, position:.back) != nil ? 0.5 : 1.0
        let value = min(15, max(minimum, requested)), tele = rear ? self.teleBase() : nil
        let useTele = tele.map { value >= $0 } ?? false
        let type: AVCaptureDevice.DeviceType = value < 1 ? .builtInUltraWideCamera : useTele ? .builtInTelephotoCamera : .builtInWideAngleCamera
        let base = value < 1 ? 0.5 : useTele ? (tele ?? 1) : 1
        guard let next = !rear || old.device.deviceType == type ? old : self.deviceInput(.back, type: type) else { self.report("未发现此镜头"); return }
        if next !== old { self.session.beginConfiguration() }; defer { if next !== old { self.session.commitConfiguration() } }
        if next !== old {
            self.session.removeInput(old)
            guard self.session.canAddInput(next) else { self.session.addInput(old); self.orient(); self.report("此镜头不可用"); return }; self.session.addInput(next)
        }
        do {
            let device = next.device, factor = min(next.device.maxAvailableVideoZoomFactor,max(next.device.minAvailableVideoZoomFactor,CGFloat(value/base)))
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            guard factor <= device.activeFormat.videoMaxZoomFactor else { throw CocoaError(.featureUnsupported) }
            let crossedNative = (device.videoZoomFactor == 1) != (factor == 1)
            device.videoZoomFactor = factor; self.input = next; if next !== old || crossedNative { self.orient() }
            DispatchQueue.main.async { self.lens = Double(factor)*base }
        } catch {
            if next !== old { self.session.removeInput(next); self.session.addInput(old); self.orient() }; self.report(error.localizedDescription)
        }
    } }
    func flip() { capture.async {
        guard !self.captureInFlight, let old = self.input, let next = (old.device.position == .back ? self.deviceInput(.front) : self.rearInput()) else { self.report("无法切换摄像头。"); return }
        self.session.beginConfiguration(); self.session.removeInput(old)
        if self.session.canAddInput(next) { self.session.addInput(next); self.input = next; let value = Double(next.device.videoZoomFactor); DispatchQueue.main.async { self.lens = value } } else { self.session.addInput(old) }
        self.orient(); self.session.commitConfiguration(); self.selectLens(1)
    } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }; lock.lock(); latest = buffer
        let now = CACurrentMediaTime(), makeThumbs = thumbnailMenu && !thumbnailBusy && now-thumbnailTime > 0.25
        let recipe = selected
        if makeThumbs { thumbnailBusy = true; thumbnailTime = now }; lock.unlock()
        guard makeThumbs else { return }; thumbnailQueue.async { autoreleasepool {
            let source = CIImage(cvPixelBuffer:buffer), scale = 112/max(source.extent.width,source.extent.height)
            let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale)); var batch = [Look:UIImage]()
            if let snapshot = self.thumbnailRenderer.context.createCGImage(small,from:small.extent) {
                let thumbnail = CIImage(cgImage:snapshot)
                for look in Look.allCases { var variant = recipe; variant.look = look; if let image = try? self.thumbnailRenderer.image(thumbnail,variant),let output = self.thumbnailRenderer.context.createCGImage(image,from:image.extent) { batch[look] = UIImage(cgImage:output) } }
            }
            DispatchQueue.main.async { self.lock.lock(); self.thumbnailBusy = false; let visible = self.thumbnailMenu; self.lock.unlock(); if visible { self.thumbnails = batch } }
        } }
    }
    func focus(at point: CGPoint, in size: CGSize, aspect: String) { capture.async {
        guard let device = self.input?.device, let connection = self.video.connection(with:.video) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let vertical = connection.videoOrientation == .portrait || connection.videoOrientation == .portraitUpsideDown
        let width = CGFloat(vertical ? dims.height : dims.width), height = CGFloat(vertical ? dims.width : dims.height)
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return }
        let ratio: CGFloat = aspect == "1:1" ? 1 : aspect == "16:9" ? (vertical ? 9.0/16 : 16.0/9) : (vertical ? 3.0/4 : 4.0/3)
        let scale = min(size.width/width,size.height/height), cropWidth = min(width,height*ratio)*scale, cropHeight = cropWidth/ratio
        let dx = point.x-size.width/2, dy = point.y-size.height/2
        guard abs(dx)<=cropWidth/2, abs(dy)<=cropHeight/2 else { return }
        var x = 0.5 + dx/(scale*width); let y = 0.5 + dy/(scale*height); if connection.isVideoMirrored { x = 1-x }
        let target:CGPoint
        switch connection.videoOrientation { case .portrait: target=CGPoint(x:y,y:1-x); case .portraitUpsideDown: target=CGPoint(x:1-y,y:x); case .landscapeLeft: target=CGPoint(x:1-x,y:1-y); default: target=CGPoint(x:x,y:y) }
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target; if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus } }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) { device.exposurePointOfInterest = target; device.exposureMode = .continuousAutoExposure }
        } catch { self.report(error.localizedDescription) }
    } }
    func take(_ flash: Bool, file: FileSettings) {
        guard ready, !busy else { return }; busy = true
        capture.async {
            guard self.session.isRunning, !self.captureInFlight else { DispatchQueue.main.async { self.busy = false }; return }
            self.captureInFlight = true; self.shot = self.current(); self.shotFile = file
            let settings: AVCapturePhotoSettings
            switch file.format {
            case .raw:
                let formats = self.photos.availableRawPhotoPixelFormatTypes
                guard let pixelFormat = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? formats.first else { self.finish("当前镜头不支持 RAW"); return }
                settings = AVCapturePhotoSettings(rawPixelFormatType: pixelFormat)
            case .heif:
                guard self.photos.availablePhotoCodecTypes.contains(.hevc) else { self.finish("当前镜头不支持 HEIF"); return }
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            case .jpeg: settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            if flash {
                guard self.input?.device.isFlashAvailable == true, self.photos.supportedFlashModes.contains(.on) else { self.finish("当前镜头或拍摄配置暂不支持闪光，请关闭闪光后重试"); return }
                settings.flashMode = .on
            } else if self.photos.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            guard let device = self.input?.device, let size = device.activeFormat.supportedMaxPhotoDimensions.first(where: { self.mp($0) == file.megapixels && (device.videoZoomFactor == 1 || file.megapixels <= 12) }) else { self.finish("镜头能力已变化，请重新选择分辨率"); return }
            settings.maxPhotoDimensions = size
            if file.night {
                guard !file.live, file.format != .raw, !flash else { self.finish("低光拍摄不支持实况、RAW 或闪光灯"); return }
                settings.photoQualityPrioritization = self.photos.maxPhotoQualityPrioritization
                self.nightFrames.removeAll(); self.nightAttempts = 1
                self.nightTemplate = AVCapturePhotoSettings(from: settings)
            }
            if file.live {
                guard file.format == .heif, file.megapixels <= 12, self.photos.isLivePhotoCaptureEnabled, !self.photos.isLivePhotoCaptureSuspended, self.shot.look == .original, self.shot.ev == 0, self.shot.aspect == "4:3" else { self.finish("实况需要 HEIF 原图、4:3、零曝光调整和不超过 12 MP。"); return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                self.liveStill = nil; self.liveError = nil; self.liveURL = url; settings.livePhotoMovieFileURL = url
            }
            self.photos.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        capture.async { let recipe = self.shot
            if self.nightTemplate != nil { if error == nil, let data { self.nightFrames.append(data) }; return }
            if self.shotFile.live { self.liveStill = data; if let error { self.liveError = error }; return }
            guard error == nil, let data else { self.finish("拍摄失败"); return }
            if photo.isRawPhoto { self.save(data, suffix: "dng", thumbnail: nil) }
            else { self.process(data, recipe: recipe, file: self.shotFile) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) { capture.async { if let error { self.liveError = error } } }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) { capture.async {
        if let template = self.nightTemplate {
            if error == nil, self.nightAttempts < 3, self.session.isRunning {
                self.nightAttempts += 1; self.photos.capturePhoto(with: AVCapturePhotoSettings(from: template), delegate:self); return
            }
            let frames = self.nightFrames, recipe = self.shot, file = self.shotFile
            self.nightTemplate = nil; self.nightFrames.removeAll()
            guard let first = frames.first else { self.finish("夜景采集失败，请重试"); return }
            self.process(first, recipe:recipe, file:file, additional:Array(frames.dropFirst())); return
        }
        guard self.shotFile.live, let url = self.liveURL else { if let error { self.finish(error.localizedDescription) }; return }; self.liveURL = nil
        let still = self.liveStill; self.liveStill = nil
        guard let data = still, error == nil, self.liveError == nil, let source = CGImageSourceCreateWithData(data as CFData,nil), let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to:.heif) || type.conforms(to:.heic), (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 > 0 else { try? FileManager.default.removeItem(at:url); self.finish("没有收到完整的 HEIF 实况资源，未保存"); return }
        PHPhotoLibrary.requestAuthorization(for:.addOnly) { status in
            guard status == .authorized || status == .limited else { try? FileManager.default.removeItem(at:url); self.finish("未获得照片保存权限"); return }
            PHPhotoLibrary.shared().performChanges({ let request = PHAssetCreationRequest.forAsset(); request.addResource(with:.photo,data:data,options:nil); request.addResource(with:.pairedVideo,fileURL:url,options:nil) }) { ok, error in
                try? FileManager.default.removeItem(at:url); if ok { let thumb = UIImage(data:data)?.preparingThumbnail(of:CGSize(width:320,height:400)); DispatchQueue.main.async { self.still = thumb } }; self.finish(ok ? nil : error?.localizedDescription ?? "无法保存实况")
            }
        }
    } }
    func importPhoto(_ data: Data, recipe: Recipe, file: FileSettings) { guard !busy else { return }; busy = true; process(data, recipe: recipe, file: file) }
    func editorPreview(_ data: Data, recipe: Recipe) async -> UIImage? {
        await withCheckedContinuation { continuation in processing.async { autoreleasepool {
            guard let source = CIImage(data:data,options:[.applyOrientationProperty:true]) else { continuation.resume(returning:nil); return }
            let ratio = min(1,1000/max(source.extent.width,source.extent.height))
            guard let image = try? self.stillRenderer.image(source.transformed(by:CGAffineTransform(scaleX:ratio,y:ratio)),recipe), let cg = self.stillRenderer.context.createCGImage(image,from:image.extent) else { continuation.resume(returning:nil); return }
            continuation.resume(returning:UIImage(cgImage:cg))
        } } }
    }
    private func fuseNight(_ reference: CIImage, additional: [Data]) -> CIImage {
        let bounds = reference.extent, scale = min(1, 768 / max(bounds.width,bounds.height))
        let shrink = CGAffineTransform(scaleX:scale,y:scale)
        let target = reference.transformed(by:shrink)
        var result = reference, accepted = 1
        for data in additional {
            guard let frame = CIImage(data:data, options:[.applyOrientationProperty:true]), frame.extent == bounds else { continue }
            let request = VNTranslationalImageRegistrationRequest(targetedCIImage:frame.transformed(by:shrink), options:[:])
            do { try VNImageRequestHandler(ciImage:target, options:[:]).perform([request]) } catch { continue }
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { continue }
            let shift = observation.alignmentTransform, dx = shift.tx/scale, dy = shift.ty/scale
            guard abs(dx)<bounds.width*0.04, abs(dy)<bounds.height*0.04 else { continue }
            let moved = frame.transformed(by:CGAffineTransform(translationX:dx,y:dy)).composited(over:reference).cropped(to:bounds)
            let difference = moved.applyingFilter("CIDifferenceBlendMode",parameters:[kCIInputBackgroundImageKey:reference])
            let weight = CGFloat(1)/CGFloat(accepted+1), slope = -8*weight
            let coefficients = CIVector(x:slope*0.25,y:slope*0.5,z:slope*0.25,w:0)
            let mask = difference.applyingFilter("CIColorMatrix",parameters:["inputRVector":coefficients,"inputGVector":coefficients,"inputBVector":coefficients,"inputBiasVector":CIVector(x:weight,y:weight,z:weight,w:0)]).applyingFilter("CIColorClamp")
            result = moved.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:mask]).cropped(to:bounds); accepted += 1
        }
        return result
    }
    private func process(_ data: Data, recipe: Recipe, file: FileSettings, additional: [Data] = []) { processing.async { autoreleasepool {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { self.finish("系统不能解码此照片。"); return }
        do {
            let merged = additional.isEmpty ? source : self.fuseNight(source, additional:additional)
            let image = try self.stillRenderer.image(merged, recipe)
            let options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): file.quality]
            let heif = file.format == .heif
            let encoded = heif ? self.stillRenderer.context.heifRepresentation(of: image, format: .RGBA8, colorSpace: self.stillRenderer.space, options: options) : self.stillRenderer.context.jpegRepresentation(of: image, colorSpace: self.stillRenderer.space, options: options)
            guard let encoded else { self.finish("无法生成所选格式"); return }
            self.save(encoded, suffix: heif ? "heic" : "jpg", thumbnail: UIImage(data: encoded)?.preparingThumbnail(of: CGSize(width: 480,height: 640)))
        } catch { self.finish(error.localizedDescription) }
    } } }
    private func save(_ data: Data, suffix: String, thumbnail: UIImage?) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { self.finish("未保存：请在设置中允许添加照片。"); return }
                PHPhotoLibrary.shared().performChanges({ let options = PHAssetResourceCreationOptions(); options.originalFilename = "FL-\(UUID().uuidString).\(suffix)"; PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options) }) { success, error in
                    if success { DispatchQueue.main.async { self.still = thumbnail } }
                    self.finish(success ? nil : (error?.localizedDescription ?? "保存失败"))
                }
            }
    }
    private func finish(_ error: String?) { capture.async { self.captureInFlight = false }; DispatchQueue.main.async { self.busy = false; if let error { self.message = error } } }
}
