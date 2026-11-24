import SwiftUI
import AVFoundation
import CoreImage
import Photos
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

enum Look: String, CaseIterable {
    case original, FL2, FL3, positive = "GR-Positive", negative = "Classic-Negative"
    var title: String {
        switch self { case .original: return "原图"; case .positive: return "GR 正片"; case .negative: return "经典负片"; default: return rawValue }
    }
}

struct Recipe {
    var look = Look.original
    var strength = 1.0
    var ev = 0.0
}

final class Renderer {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
    private var tables = [Look: Data]()
    func image(_ source: CIImage, _ recipe: Recipe) throws -> CIImage {
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
    @Published var frame: UIImage?
    @Published var still: UIImage?
    @Published var ready = false
    @Published var busy = false
    @Published var message: String?
    @Published var flashAvailable = false
    let session = AVCaptureSession()
    private let capture = DispatchQueue(label: "fl.capture")
    private let frames = DispatchQueue(label: "fl.frames")
    private let processing = DispatchQueue(label: "fl.photo")
    private let previewRenderer = Renderer(), stillRenderer = Renderer()
    private let photos = AVCapturePhotoOutput(), video = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var selected = Recipe(), shot = Recipe()
    private var lastTime = -Double.infinity
    private let lock = NSLock()
    private var publishPending = false
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
    private func deviceInput(_ position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }
    private func configure() {
        guard let newInput = deviceInput(.back) ?? deviceInput(.front) else { report("此设备没有可用摄像头。"); return }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(newInput) else { report("无法打开摄像头。"); return }; session.addInput(newInput)
        guard session.canAddOutput(photos) else { session.removeInput(newInput); report("无法启动照片输出。"); return }; session.addOutput(photos)
        guard session.canAddOutput(video) else { session.removeInput(newInput); session.removeOutput(photos); report("无法启动取景。"); return }
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.addOutput(video); video.setSampleBufferDelegate(self, queue: frames)
        input = newInput; orient()
    }
    private func orient() {
        let front = input?.device.position == .front
        for output in [video as AVCaptureOutput, photos as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = front }
        }
        let available = input?.device.hasFlash == true
        DispatchQueue.main.async { self.flashAvailable = available }
    }
    func flip() { capture.async {
        guard !self.captureInFlight, let old = self.input, let next = self.deviceInput(old.device.position == .back ? .front : .back) else { self.report("无法切换摄像头。"); return }
        self.session.beginConfiguration(); self.session.removeInput(old)
        if self.session.canAddInput(next) { self.session.addInput(next); self.input = next } else { self.session.addInput(old) }
        self.orient(); self.session.commitConfiguration()
    } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CACurrentMediaTime(); guard time-lastTime >= 1.0/24, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }; lastTime = time
        lock.lock(); let skip = publishPending; if !skip { publishPending = true }; lock.unlock(); guard !skip else { return }
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer), scale = min(1, 960/max(source.extent.width, source.extent.height))
            do {
                let image = try previewRenderer.image(source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), current())
                let rendered = previewRenderer.context.createCGImage(image, from: image.extent)
                DispatchQueue.main.async { if let rendered { self.frame = UIImage(cgImage: rendered) }; self.lock.lock(); self.publishPending = false; self.lock.unlock() }
            } catch { lock.lock(); publishPending = false; lock.unlock() }
        }
    }
    func take(_ flash: Bool) {
        guard ready, !busy else { return }; busy = true
        capture.async {
            guard self.session.isRunning, !self.captureInFlight else { DispatchQueue.main.async { self.busy = false }; return }
            self.captureInFlight = true; self.shot = self.current()
            let settings = AVCapturePhotoSettings()
            if self.input?.device.hasFlash == true { settings.flashMode = flash ? .on : .off }
            self.photos.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        capture.async { let recipe = self.shot
            guard error == nil, let data else { self.finish("拍摄失败"); return }
            self.process(data, recipe: recipe)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) { if let error { finish(error.localizedDescription) } }
    func importPhoto(_ data: Data, recipe: Recipe) { guard !busy else { return }; busy = true; process(data, recipe: recipe) }
    private func process(_ data: Data, recipe: Recipe) { processing.async { autoreleasepool {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { self.finish("系统不能解码此照片。"); return }
        do {
            let image = try self.stillRenderer.image(source, recipe)
            guard let jpeg = self.stillRenderer.context.jpegRepresentation(of: image, colorSpace: self.stillRenderer.space, options: [:]) else { self.finish("无法生成 JPEG。"); return }
            let thumbnail = UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 480,height: 640))
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { self.finish("未保存：请在设置中允许添加照片。"); return }
                PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil) }) { success, error in
                    if success { DispatchQueue.main.async { self.still = thumbnail } }
                    self.finish(success ? nil : (error?.localizedDescription ?? "保存失败"))
                }
            }
        } catch { self.finish(error.localizedDescription) }
    } } }
    private func finish(_ error: String?) { capture.async { self.captureInFlight = false }; DispatchQueue.main.async { self.busy = false; if let error { self.message = error } } }
}
