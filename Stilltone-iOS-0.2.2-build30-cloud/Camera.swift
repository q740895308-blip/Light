import SwiftUI
import AVFoundation
import CoreImage
import MetalKit
import Photos
import PhotosUI
import ImageIO
import Vision
import UniformTypeIdentifiers

// The still keeps its ImageIO metadata; the movie keeps the source audio and timed metadata tracks.
private enum LiveRender {
    enum Failure: Error { case image, movie, pairing }
    static func still(_ data: Data, recipe: Recipe, destination: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let original = CGImageSourceCreateImageAtIndex(source,0,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL,UTType.heic.identifier as CFString,1,nil)
        else { throw Failure.image }
        let renderer = Renderer()
        let image = try renderer.image(CIImage(cgImage:original),recipe)
        guard let frame = renderer.context.createCGImage(image,from:image.extent) else { throw Failure.image }
        CGImageDestinationAddImage(writer,frame,properties)
        guard CGImageDestinationFinalize(writer) else { throw Failure.image }
        return try Data(contentsOf:destination)
    }

    static func movie(_ url: URL, recipe: Recipe, work: URL) async throws -> URL {
        let original = AVURLAsset(url:url)
        let temporaryVideo = work.appendingPathComponent("color.mov")
        let final = work.appendingPathComponent("paired.mov")
        let renderer = Renderer(), renderLock = NSLock()
        guard let color = AVAssetExportSession(asset:original,presetName:AVAssetExportPresetHighestQuality) else { throw Failure.movie }
        color.videoComposition = AVVideoComposition(asset:original, applyingCIFiltersWithHandler:{ request in
            renderLock.lock()
            defer { renderLock.unlock() }
            do {
                let image = try renderer.image(request.sourceImage,recipe)
                request.finish(with:image.cropped(to:request.sourceImage.extent),context:renderer.context)
            } catch { request.finish(with:error) }
        })
        try await export(color,to:temporaryVideo)
        let composition = AVMutableComposition()
        let colored = AVURLAsset(url:temporaryVideo)
        guard let video = try await colored.loadTracks(withMediaType:.video).first else { throw Failure.movie }
        let videoOut = try await insert(video, into:composition)
        videoOut.preferredTransform = try await video.load(.preferredTransform)
        let metadataTracks = try await original.loadTracks(withMediaType:.metadata)
        guard !metadataTracks.isEmpty else { throw Failure.pairing }
        for track in metadataTracks { _ = try await insert(track,into:composition) }
        let audioTracks = try await original.loadTracks(withMediaType:.audio)
        for track in audioTracks { _ = try await insert(track,into:composition) }
        guard let mux = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw Failure.movie }
        mux.metadata = try await original.load(.metadata)
        try await export(mux,to:final)
        return final
    }
    private static func insert(_ track: AVAssetTrack, into composition: AVMutableComposition) async throws -> AVMutableCompositionTrack {
        guard let output = composition.addMutableTrack(withMediaType:track.mediaType,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw Failure.movie }
        let range = try await track.load(.timeRange)
        try output.insertTimeRange(range,of:track,at:range.start)
        return output
    }
    private static func export(_ session: AVAssetExportSession, to url: URL) async throws {
        guard session.supportedFileTypes.contains(.mov) else { throw Failure.movie }
        session.outputURL = url; session.outputFileType = .mov
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void,Error>) in
            session.exportAsynchronously {
                if session.status == .completed { resume.resume(returning:()) }
                else { resume.resume(throwing:session.error ?? Failure.movie) }
            }
        }
    }
    static func validate(still: URL, movie: URL) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void,Error>) in
            PHLivePhoto.request(withResourceFileURLs:[still,movie],placeholderImage:nil,targetSize:CGSize(width:320,height:320),contentMode:.aspectFit) { photo,info in
                if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                if let error = info[PHLivePhotoInfoErrorKey] as? Error { resume.resume(throwing:error) }
                else if photo != nil { resume.resume(returning:()) }
                else { resume.resume(throwing:Failure.pairing) }
            }
        }
    }
}

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
    var autoFlash = false
    var autoNight = false
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
    @Published private(set) var zoomSettling = false
    @Published private(set) var inputRevision = 0
    private var currentInputRevision = 0
    private var requestedDisplayZoom = 1.0
    private var parkedRear: (input: AVCaptureDeviceInput, zoom: Double, highResolution: Bool)?
    @Published private(set) var macroVisible = false
    @Published private(set) var macroEnabled = true
    private var autoMacroEnabled = true // capture queue
    private var macroObservation: NSKeyValueObservation?
    @Published private(set) var focusLocked = false
    @Published private(set) var biasLimits: [Float] = [0,0]
    @Published private(set) var supportsAutoFlash = false
    private var focusGeneration = 0
    private var requestedBias: Float = 0
    func setHardwareBias(_ value: Double) {
        guard value.isFinite else { return }
        capture.async {
            self.requestedBias = Float(max(-8,min(8,value)))
            if let device = self.input?.device { self.applyBias(on:device) }
        }
    }
    private func applyBias(on device: AVCaptureDevice) {
        let value = max(device.minExposureTargetBias,min(device.maxExposureTargetBias,requestedBias))
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(value, completionHandler:nil)
        } catch { report(error.localizedDescription) }
    }
    private func resetMetering(on device: AVCaptureDevice) {
        focusGeneration += 1
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x:0.5,y:0.5) }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x:0.5,y:0.5) }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        } catch { report(error.localizedDescription) }
        let limits = [device.minExposureTargetBias,device.maxExposureTargetBias]
        applyBias(on:device)
        DispatchQueue.main.async { self.focusLocked = false; self.biasLimits = limits }
    }
    @Published var still: UIImage?
    @Published var ready = false
    @Published var busy = false
    @Published var message: String?
    @Published var flashAvailable = false
    @Published var jpegAvailable = false
    @Published private(set) var saveIssue: String?
    @Published private(set) var lastSavedID = ""
    private(set) var latestThumbJPEG: String?
    private var shotID: Int64?
    private var processedPhoto: Data?
    private var processingError: Error?
    private var committedPending = false
    private var saveInProgress = false
    private var pending: PendingPhoto?
    private var inspectedPending = false
    private struct PendingPhoto {
        let data: Data
        let suffix: String
        var movie: URL?
        let thumbnail: UIImage?
        let id: UUID
        var alternateRAW: Data? = nil
    }
    private var pendingFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingCapture", isDirectory: true)
    }
    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(resumeAfterInterruption), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }
    @objc private func interrupted() {
        capture.async { DispatchQueue.main.async { self.ready = false; self.macroVisible = false } }
    }
    @objc private func resumeAfterInterruption() { capture.async { if self.active { self.authorize() } } }
    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        capture.async {
            DispatchQueue.main.async { self.ready = false }
            if self.active && error?.code == .mediaServicesWereReset { self.authorize() }
            else if self.active { self.report(error?.localizedDescription ?? "相机会话已中断，请重新进入拍摄页面。") }
        }
    }
    @Published var rawAvailable = false
    @Published private(set) var alternate48Available = false
    private var usingDedicatedWide = false
    @Published private(set) var highResolutionActive = false
    @Published var liveAvailable = false
    @Published private(set) var liveSuspended = false
    private var nightRequested = false
    private var nightFrames = [Data]()
    private var nightTemplate: AVCapturePhotoSettings?
    private var nightAttempts = 0
    func setNight(_ enabled: Bool) { capture.async { self.nightRequested = enabled; self.applyLowLightBoost() } }
    private func applyLowLightBoost() {
        guard let device = input?.device, device.isLowLightBoostSupported else { return }
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; device.automaticallyEnablesLowLightBoostWhenAvailable = nightRequested } catch { report(error.localizedDescription) }
    }
    private var liveURL: URL?, liveError: Error?
    private var flashObservation: NSKeyValueObservation?
    private var liveObservation: NSKeyValueObservation?
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
    private var physicalPose: AVCaptureVideoOrientation?
    private var rotationCoordinator: AnyObject?
    @Published private(set) var controlRotation = 0
    func updatePhysicalPose(_ pose: UIDeviceOrientation) {
        let videoPose: AVCaptureVideoOrientation, degrees: Int
        switch pose {
        case .portrait: videoPose = .portrait; degrees = 0
        case .landscapeLeft: videoPose = .landscapeRight; degrees = 90
        case .landscapeRight: videoPose = .landscapeLeft; degrees = -90
        case .portraitUpsideDown: videoPose = .portraitUpsideDown; degrees = 180
        default: return
        }
        capture.async { self.physicalPose = videoPose }
        DispatchQueue.main.async {
            // Continue from the displayed angle when crossing the upside-down position.
            let delta = (degrees - self.controlRotation % 360 + 540) % 360 - 180
            if delta != 0 { self.controlRotation += delta }
        }
    }
    private func orientPhotoForShutter() {
        guard let connection = photos.connection(with: .video) else { return }
        if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                return
            }
        }
        if connection.isVideoOrientationSupported { connection.videoOrientation = physicalPose ?? capturePose }
    }
    func setPose(_ pose: UIDeviceOrientation) { capture.async {
        switch pose { case .portrait: self.capturePose = .portrait; case .portraitUpsideDown: self.capturePose = .portraitUpsideDown; case .landscapeLeft: self.capturePose = .landscapeRight; case .landscapeRight: self.capturePose = .landscapeLeft; default: return }
        if let connection = self.video.connection(with:.video), connection.isVideoOrientationSupported { connection.videoOrientation = self.capturePose }
    } }
    // The active rail requests the displayed backing-pixel size with each frame.
    private var requestedThumbnailEdge: CGFloat = 224
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
    func requestThumbnailAtlas(edge: Int, _ completion: @escaping (String?) -> Void) {
        lock.lock(); requestedThumbnailEdge = CGFloat(min(384, max(96, edge))); atlasRequest = completion; lock.unlock()
    }
    func cancelThumbnailAtlas() {
        lock.lock(); defer { lock.unlock() }
        atlasRequest = nil; thumbnailGeneration &+= 1
        // A running worker keeps its slot until it returns; rail toggles cannot queue more workers.
    }
    private func makeThumbnailAtlas(_ buffer: CVPixelBuffer, recipe: Recipe, edge: CGFloat) -> CGImage? {
        let source = CIImage(cvPixelBuffer:buffer)
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
    private func renderThumbnailBatch(_ buffer: CVPixelBuffer, recipe: Recipe, generation: UInt64, edge: CGFloat, forWeb: Bool) -> (jpeg: String?, tiles: [Look:UIImage]) {
        func isCurrent() -> Bool { lock.lock(); defer { lock.unlock() }; return generation == thumbnailGeneration }
        guard isCurrent(), let atlas = makeThumbnailAtlas(buffer, recipe:recipe, edge:edge), isCurrent() else { return (nil, [:]) }
        if forWeb { return (UIImage(cgImage:atlas).jpegData(compressionQuality:0.88)?.base64EncodedString(), [:]) }
        var tiles = [Look:UIImage]()

        for (index, look) in Look.allCases.enumerated() {
            let rect = CGRect(x:CGFloat(index)*edge, y:0, width:edge, height:edge)
            if let tile = atlas.cropping(to:rect) { tiles[look] = UIImage(cgImage:tile) }
        }
        return (nil, tiles)
    }
    private var latest: CVPixelBuffer?
    private var lastDisplayBuffer: CVPixelBuffer?, waitingForPreview: UUID?
    @Published private(set) var transitionImage: UIImage?
    private var visibleTransition: UUID? // main queue
    private lazy var transitionRenderer = Renderer() // capture queue
    private let lock = NSLock()
    func previewFrame() -> (CVPixelBuffer, Recipe)? {
        lock.lock(); defer { lock.unlock() }; guard let latest else { return nil }; self.latest = nil; return (latest, selected)
    }
    private var active = false
    private var acceptingPreviewFrames = false // protected by lock
    private var hiddenStopGeneration: UInt64 = 0
    private var captureInFlight = false
    func update(_ recipe: Recipe) { lock.lock(); selected = recipe; lock.unlock() }
    private func current() -> Recipe { lock.lock(); defer { lock.unlock() }; return selected }
    private func report(_ text: String) { DispatchQueue.main.async { self.message = text } }
    func start() {
        capture.async {
            guard !self.active else { return }
            self.restorePending()
            self.active = true
            self.hiddenStopGeneration &+= 1
            self.lock.lock(); self.acceptingPreviewFrames = true; self.lock.unlock()
            self.authorize()
        }
    }
    private func authorize() {
        guard active else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if input == nil { configure() }
            guard let device = input?.device else { return }
            if !session.isRunning {
                resetZoom(device)
                resetMetering(on:device)
                // A foreground restart returns to 1×. Republish its sizes too, not the
                // previous 2×/tele list. Set output capabilities before starting video.
                updatePhotoCapabilities()
                session.startRunning()
            }
            let running = session.isRunning && !session.isInterrupted
            refreshMacroState(device)
            DispatchQueue.main.async { self.ready = running }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in self.capture.async { self.authorize() } }
        default: report("未获得相机权限。请在设置中允许访问相机，或从相册导入照片。")
        }
    }
    func stop() { capture.async {
        guard self.active else { return }
        self.active = false
        self.hiddenStopGeneration &+= 1
        self.lock.lock()
        self.acceptingPreviewFrames = false; self.latest = nil; self.lastDisplayBuffer = nil; self.waitingForPreview = nil
        self.nativeThumbnails = false; self.atlasRequest = nil; self.thumbnailGeneration &+= 1
        self.lock.unlock()
        DispatchQueue.main.async {
            self.ready = false; self.macroVisible = false; self.transitionImage = nil; self.visibleTransition = nil
        }
        guard let id = self.shotID else { self.stopSessionIfHidden(); return }
        // Live Photos can still be collecting their motion tail when the page closes.
        // The final callback normally stops the session; bound that wait if it is lost.
        let generation = self.hiddenStopGeneration
        self.capture.asyncAfter(deadline:.now() + 5) {
            guard !self.active, self.hiddenStopGeneration == generation, self.shotID == id else { return }
            self.stopSessionIfHidden()
        }
    } }
    private func stopSessionIfHidden() {
        if !active && session.isRunning { session.stopRunning() }
    }
    private func deviceInput(_ position: AVCaptureDevice.Position, type: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(type, for: .video, position: position) else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }
    private func wideFactor(_ device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *), device.isVirtualDevice {
            let multiplier = device.displayVideoZoomFactorMultiplier
            if multiplier.isFinite && multiplier > 0 { return 1 / multiplier }
        }
        let factors = [CGFloat(1)] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        guard let index = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }), index < factors.count else { return 1 }
        return factors[index]
    }
    private func resetZoom(_ device: AVCaptureDevice, displayZoom: Double = 1) {
        let base = wideFactor(device)
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isVirtualDevice { setFallbackLenses(device,displayZoom:displayZoom) }
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            let baseLens: Double
            if device.deviceType == .builtInUltraWideCamera { baseLens = 0.5 }
            else if device.deviceType == .builtInTelephotoCamera { baseLens = teleBase() ?? 1 }
            else { baseLens = 1 }
            device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor,max(device.minAvailableVideoZoomFactor,CGFloat(displayZoom/baseLens)*base))
            let actual = Double(device.videoZoomFactor/base) * baseLens
            requestedDisplayZoom = actual
            DispatchQueue.main.async { self.lens = actual; self.zoomSettling = false }
        } catch { report(error.localizedDescription) }
    }
    // Called under the device configuration lock. Other focal lengths keep their
    // normal fallbacks, including the wide camera as a fallback for telephoto.
    private func setFallbackLenses(_ device: AVCaptureDevice, displayZoom: Double) {
        let allowed = device.supportedFallbackPrimaryConstituentDevices.filter {
            autoMacroEnabled || abs(displayZoom - 1) > 0.001 || $0.deviceType != .builtInUltraWideCamera
        }
        if device.fallbackPrimaryConstituentDevices != allowed { device.fallbackPrimaryConstituentDevices = allowed }
    }
    private func macroAvailable(_ device: AVCaptureDevice) -> Bool {
        active && session.isRunning && !session.isInterrupted && !usingDedicatedWide &&
            device.isVirtualDevice && device.position == .back && !device.isRampingVideoZoom &&
            abs(device.videoZoomFactor / wideFactor(device) - 1) <= 0.001 &&
            device.supportedFallbackPrimaryConstituentDevices.contains {
                $0.deviceType == .builtInUltraWideCamera && $0.isFocusModeSupported(.continuousAutoFocus)
            }
    }
    private func refreshMacroState(_ device: AVCaptureDevice) {
        let enabled = autoMacroEnabled
        // Once disabled, the excluded lens can no longer signal proximity. Keep
        // the off control accessible at 1× so the photographer can re-enable it.
        let visible = macroAvailable(device) && (!enabled || device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera)
        DispatchQueue.main.async {
            if self.macroEnabled != enabled { self.macroEnabled = enabled }
            if self.macroVisible != visible { self.macroVisible = visible }
        }
    }
    func setAutoMacro(_ enabled: Bool) {
        capture.async {
            guard let device = self.input?.device, self.macroAvailable(device),
                  !self.captureInFlight, self.autoMacroEnabled != enabled else { return }
            do {
                try device.lockForConfiguration()
                self.autoMacroEnabled = enabled
                self.setFallbackLenses(device,displayZoom:1)
                device.unlockForConfiguration()
                self.refreshMacroState(device)
            } catch { self.report(error.localizedDescription) }
        }
    }
    private func rearInput() -> AVCaptureDeviceInput? {
        // AVFoundation can switch constituent lenses without replacing a virtual input.
        for type: AVCaptureDevice.DeviceType in [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] {
            if let candidate = deviceInput(.back, type:type) { return candidate }
        }
        return nil
    }
    private func replaceBackInput(with next: AVCaptureDeviceInput) -> Bool {
        guard let old = input, old.device.position == .back else { return false }
        session.beginConfiguration()
        session.removeInput(old)
        let accepted = session.canAddInput(next)
        if accepted {
            session.addInput(next); input = next; preparePhotoFormat(next.device); resetZoom(next.device); orient()
        } else { session.addInput(old) }
        session.commitConfiguration()
        updatePhotoCapabilities()
        return accepted
    }
    private func beginPreviewTransition() -> UUID? {
        lock.lock(); let buffer = lastDisplayBuffer, recipe = selected; lock.unlock()
        guard let buffer else { return nil }
        let source = CIImage(cvPixelBuffer:buffer), scale = min(1,360/max(source.extent.width,source.extent.height))
        let small = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let styled = (try? transitionRenderer.image(small,recipe)) ?? small
        let blurred = styled.clampedToExtent().applyingGaussianBlur(sigma:8).cropped(to:styled.extent)
        guard let cg = transitionRenderer.context.createCGImage(blurred,from:blurred.extent) else { return nil }
        let id = UUID()
        DispatchQueue.main.async { self.visibleTransition = id; self.transitionImage = UIImage(cgImage:cg) }
        return id
    }
    private func clearPreviewTransition(_ id: UUID, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) {
            guard self.visibleTransition == id else { return }
            self.visibleTransition = nil; self.transitionImage = nil
        }
    }
    func setHighResolution(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        capture.async {
            guard self.active, !self.captureInFlight, let current=self.input, current.device.position == .back,
                  !current.device.isRampingVideoZoom else { DispatchQueue.main.async { completion(false) }; return }
            if self.usingDedicatedWide == enabled { DispatchQueue.main.async { completion(true) }; return }
            let candidate = enabled ? self.deviceInput(.back) : self.rearInput()
            guard let next=candidate, !enabled || next.device.formats.contains(where:{$0.supportedMaxPhotoDimensions.contains(where:{self.mp($0)==48})}) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let transition = self.beginPreviewTransition()
            self.usingDedicatedWide = enabled
            let switched = self.replaceBackInput(with:next)
            let ready = switched && (!enabled || next.device.activeFormat.supportedMaxPhotoDimensions.contains(where:{self.mp($0)==48}))
            if !ready {
                self.usingDedicatedWide = !enabled
                if switched { _ = self.replaceBackInput(with:current) }
                else { self.updatePhotoCapabilities() }
            }
            if let transition {
                self.lock.lock(); self.waitingForPreview = transition; self.lock.unlock()
                self.clearPreviewTransition(transition,after:1.5)
            }
            DispatchQueue.main.async { completion(ready) }
        }
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
        let target = usingDedicatedWide ? 48 : 12
        guard device.position == .back, !device.activeFormat.supportedMaxPhotoDimensions.contains(where:{mp($0) == target}) else { return }
        let candidates = device.formats.filter { format in
            format.supportedMaxPhotoDimensions.contains(where:{mp($0) == target})
        }
        let preferred = candidates.filter { $0.supportedMaxPhotoDimensions.contains(where:{mp($0) == 12}) }
        let pool = preferred.isEmpty ? candidates : preferred
        guard let format = pool.first(where:{CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width}) ?? pool.first else {return}
        do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() };device.activeFormat = format } catch { report(error.localizedDescription) }
    }
    private func mainZoom(_ device: AVCaptureDevice)->Bool {
        device.position == .back && (device.isVirtualDevice || device.deviceType == .builtInWideAngleCamera)
            && abs(device.videoZoomFactor / wideFactor(device) - 1) < 0.01
    }
    private func sizeChoices(_ device: AVCaptureDevice, highResolution: Bool) -> [Int] {
        Set(device.activeFormat.supportedMaxPhotoDimensions.map(mp).filter { usingDedicatedWide || highResolution || $0 <= 12 }).sorted()
    }
    private var zoomObservation: NSKeyValueObservation?
    private weak var observedZoomDevice: AVCaptureDevice?
    private func observeZoomCompletion(on device: AVCaptureDevice) {
        guard observedZoomDevice !== device else { return }
        zoomObservation?.invalidate(); zoomObservation = nil; observedZoomDevice = device
        macroObservation?.invalidate(); macroObservation = nil
        if device.isVirtualDevice && device.position == .back {
            macroObservation = device.observe(\.activePrimaryConstituent, options:[.new]) { [weak self] changed, _ in
                guard let self else { return }
                self.capture.async {
                    guard self.input?.device === changed else { return }
                    self.refreshMacroState(changed)
                }
            }
        }
        flashObservation = device.observe(\.isFlashAvailable, options:[.new]) { [weak self] changed, _ in
            guard let self else { return }
            self.capture.async {
                guard self.input?.device === changed else { return }
                let available = changed.isFlashAvailable && self.photos.supportedFlashModes.contains(.on)
                DispatchQueue.main.async { self.flashAvailable = available }
            }
        }
        if liveObservation == nil {
            liveObservation = photos.observe(\.isLivePhotoCaptureSuspended, options:[.new]) { [weak self] output, _ in
                guard let self else { return }
                self.capture.async {
                    let live = output.availablePhotoCodecTypes.contains(.hevc) && output.isLivePhotoCaptureEnabled && !output.isLivePhotoCaptureSuspended
                    let suspended = output.isLivePhotoCaptureSuspended
                    DispatchQueue.main.async { self.liveSuspended = suspended; self.liveAvailable = live }
                }
            }
        }
        // Observe physical zoom ramps as well as virtual-camera switchovers.
        zoomObservation = device.observe(\.isRampingVideoZoom, options: [.new]) { [weak self] changed, _ in
            guard let self else { return }
            self.capture.async {
                guard self.input?.device === changed else { return }
                self.refreshMacroState(changed)
                guard !changed.isRampingVideoZoom else { return }
                let opticalBase: Double = changed.deviceType == .builtInUltraWideCamera ? 0.5 : (changed.deviceType == .builtInTelephotoCamera ? self.teleBase() ?? 1 : 1)
                let actual = Double(changed.videoZoomFactor / self.wideFactor(changed)) * opticalBase
                let choices = self.sizeChoices(changed, highResolution:self.mainZoom(changed))
                DispatchQueue.main.async { self.zoomSettling = false; self.lens = actual; self.sizesMP = choices }
            }
        }
    }
    private func orient() {
        if #available(iOS 17.0, *), let device = input?.device {
            rotationCoordinator = AVCaptureDevice.RotationCoordinator(device:device,previewLayer:nil)
        }
        capture.async { self.applyLowLightBoost() }
        if let device = input?.device { capture.async { if self.input?.device === device { self.resetMetering(on:device) } } }
        let front = input?.device.position == .front
        for output in [video as AVCaptureOutput, photos as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoOrientationSupported { connection.videoOrientation = capturePose }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = front }
        }
        let available = input?.device.isFlashAvailable == true && photos.supportedFlashModes.contains(.on)
        var options = [1.0]
        if usingDedicatedWide, let device = input?.device {
            options += [2.0,3.0].filter { CGFloat($0) <= device.maxAvailableVideoZoomFactor }
        } else if !front {
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
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let targetDimensions = supported.filter { mp($0) == (usingDedicatedWide ? 48 : 12) }
        let sizes = targetDimensions.isEmpty ? supported : targetDimensions
        if let largest = sizes.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }),
           largest.width != photos.maxPhotoDimensions.width || largest.height != photos.maxPhotoDimensions.height {
            photos.maxPhotoDimensions = largest
        }
        observeZoomCompletion(on: device)
        refreshMacroState(device)
        let choices = sizeChoices(device, highResolution: mainZoom(device))
        let wide48 = device.isVirtualDevice && AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back)?.formats.contains(where:{ $0.supportedMaxPhotoDimensions.contains(where:{self.mp($0)==48}) }) == true
        let high = usingDedicatedWide
        DispatchQueue.main.async { self.alternate48Available = wide48; self.highResolutionActive = high }
        let raw = !photos.availableRawPhotoPixelFormatTypes.isEmpty
        let heif = photos.availablePhotoCodecTypes.contains(.hevc)
        let jpeg = photos.availablePhotoCodecTypes.contains(.jpeg)
        let suspended = photos.isLivePhotoCaptureSuspended
        let live = heif && photos.isLivePhotoCaptureSupported && photos.isLivePhotoCaptureEnabled && !photos.isLivePhotoCaptureSuspended
        let flash = device.isFlashAvailable && photos.supportedFlashModes.contains(.on)
        let autoFlash = photos.supportedFlashModes.contains(.auto)
        DispatchQueue.main.async {
            self.sizesMP = choices; self.rawAvailable = raw; self.heifAvailable = heif
            self.jpegAvailable = jpeg; self.liveSuspended = suspended; self.liveAvailable = live; self.flashAvailable = flash
            self.supportsAutoFlash = autoFlash
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
    func selectLens(_ requested: Double, inputRevision: Int? = nil) { capture.async {
        guard self.active, requested.isFinite, inputRevision == nil || inputRevision == self.currentInputRevision,
              !self.captureInFlight, let current = self.input else { return }
        let old = current
        if self.usingDedicatedWide {
            let device = current.device, factor = max(1,min(CGFloat(requested),min(15,device.maxAvailableVideoZoomFactor)))
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let rate = Float(max(1,min(12,abs(log2(Double(factor/device.videoZoomFactor)))/0.28)))
                device.ramp(toVideoZoomFactor:factor,withRate:rate)
                self.requestedDisplayZoom = Double(factor)
                let settling = device.isRampingVideoZoom
                DispatchQueue.main.async { self.lens = Double(factor); self.zoomSettling = settling }
            } catch { self.report(error.localizedDescription) }
            return

        }
        if old.device.isVirtualDevice && old.device.position == .back {
            let device = old.device, base = self.wideFactor(device)
            let factor = max(device.minAvailableVideoZoomFactor,min(device.maxAvailableVideoZoomFactor,CGFloat(min(requested,15))*base))
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let parts=device.constituentDevices, switches=[1.0]+device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
                let tele=parts.firstIndex(where:{$0.deviceType == .builtInTelephotoCamera}).flatMap { switches.indices.contains($0) ? switches[$0]/Double(base) : nil }
                self.setFallbackLenses(device,displayZoom:Double(factor/base))
                let distance = abs(log2(Double(factor / device.videoZoomFactor)))
                let currentZoom = Double(device.videoZoomFactor/base)
                let crossesTele=tele.map { (requested >= $0-0.001) != (currentZoom >= $0-0.001) } ?? false
                let rate = Float(max(0.6,min(12,distance/(crossesTele ? 0.48 : 0.28))))
                device.ramp(toVideoZoomFactor:factor,withRate:rate)
                self.requestedDisplayZoom = Double(factor/base)
                // Hide high resolutions immediately on the way out. On the way back,
                // do not offer them on the strength of a target that has not been reached.
                let atMain = abs(factor/base-1) < 0.01 && self.mainZoom(device)
                let sizes = self.sizeChoices(device, highResolution:atMain)
                let settling = device.isRampingVideoZoom
                DispatchQueue.main.async { self.lens = Double(factor/base); self.sizesMP = sizes; self.zoomSettling = settling }
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
            self.preparePhotoFormat(next.device)
        }
        do {
            let device = next.device, factor = min(next.device.maxAvailableVideoZoomFactor,max(next.device.minAvailableVideoZoomFactor,CGFloat(value/base)))
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            guard factor <= device.activeFormat.videoMaxZoomFactor else { throw CocoaError(.featureUnsupported) }
            let distance = abs(log2(Double(factor/device.videoZoomFactor)))
            if switching { device.videoZoomFactor = factor }
            else { device.ramp(toVideoZoomFactor:factor,withRate:Float(max(1,min(12,distance/0.28)))) }
            self.input = next
            self.requestedDisplayZoom = Double(factor)*base
            if switching { self.orient(); refreshCapabilities = true }
            let settling = device.isRampingVideoZoom
            let sizes = self.sizeChoices(device, highResolution:!settling && self.mainZoom(device))
            DispatchQueue.main.async { self.lens = Double(factor)*base; self.zoomSettling = settling; self.sizesMP = sizes }
        } catch {
            if next !== old { self.session.removeInput(next); self.session.addInput(old); self.orient() }; self.report(error.localizedDescription)
        }
    } }
    func flip(inputRevision: Int? = nil) { capture.async {
        guard self.active, !self.captureInFlight, let old = self.input,
              inputRevision == nil || inputRevision == self.currentInputRevision else { return }
        let toFront = old.device.position == .back
        let restore = toFront ? nil : self.parkedRear
        guard let next = toFront ? self.deviceInput(.front) : (restore?.input ?? self.rearInput()) else {
            self.report("无法切换摄像头。"); return
        }
        let previousZoom = self.requestedDisplayZoom
        self.session.beginConfiguration()
        self.session.removeInput(old)
        guard self.session.canAddInput(next) else {
            self.session.addInput(old); self.orient(); self.session.commitConfiguration()
            self.resetZoom(old.device,displayZoom:previousZoom); self.updatePhotoCapabilities()
            self.report("当前无法切换摄像头，已恢复原镜头。"); return
        }
        if toFront { self.parkedRear = (old,previousZoom,self.usingDedicatedWide) }
        else { self.parkedRear = nil }
        self.usingDedicatedWide = restore?.highResolution ?? false
        self.session.addInput(next); self.input = next
        self.preparePhotoFormat(next.device); self.orient(); self.session.commitConfiguration()
        self.resetZoom(next.device,displayZoom:restore?.zoom ?? 1)
        self.updatePhotoCapabilities()
        self.currentInputRevision += 1
        let revision = self.currentInputRevision
        DispatchQueue.main.async { self.inputRevision = revision }
    } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        guard acceptingPreviewFrames else { lock.unlock(); return }
        latest = buffer; lastDisplayBuffer = buffer
        if let id=waitingForPreview { waitingForPreview=nil; clearPreviewTransition(id,after:0.12) }
        guard !thumbnailRendering, nativeThumbnails || atlasRequest != nil else { lock.unlock(); return }
        let now = CACurrentMediaTime(), pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard now >= nextThumbnailTime, !pts.isNumeric || !lastThumbnailPTS.isNumeric || CMTimeCompare(pts, lastThumbnailPTS) != 0 else { lock.unlock(); return }
        let recipe = selected, generation = thumbnailGeneration, deliver = atlasRequest
        let edge: CGFloat = deliver == nil ? 224 : requestedThumbnailEdge
        let thermal = ProcessInfo.processInfo.thermalState
        let fps: Double = thermal == .serious || thermal == .critical ? 12 : 30
        atlasRequest = nil; thumbnailRendering = true; lastThumbnailPTS = pts; nextThumbnailTime = now + 1.0/fps - 0.002
        lock.unlock()
        thumbnailQueue.async { autoreleasepool {
            let batch = self.renderThumbnailBatch(buffer, recipe:recipe, generation:generation, edge:edge, forWeb:deliver != nil)
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
    @MainActor func focus(at point: CGPoint, in size: CGSize, lockExposure: Bool = false) {
        guard let layer = focusPreviewLayer, layer.connection != nil,
              size.width > 0, size.height > 0, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let u = point.x / size.width, v = point.y / size.height
        guard (0...1).contains(u), (0...1).contains(v) else { return }
        let position = CGPoint(x: layer.bounds.minX + u * layer.bounds.width, y: layer.bounds.minY + v * layer.bounds.height)
        let target = layer.captureDevicePointConverted(fromLayerPoint: position)
        guard (0...1).contains(target.x), (0...1).contains(target.y) else { return }
        setFocusPoint(target, lockExposure:lockExposure)
    }
    private func setFocusPoint(_ target: CGPoint, lockExposure: Bool) { capture.async {
        guard self.active, let device = self.input?.device else { return }
        self.focusGeneration += 1
        let generation = self.focusGeneration
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = target
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        } catch { self.report(error.localizedDescription); return }
        DispatchQueue.main.async { self.focusLocked = false }
        if lockExposure { self.finishFocusLock(device,generation:generation,attempt:0) }
    } }
    private func finishFocusLock(_ device: AVCaptureDevice, generation: Int, attempt: Int) {
        capture.asyncAfter(deadline:.now() + 0.1) {
            guard self.active, self.input?.device === device, self.focusGeneration == generation else { return }
            if device.isAdjustingFocus || device.isAdjustingExposure {
                if attempt < 20 { self.finishFocusLock(device,generation:generation,attempt:attempt+1) }
                else { self.report("当前光线下对焦或测光尚未稳定。") }
                return
            }
            guard device.isExposureModeSupported(.locked), device.isFocusModeSupported(.locked) else {
                self.report("当前镜头无法同时锁定曝光和对焦。"); return
            }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.focusMode = .locked; device.exposureMode = .locked
                DispatchQueue.main.async { self.focusLocked = true }
            } catch { self.report(error.localizedDescription) }
        }
    }
    func take(_ flash: Bool, file: FileSettings) {
        guard ready, !busy, saveIssue == nil else { return }; busy = true
        let shutterRecipe = current()
        capture.async {
            guard self.active, self.session.isRunning, !self.session.isInterrupted, !self.captureInFlight, self.pending == nil else {
                DispatchQueue.main.async { self.busy = false }; return
            }
            guard self.input?.device.isRampingVideoZoom != true else {
                self.finish("镜头正在变焦，请在倍率稳定后拍摄。"); return
            }
            self.captureInFlight = true; self.shot = shutterRecipe; self.shotFile = file
            let settings: AVCapturePhotoSettings
            switch file.format {
            case .raw:
                guard [12,48].contains(file.megapixels) else { self.finish("当前 RAW 只提供 12 或 48 MP。"); return }
                let formats = self.photos.availableRawPhotoPixelFormatTypes
                guard let pixelFormat = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? formats.first else { self.finish("当前镜头不支持 RAW"); return }
                settings = AVCapturePhotoSettings(rawPixelFormatType: pixelFormat)
                if !AVCapturePhotoOutput.isAppleProRAWPixelFormat(pixelFormat) { settings.photoQualityPrioritization = .speed }
            case .heif:
                guard self.photos.availablePhotoCodecTypes.contains(.hevc) else { self.finish("当前镜头不支持 HEIF"); return }
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            case .jpeg: self.finish("请选择 HEIF 或 RAW"); return
            }
            if flash {
                guard self.input?.device.isFlashAvailable == true, self.photos.supportedFlashModes.contains(.on) else { self.finish("当前镜头或拍摄配置暂不支持闪光，请关闭闪光后重试"); return }
                settings.flashMode = .on
            } else if file.autoFlash && self.input?.device.isFlashAvailable == true && self.photos.supportedFlashModes.contains(.auto) {
                settings.flashMode = .auto
            } else if self.photos.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            guard let device = self.input?.device, let size = device.activeFormat.supportedMaxPhotoDimensions.first(where: { self.mp($0) == file.megapixels && (self.usingDedicatedWide == (file.megapixels == 48)) }) else { self.finish("镜头能力已变化，请重新选择分辨率"); return }
            settings.maxPhotoDimensions = size
            let exposureSeconds = CMTimeGetSeconds(device.exposureDuration)
            let lowLight = exposureSeconds.isFinite && exposureSeconds >= 1.0/35 && device.iso >= 400
            if file.night || (file.autoNight && lowLight) {
                guard !file.live, file.format != .raw, !flash else { self.finish("低光拍摄不支持实况、RAW 或闪光灯"); return }
                settings.photoQualityPrioritization = self.photos.maxPhotoQualityPrioritization
                self.nightFrames.removeAll(); self.nightAttempts = 1
                self.nightTemplate = AVCapturePhotoSettings(from: settings)
            }
            if file.live {
                guard file.format == .heif, file.megapixels == 12, !self.usingDedicatedWide, self.photos.isLivePhotoCaptureEnabled, !self.photos.isLivePhotoCaptureSuspended, self.shot.ev == 0, self.shot.aspect == "4:3" else { self.finish("当前配置无法拍摄所选分辨率的 HEIF 实况。"); return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                self.liveError = nil; self.liveURL = url; settings.livePhotoMovieFileURL = url
            }
            self.orientPhotoForShutter()
            self.startExposure(settings)
        }
    }
    private func startExposure(_ settings: AVCapturePhotoSettings) {
        shotID = settings.uniqueID
        processedPhoto = nil
        processingError = nil
        photos.capturePhoto(with: settings, delegate: self)
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID, data = photo.fileDataRepresentation()
        capture.async {
            guard self.shotID == id else { return }
            self.processedPhoto = data
            self.processingError = error
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        capture.async {
            guard self.shotID == resolvedSettings.uniqueID else { return }
            self.liveError = error
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        capture.async {
            guard self.shotID == resolvedSettings.uniqueID else { return }
            self.shotID = nil
            let data = self.processedPhoto, failure = error ?? self.processingError
            self.processedPhoto = nil; self.processingError = nil
            if let template = self.nightTemplate {
                if failure == nil, let data { self.nightFrames.append(data) }
                if failure == nil && self.nightAttempts < 3 && self.active && self.session.isRunning && !self.session.isInterrupted {
                    self.nightAttempts += 1
                    self.startExposure(AVCapturePhotoSettings(from: template))
                    return
                }
                let frames = self.nightFrames
                self.nightTemplate = nil; self.nightFrames.removeAll()
                self.stopSessionIfHidden()
                guard let first = frames.first else { self.finish("夜景采集失败，请重试"); return }
                self.process(first, recipe: self.shot, file: self.shotFile, additional: Array(frames.dropFirst()))
                return
            }
            self.stopSessionIfHidden()
            let movie = self.liveURL; self.liveURL = nil
            if failure == nil, self.shotFile.megapixels == 48, self.mp(resolvedSettings.photoDimensions) != 48 {
                self.report("系统以 \(self.mp(resolvedSettings.photoDimensions)) MP 完成本次拍摄。")
            }
            guard failure == nil, let data else {
                if let movie { try? FileManager.default.removeItem(at: movie) }
                self.finish(failure?.localizedDescription ?? "未收到照片数据"); return
            }
            if let movie {
                guard self.liveError == nil, let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
                      type.conforms(to:.heif) || type.conforms(to:.heic),
                      (try? movie.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 > 0 else {
                    try? FileManager.default.removeItem(at: movie)
                    self.report("实况视频未完成，将尝试保留静态照片。")
                    self.process(data,recipe:self.shot,file:self.shotFile)
                    return
                }
                let recipe = self.shot
                if recipe.look == .original || recipe.strength == 0 {
                    self.save(data, suffix:"heic", thumbnail:nil, movie:movie)
                } else {
                    self.renderLive(data,movie:movie,recipe:recipe)
                }
            } else if self.shotFile.format == .raw {
                self.saveRAW(data,recipe:self.shot)
            } else { self.process(data, recipe:self.shot, file:self.shotFile) }
        }
    }
    func importPhoto(_ data: Data, recipe: Recipe, file: FileSettings) {
        guard !busy, saveIssue == nil else { return }; busy = true; process(data, recipe:recipe, file:file)
    }
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
        if additional.isEmpty, !file.night, recipe.ev == 0, recipe.look == .original || recipe.strength == 0 {
            let w = source.extent.width, h = source.extent.height
            let nativeFrame = recipe.aspect == "原始" || (recipe.aspect == "4:3" && abs(max(w,h)*3-min(w,h)*4) <= 4)
            if nativeFrame, let ref = CGImageSourceCreateWithData(data as CFData,nil),
               let identifier = CGImageSourceGetType(ref), let type = UTType(identifier as String),
               (file.format == .jpeg && type.conforms(to:.jpeg)) || (file.format == .heif && (type.conforms(to:.heic) || type.conforms(to:.heif))) {
                self.save(data,suffix:file.format == .jpeg ? "jpg" : "heic",thumbnail:nil)
                return
            }
        }
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
    private func renderLive(_ data: Data, movie: URL, recipe: Recipe) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        Task {
            defer { try? FileManager.default.removeItem(at:work) }
            do {
                try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
                var frameRecipe = recipe; frameRecipe.aspect = "原始"
                let still = work.appendingPathComponent("key.heic")
                let rendered = try await Task.detached {
                    try LiveRender.still(data, recipe:frameRecipe, destination:still)
                }.value
                let pair = try await LiveRender.movie(movie,recipe:frameRecipe,work:work)
                try await LiveRender.validate(still:still,movie:pair)
                // The capture queue takes ownership; the intermediate folder can now be removed.
                let finished = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                try FileManager.default.moveItem(at:pair,to:finished)
                save(rendered,suffix:"heic",thumbnail:nil,movie:finished)
                try? FileManager.default.removeItem(at:movie)
            } catch {
                capture.async {
                    self.pending = PendingPhoto(data:data,suffix:"heic",movie:movie,thumbnail:nil,id:UUID())
                    self.persistPending()
                    let durable = FileManager.default.fileExists(atPath:self.pendingFolder.path)
                    DispatchQueue.main.async {
                        self.saveIssue = "滤镜实况未能生成。点“重试保存”将保存原始实况。" + (durable ? "" : " 当前仅在内存保留，请勿退出应用。")
                    }
                    self.finish(nil)
                }
            }
        }
    }
    private func saveRAW(_ data: Data, recipe: Recipe) {
        guard recipe.look != .original, recipe.strength > 0 else { save(data,suffix:"dng",thumbnail:nil); return }
        processing.async { autoreleasepool {
            do {
                guard let source = CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw CocoaError(.fileReadCorruptFile) }
                let image = try self.stillRenderer.image(source,recipe)
                guard let heif = self.stillRenderer.context.heifRepresentation(of:image,format:.RGBA8,colorSpace:self.stillRenderer.space,options:[:]) else { throw CocoaError(.fileWriteUnknown) }
                self.save(heif,suffix:"heic",thumbnail:nil,alternateRAW:data)
            } catch {
                self.report("滤镜显示图生成失败，将保留 DNG 原片。")
                self.save(data,suffix:"dng",thumbnail:nil)
            }
        } }
    }
    private func save(_ data: Data, suffix: String, thumbnail: UIImage?, movie: URL? = nil, alternateRAW: Data? = nil) {
        capture.async {
            self.pending = PendingPhoto(data:data, suffix:suffix, movie:movie, thumbnail:thumbnail, id:UUID(),alternateRAW:alternateRAW)
            self.persistPending()
            self.writePending()
        }
    }
    // Publish a complete directory so a partial Live pair is never offered for recovery.
    private func persistPending() {
        guard var photo = pending else { return }
        let fm = FileManager.default, destination = pendingFolder
        let staging = destination.deletingLastPathComponent().appendingPathComponent("Capture-" + photo.id.uuidString)
        do {
            try fm.createDirectory(at:staging, withIntermediateDirectories:true)
            try photo.data.write(to:staging.appendingPathComponent("still." + photo.suffix))
            try photo.id.uuidString.write(to:staging.appendingPathComponent("id"), atomically:true, encoding:.utf8)
            if let raw = photo.alternateRAW { try raw.write(to:staging.appendingPathComponent("alternate.dng")) }
            if let movie = photo.movie { try fm.copyItem(at:movie, to:staging.appendingPathComponent("pair.mov")) }
            try fm.moveItem(at:staging, to:destination)
            if let movie = photo.movie {
                photo.movie = destination.appendingPathComponent("pair.mov"); pending = photo
                try? fm.removeItem(at:movie)
            }
        } catch {
            try? fm.removeItem(at:staging)
            // Keep the in-memory original and any temporary movie until the user retries.
        }
    }
    private func restorePending() {
        guard !inspectedPending else { return }; inspectedPending = true
        let fm = FileManager.default, folder = pendingFolder
        guard fm.fileExists(atPath:folder.path) else { return }
        do {
            if fm.fileExists(atPath:folder.appendingPathComponent("committed").path) {
                committedPending = true
                try clearPending()
                return
            }
            guard let still = try fm.contentsOfDirectory(at:folder, includingPropertiesForKeys:nil)
                .first(where: { $0.lastPathComponent.hasPrefix("still.") }) else { throw CocoaError(.fileReadCorruptFile) }
            let movie = folder.appendingPathComponent("pair.mov")
            let rawURL = folder.appendingPathComponent("alternate.dng")
            let raw = fm.fileExists(atPath:rawURL.path) ? try Data(contentsOf:rawURL,options:.mappedIfSafe) : nil
            pending = PendingPhoto(data:try Data(contentsOf:still, options:.mappedIfSafe), suffix:still.pathExtension,
                                   movie:fm.fileExists(atPath:movie.path) ? movie : nil, thumbnail:nil, id:(try? String(contentsOf:folder.appendingPathComponent("id"),encoding:.utf8)).flatMap(UUID.init(uuidString:)) ?? UUID(),alternateRAW:raw)
            DispatchQueue.main.async { self.saveIssue = "上次拍摄的照片尚待确认，请先在相册核对。" }
        } catch { DispatchQueue.main.async { self.saveIssue = "无法读取待保存照片。请重试或放弃此项。" } }
    }
    func retrySave() {
        capture.async {
            guard !self.saveInProgress else { return }
            if self.committedPending {
                do { try self.clearPending(); DispatchQueue.main.async { self.saveIssue = nil } }
                catch { self.report("清理缓存失败：" + error.localizedDescription) }
                return
            }
            if self.pending == nil { self.inspectedPending = false; self.restorePending() }
            guard self.pending != nil else { return }
            DispatchQueue.main.async { self.busy = true }
            self.writePending()
        }
    }
    func discardPending() { capture.async {
        guard !self.saveInProgress else { return }
        do { try self.clearPending(); DispatchQueue.main.async { self.saveIssue = nil } }
        catch { self.report(error.localizedDescription) }
    } }
    private func clearPending() throws {
        let fm = FileManager.default
        if let movie = pending?.movie, movie.deletingLastPathComponent().standardizedFileURL != pendingFolder.standardizedFileURL,
           fm.fileExists(atPath:movie.path) { try fm.removeItem(at:movie) }
        if fm.fileExists(atPath:pendingFolder.path) { try fm.removeItem(at:pendingFolder) }
        pending = nil; committedPending = false
    }
    private func writePending() {
        guard !saveInProgress, let photo = pending else { return }
        saveInProgress = true
        PHPhotoLibrary.requestAuthorization(for:.addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.saveFailed("请在系统设置中允许添加照片，然后重试。"); return
            }
            self.importPending(photo, originalOnly:false)
        }
    }
    private func importPending(_ photo: PendingPhoto, originalOnly: Bool) {
            let rawOnly = originalOnly || photo.suffix == "dng"
            let primary = originalOnly ? (photo.alternateRAW ?? photo.data) : photo.data
            let ext = rawOnly ? "dng" : photo.suffix
            let rawType = AVFileType.dng.rawValue
            let folder = pendingFolder
            let persisted = (try? String(contentsOf:folder.appendingPathComponent("id"),encoding:.utf8)) == photo.id.uuidString
            func attach(_ request:PHAssetCreationRequest, _ resource:PHAssetResourceType, _ data:Data, _ filename:String, _ suffix:String, _ type:String?) {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "FL-" + photo.id.uuidString + "." + suffix
                options.uniformTypeIdentifier = type
                let url = folder.appendingPathComponent(filename)
                if persisted && FileManager.default.fileExists(atPath:url.path) {
                    request.addResource(with:resource,fileURL:url,options:options)
                } else { request.addResource(with:resource,data:data,options:options) }
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                attach(request,.photo,primary,originalOnly ? "alternate.dng" : "still."+ext,ext,rawOnly ? rawType : (ext == "heic" ? AVFileType.heic.rawValue : nil))
                if !originalOnly, let raw = photo.alternateRAW {
                    attach(request,.alternatePhoto,raw,"alternate.dng","dng",rawType)
                }
                if let movie = photo.movie { request.addResource(with:.pairedVideo, fileURL:movie, options:nil) }
            }) { ok, error in
                guard ok else {
                    if !originalOnly, photo.alternateRAW != nil {
                        self.importPending(photo,originalOnly:true)
                    } else {
                        let details = error.map { e in let ns = e as NSError; return "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）" }
                        self.saveFailed(details ?? "系统相册暂时无法写入。")
                    }
                    return
                }
                self.capture.async {
                    self.saveInProgress = false
                    self.committedPending = true
                    _ = FileManager.default.createFile(atPath:self.pendingFolder.appendingPathComponent("committed").path,contents:Data())
                    let cleanupIssue: String?
                    do { try self.clearPending(); cleanupIssue = nil }
                    catch { cleanupIssue = "照片已保存。点重试清理本地缓存。" }
                    let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:160]
                    let thumb = CGImageSourceCreateWithData(primary as CFData,nil).flatMap {
                        CGImageSourceCreateThumbnailAtIndex($0,0,options as CFDictionary)
                    }.map { UIImage(cgImage:$0) } ?? photo.thumbnail
                    let jpeg = thumb?.jpegData(compressionQuality:0.8)?.base64EncodedString()
                    DispatchQueue.main.async {
                        self.still = thumb; self.latestThumbJPEG = jpeg
                        self.lastSavedID = photo.id.uuidString; self.saveIssue = cleanupIssue
                    }
                    self.finish(originalOnly ? "相册已保存 DNG 原片，滤镜显示图未能一并写入。" : nil)
                }
            }
    }
    private func saveFailed(_ reason: String) {
        capture.async {
            self.saveInProgress = false
            let durable = FileManager.default.fileExists(atPath:self.pendingFolder.path)
            DispatchQueue.main.async { self.saveIssue = reason + (durable ? "" : " 当前仅在内存保留，请勿退出应用。") }
            self.finish(nil)
        }
    }
    private func finish(_ error: String?) {
        capture.async {
            self.captureInFlight = false
            DispatchQueue.main.async { self.busy = false; if let error { self.message = error } }
        }
    }
}
