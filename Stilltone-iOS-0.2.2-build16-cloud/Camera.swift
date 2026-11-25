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
    private func mp(_ size: CMVideoDimensions) -> Int { let pixels = Double(size.width) * Double(size.height) / 1_000_000; return (47...50).contains(pixels) ? 48 : Int(pixels.rounded()) }
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
    // Retain build 15's tile resolution; reduce wasted work, not spatial detail.
    private static let thumbnailEdge: CGFloat = 224
    private let thumbnailQueue = DispatchQueue(label:"fl.thumbnails", qos:.utility), thumbnailRenderer = Renderer()
    // Under lock: the native rail is continuous; the Web rail grants one frame at a time.
    private var nativeThumbnails = false, thumbnailRendering = false
    private var atlasRequest: ((String?) -> Void)?
    private var thumbnailGeneration: UInt64 = 0
    private var nextThumbnailTime = 0.0
    private var lastThumbnailPTS = CMTime.invalid
    func enableThumbnails(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled != nativeThumbnails else { return }
        nativeThumbnails = enabled; thumbnailGeneration &+= 1
    }
    func requestThumbnailAtlas(_ completion: @escaping (String?) -> Void) {
        lock.lock(); atlasRequest = completion; lock.unlock()
    }
    func cancelThumbnailAtlas() {
        lock.lock(); defer { lock.unlock() }
        atlasRequest = nil; thumbnailGeneration &+= 1
        // A running worker keeps its slot until it returns; rail toggles cannot queue more workers.
    }
    private func makeThumbnailAtlas(_ buffer: CVPixelBuffer, recipe: Recipe) -> CGImage? {
        let source = CIImage(cvPixelBuffer:buffer), edge = Self.thumbnailEdge
        let bounds = source.extent, side = min(bounds.width, bounds.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x:bounds.midX-side/2, y:bounds.midY-side/2, width:side, height:side)
        let tile = CGRect(x:0, y:0, width:edge, height:edge)
        let small = source.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX, y:-crop.minY))
            .transformed(by:CGAffineTransform(scaleX:edge/side, y:edge/side)).cropped(to:tile)
        let strip = CGRect(x:0, y:0, width:edge*CGFloat(Look.allCases.count), height:edge)
        var atlas = CIImage(color:.black).cropped(to:strip)
        for (index, look) in Look.allCases.enumerated() {
            var variant = recipe; variant.aspect = "1:1"; variant.look = look
            guard let image = try? thumbnailRenderer.image(small, variant) else { continue }
            let position = CGAffineTransform(translationX:CGFloat(index)*edge, y:0)
            atlas = image.cropped(to:tile).transformed(by:position).composited(over:atlas)
        }
        return thumbnailRenderer.context.createCGImage(atlas, from:strip)
    }
    private func renderThumbnailBatch(_ buffer: CVPixelBuffer, recipe: Recipe, generation: UInt64, forWeb: Bool) -> (jpeg: String?, tiles: [Look:UIImage]) {
        func isCurrent() -> Bool { lock.lock(); defer { lock.unlock() }; return generation == thumbnailGeneration }
        guard isCurrent(), let atlas = makeThumbnailAtlas(buffer, recipe:recipe), isCurrent() else { return (nil, [:]) }
        if forWeb { return (UIImage(cgImage:atlas).jpegData(compressionQuality:0.88)?.base64EncodedString(), [:]) }
        var tiles = [Look:UIImage]()
        let edge = Self.thumbnailEdge
        for (index, look) in Look.allCases.enumerated() {
            let rect = CGRect(x:CGFloat(index)*edge, y:0, width:edge, height:edge)
            if let tile = atlas.cropping(to:rect) { tiles[look] = UIImage(cgImage:tile) }
        }
        return (nil, tiles)
    }
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
            guard let device = input?.device else { return }
            if !session.isRunning {
                resetZoom(device)
                // A foreground restart returns to 1×. Republish its sizes too, not the
                // previous 2×/tele list. Set output capabilities before starting video.
                updatePhotoCapabilities()
                session.startRunning()
            }
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
    private func resetZoom(_ device: AVCaptureDevice) {
        let base = wideFactor(device)
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor,max(device.minAvailableVideoZoomFactor,base))
            let actual = Double(device.videoZoomFactor/base)
            DispatchQueue.main.async { self.lens = actual }
        } catch { report(error.localizedDescription) }
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
        input = newInput; preparePhotoFormat(newInput.device); orient()
    }
    private func preparePhotoFormat(_ device: AVCaptureDevice) {
        guard device.position == .back, !device.activeFormat.supportedMaxPhotoDimensions.contains(where:{mp($0) == 48}) else { return }
        let candidates = device.formats.filter { format in
            let sizes = Set(format.supportedMaxPhotoDimensions.map { mp($0) }); return sizes.contains(12) && sizes.contains(48)
        }
        guard let format = candidates.first(where:{CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width}) ?? candidates.first else {return}
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() };device.activeFormat = format } catch { report(error.localizedDescription) }
    }
    private func mainZoom(_ device: AVCaptureDevice)->Bool {
        device.position == .back && (device.isVirtualDevice || device.deviceType == .builtInWideAngleCamera)
            && abs(device.videoZoomFactor / wideFactor(device) - 1) < 0.01
    }
    private func sizeChoices(_ device: AVCaptureDevice, highResolution: Bool) -> [Int] {
        Set(device.activeFormat.supportedMaxPhotoDimensions.map(mp).filter { highResolution || $0 <= 12 }).sorted()
    }
    private var zoomObservation: NSKeyValueObservation?
    private weak var observedZoomDevice: AVCaptureDevice?
    private func observeZoomCompletion(on device: AVCaptureDevice) {
        guard observedZoomDevice !== device else { return }
        zoomObservation?.invalidate(); zoomObservation = nil; observedZoomDevice = device
        guard device.isVirtualDevice, device.position == .back else { return }
        zoomObservation = device.observe(\.isRampingVideoZoom, options: [.new]) { [weak self] changed, _ in
            guard let self else { return }
            self.capture.async {
                guard self.input?.device === changed, !changed.isRampingVideoZoom else { return }
                let actual = Double(changed.videoZoomFactor / self.wideFactor(changed))
                let choices = self.sizeChoices(changed, highResolution:self.mainZoom(changed))
                DispatchQueue.main.async { self.lens = actual; self.sizesMP = choices }
            }
        }
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
        let ordered = options.sorted()
        DispatchQueue.main.async { self.flashAvailable = available; self.lenses = ordered }
    }

    // Called on the capture queue, after committing the input/format transaction.
    private func updatePhotoCapabilities() {
        guard let device = input?.device else { return }
        if photos.isAppleProRAWSupported && !photos.isAppleProRAWEnabled { photos.isAppleProRAWEnabled = true }
        if photos.isLivePhotoCaptureSupported && !photos.isLivePhotoCaptureEnabled { photos.isLivePhotoCaptureEnabled = true }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = sizes.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }),
           largest.width != photos.maxPhotoDimensions.width || largest.height != photos.maxPhotoDimensions.height {
            photos.maxPhotoDimensions = largest
        }
        observeZoomCompletion(on: device)
        let choices = sizeChoices(device, highResolution: mainZoom(device))
        let raw = !photos.availableRawPhotoPixelFormatTypes.isEmpty
        let heif = photos.availablePhotoCodecTypes.contains(.hevc)
        let live = heif && photos.isLivePhotoCaptureSupported && photos.isLivePhotoCaptureEnabled
        DispatchQueue.main.async {
            self.sizesMP = choices; self.rawAvailable = raw; self.heifAvailable = heif; self.liveAvailable = live
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
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.ramp(toVideoZoomFactor:factor,withRate:16)
                // Hide high resolutions immediately on the way out. On the way back,
                // do not offer them on the strength of a target that has not been reached.
                let atMain = abs(factor/base-1) < 0.01 && self.mainZoom(device)
                let sizes = self.sizeChoices(device, highResolution:atMain)
                DispatchQueue.main.async { self.lens = Double(factor/base); self.sizesMP = sizes }
            } catch { self.report(error.localizedDescription) }
            return
        }
        let rear = old.device.position == .back
        let minimum = rear && AVCaptureDevice.default(.builtInUltraWideCamera, for:.video, position:.back) != nil ? 0.5 : 1.0
        let value = min(15, max(minimum, requested)), tele = rear ? self.teleBase() : nil
        let useTele = tele.map { value >= $0 } ?? false
        let type: AVCaptureDevice.DeviceType = value < 1 ? .builtInUltraWideCamera : useTele ? .builtInTelephotoCamera : .builtInWideAngleCamera
        let base = value < 1 ? 0.5 : useTele ? (tele ?? 1) : 1
        guard let next = !rear || old.device.deviceType == type ? old : self.deviceInput(.back, type: type) else { self.report("未发现此镜头"); return }
        let switching = next !== old
        var refreshCapabilities = switching
        if switching { self.session.beginConfiguration() }
        defer {
            if switching { self.session.commitConfiguration() }
            if refreshCapabilities { self.updatePhotoCapabilities() }
        }
        if next !== old {
            self.session.removeInput(old)
            guard self.session.canAddInput(next) else { self.session.addInput(old); self.orient(); self.report("此镜头不可用"); return }; self.session.addInput(next)
        }
        do {
            let device = next.device, factor = min(next.device.maxAvailableVideoZoomFactor,max(next.device.minAvailableVideoZoomFactor,CGFloat(value/base)))
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            guard factor <= device.activeFormat.videoMaxZoomFactor else { throw CocoaError(.featureUnsupported) }
            let crossedNative = (device.videoZoomFactor == 1) != (factor == 1)
            device.videoZoomFactor = factor; self.input = next
            if switching || crossedNative { self.orient(); refreshCapabilities = true }
            DispatchQueue.main.async { self.lens = Double(factor)*base }
        } catch {
            if next !== old { self.session.removeInput(next); self.session.addInput(old); self.orient() }; self.report(error.localizedDescription)
        }
    } }
    func flip() { capture.async {
        guard !self.captureInFlight, let old = self.input, let next = (old.device.position == .back ? self.deviceInput(.front) : self.rearInput()) else { self.report("无法切换摄像头。"); return }
        self.session.beginConfiguration(); self.session.removeInput(old)
        if self.session.canAddInput(next) { self.session.addInput(next); self.input = next; self.preparePhotoFormat(next.device); self.resetZoom(next.device) } else { self.session.addInput(old) }
        self.orient(); self.session.commitConfiguration(); self.updatePhotoCapabilities()
    } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buffer
        guard !thumbnailRendering, nativeThumbnails || atlasRequest != nil else { lock.unlock(); return }
        let now = CACurrentMediaTime(), pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard now >= nextThumbnailTime, !pts.isNumeric || !lastThumbnailPTS.isNumeric || CMTimeCompare(pts, lastThumbnailPTS) != 0 else { lock.unlock(); return }
        let recipe = selected, generation = thumbnailGeneration, deliver = atlasRequest
        atlasRequest = nil; thumbnailRendering = true; lastThumbnailPTS = pts; nextThumbnailTime = now + 1.0/12.0
        lock.unlock()
        thumbnailQueue.async { autoreleasepool {
            let batch = self.renderThumbnailBatch(buffer, recipe:recipe, generation:generation, forWeb:deliver != nil)
            DispatchQueue.main.async {
                self.lock.lock(); self.thumbnailRendering = false
                let current = generation == self.thumbnailGeneration; self.lock.unlock()
                guard current else { return }
                if let deliver { deliver(batch.jpeg) } else if !batch.tiles.isEmpty { self.thumbnails = batch.tiles }
            }
        } }
    }
    // The actual preview layer owns the aspect-fill crop, orientation and mirroring.
    // Access the layer only on main; configure the device only on the capture queue.
    @MainActor weak var focusPreviewLayer: AVCaptureVideoPreviewLayer?
    @MainActor func focus(at point: CGPoint, in size: CGSize) {
        guard let layer = focusPreviewLayer, layer.connection != nil,
              size.width > 0, size.height > 0, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let u = point.x / size.width, v = point.y / size.height
        guard (0...1).contains(u), (0...1).contains(v) else { return }
        let position = CGPoint(x: layer.bounds.minX + u * layer.bounds.width, y: layer.bounds.minY + v * layer.bounds.height)
        let target = layer.captureDevicePointConverted(fromLayerPoint: position)
        guard (0...1).contains(target.x), (0...1).contains(target.y) else { return }
        setFocusPoint(target)
    }
    private func setFocusPoint(_ target: CGPoint) { capture.async {
        guard let device = self.input?.device else { return }
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target; if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus } }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) { device.exposurePointOfInterest = target; device.exposureMode = .continuousAutoExposure }
        } catch { self.report(error.localizedDescription) }
    } }
    func take(_ flash: Bool, file: FileSettings) {
        guard ready, !busy else { return }; busy = true
        let shutterRecipe = current()
        capture.async {
            guard self.session.isRunning, !self.captureInFlight else { DispatchQueue.main.async { self.busy = false }; return }
            self.captureInFlight = true; self.shot = shutterRecipe; self.shotFile = file
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
            guard let device = self.input?.device, let size = device.activeFormat.supportedMaxPhotoDimensions.first(where: { self.mp($0) == file.megapixels && (self.mainZoom(device) || file.megapixels <= 12) }) else { self.finish("镜头能力已变化，请重新选择分辨率"); return }
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
