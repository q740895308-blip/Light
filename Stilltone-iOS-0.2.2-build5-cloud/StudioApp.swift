import SwiftUI
import PhotosUI
import Photos
import MetalKit
import CoreImage
import WebKit
import AVFoundation

private struct OfflineStudio: UIViewRepresentable {
    @Binding var result: String?
    final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var owner: OfflineStudio
        init(_ owner: OfflineStudio) { self.owner = owner }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true, let text = message.body as? String, let data = Data(base64Encoded:text), data.starts(with:[0xff,0xd8]) else { return }
            PHPhotoLibrary.requestAuthorization(for:.addOnly) { status in
                guard status == .authorized || status == .limited else { DispatchQueue.main.async { self.owner.result = "未获得保存权限" }; return }
                PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with:.photo,data:data,options:nil) }) { ok,error in DispatchQueue.main.async { self.owner.result = ok ? "已保存 JPEG 副本" : (error?.localizedDescription ?? "无法保存") } }
            }
        }
    }
    func makeCoordinator() -> Bridge { Bridge(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.userContentController.add(context.coordinator,name:"savePhoto")
        let view = WKWebView(frame:.zero,configuration:config); view.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource:"Stilltone-Album",withExtension:"html") { view.loadFileURL(url,allowingReadAccessTo:url) }; return view
    }
    func updateUIView(_ view: WKWebView,context:Context) {}
    static func dismantleUIView(_ view: WKWebView,coordinator:Bridge) { view.configuration.userContentController.removeScriptMessageHandler(forName:"savePhoto") }
}

private struct LibraryWorkspace: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var filter = "全部"
    @State private var permitted = false
    @State private var checked = false
    @State private var studio = false
    @State private var studioResult: String?
    var body: some View {
        NavigationStack {
            VStack {
                Picker("筛选", selection:$filter) { ForEach(["全部","收藏","截屏"],id:\.self) { Text($0) } }.pickerStyle(.segmented).padding(.horizontal)
                if checked && !permitted { Text("请在系统设置中允许访问照片") }
                else if checked && assets.isEmpty { Text("没有符合条件的照片").foregroundStyle(.secondary) }
                ScrollView { LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:2),count:3),spacing:2) {
                    ForEach(assets,id:\.localIdentifier) { asset in
                        NavigationLink { AssetWorkbench(asset:asset) } label: { LibraryThumbnail(asset:asset) }
                    }
                } }
            }.navigationTitle("相册").toolbar { Button("高级修图") { studio = true }; Button("关闭") { dismiss() } }
            .sheet(isPresented:$studio) { NavigationStack { OfflineStudio(result:$studioResult).navigationTitle("Stilltone").navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { studio = false } }.alert("Stilltone",isPresented:Binding(get:{studioResult != nil},set:{ if !$0 { studioResult = nil } })) { Button("好") { studioResult = nil } } message:{Text(studioResult ?? "")} } }
            .task(id:filter) {
                let status = await PHPhotoLibrary.requestAuthorization(for:.readWrite)
                guard !Task.isCancelled else { return }; permitted = status == .authorized || status == .limited; checked = true
                guard permitted else { assets = []; return }
                let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key:"creationDate",ascending:false)]
                if filter == "收藏" { options.predicate = NSPredicate(format:"favorite == YES") }
                if filter == "截屏" { options.predicate = NSPredicate(format:"(mediaSubtype & %d) != 0",PHAssetMediaSubtype.photoScreenshot.rawValue) }
                let list = PHAsset.fetchAssets(with:.image,options:options); var found:[PHAsset] = []; list.enumerateObjects { asset,_,_ in found.append(asset) }; assets = found
            }
        }.preferredColorScheme(.dark)
    }
}

private struct LibraryThumbnail: View {
    let asset: PHAsset
    @State private var preview: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        Color(white:0.12).aspectRatio(1,contentMode:.fit).overlay { if let preview { Image(uiImage:preview).resizable().scaledToFill() } }.clipped()
            .onAppear { let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
                request = PHImageManager.default().requestImage(for:asset,targetSize:CGSize(width:300,height:300),contentMode:.aspectFill,options:options) { image,_ in if let image { DispatchQueue.main.async { preview = image } } }
            }.onDisappear { if let request { PHImageManager.default().cancelImageRequest(request) } }
    }
}

private struct AlbumAdjustments: Codable, Equatable {
    var exposure = 0.0, contrast = 1.0, saturation = 1.0, warmth = 0.0
    static let identifier = "com.flcamera.library.adjustments"
    static func decode(_ adjustment:PHAdjustmentData?) -> Self? {
        guard let adjustment, adjustment.formatIdentifier == identifier, adjustment.formatVersion == "1" else { return nil }; return try? JSONDecoder().decode(Self.self,from:adjustment.data)
    }
    func render(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIExposureAdjust",parameters:["inputEV":exposure]).applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:contrast,kCIInputSaturationKey:saturation]).applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500+warmth*2000,y:0)])
    }
}

private struct AssetWorkbench: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var input: PHContentEditingInput?
    @State private var base: CIImage?
    @State private var preview: UIImage?
    @State private var values = AlbumAdjustments()
    @State private var initial = AlbumAdjustments()
    @State private var tab = "编辑"
    @State private var busy = false
    @State private var errorText: String?
    private static let context = CIContext()
    private var editable: Bool { asset.canPerform(.content) && !asset.mediaSubtypes.contains(.photoLive) }
    var body: some View {
        VStack {
            if let preview { Image(uiImage:preview).resizable().scaledToFit().frame(maxHeight:.infinity) } else if errorText == nil { ProgressView() }
            Picker("页面",selection:$tab) { Text("编辑").tag("编辑"); Text("详情").tag("详情") }.pickerStyle(.segmented)
            if tab == "详情" { VStack(alignment:.leading) { Text("\(asset.pixelWidth) × \(asset.pixelHeight)"); if let date = asset.creationDate { Text(date.formatted()) }; Text(PHAssetResource.assetResources(for:asset).first?.originalFilename ?? "照片") }.frame(maxWidth:.infinity,alignment:.leading) }
            else if editable { Group { slider("曝光",$values.exposure,-2...2); slider("对比度",$values.contrast,0.5...1.5); slider("饱和度",$values.saturation,0...2); slider("色温",$values.warmth,-1...1) }.disabled(input == nil || busy) }
            else { Text("此照片仅支持查看").font(.caption) }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
        }.padding().navigationTitle("照片").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(busy).interactiveDismissDisabled(busy)
        .toolbar { Button(busy ? "保存中" : "保存") { Task { await save() } }.disabled(!editable || busy || input == nil || values == initial) }
        .task {
            let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = true; options.canHandleAdjustmentData = { AlbumAdjustments.decode($0) != nil }
            let loaded: PHContentEditingInput? = await withCheckedContinuation { continuation in asset.requestContentEditingInput(with:options) { result,_ in continuation.resume(returning:result) } }
            guard !Task.isCancelled else { return }; guard let loaded, let url = loaded.fullSizeImageURL, let image = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { errorText = "无法读取照片，请检查权限或 iCloud 网络"; return }
            input = loaded; values = AlbumAdjustments.decode(loaded.adjustmentData) ?? AlbumAdjustments(); initial = values; let scale = min(1,1280/max(image.extent.width,image.extent.height)); base = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        }.task(id:PreviewKey(settings:values,ready:base != nil)) {
            guard let base else { return }; let settings = values
            do { try await Task.sleep(nanoseconds:35_000_000) } catch { return }
            let cg = await Task.detached { Self.context.createCGImage(settings.render(base),from:base.extent) }.value
            if !Task.isCancelled, let cg { preview = UIImage(cgImage:cg) }
        }
    }
    private struct PreviewKey: Equatable { let settings:AlbumAdjustments; let ready:Bool }
    private func slider(_ name:String,_ binding:Binding<Double>,_ range:ClosedRange<Double>) -> some View { HStack { Text(name).frame(width:54,alignment:.leading); Slider(value:binding,in:range); Text(String(format:"%.2f",binding.wrappedValue)).monospacedDigit().frame(width:48) } }
    @MainActor private func save() async {
        guard !busy, editable, let input, let url = input.fullSizeImageURL else { return }; busy = true; defer { busy = false }; let settings = values
        do {
            let output = PHContentEditingOutput(contentEditingInput:input)
            output.adjustmentData = PHAdjustmentData(formatIdentifier:AlbumAdjustments.identifier,formatVersion:"1",data:try JSONEncoder().encode(settings))
            let destination = output.renderedContentURL
            try await Task.detached { guard let image = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]),let space = CGColorSpace(name:CGColorSpace.sRGB) else { throw CocoaError(.fileReadCorruptFile) }; try Self.context.writeJPEGRepresentation(of:settings.render(image),to:destination,colorSpace:space,options:[:]) }.value
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for:asset).contentEditingOutput = output }; dismiss()
        } catch { errorText = "未保存：" + error.localizedDescription }
    }
}

private final class CameraFeedView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var feed: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
private struct CameraFeed: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraFeedView {
        let view = CameraFeedView(); view.feed.videoGravity = .resizeAspectFill; view.feed.session = session; return view
    }
    func updateUIView(_ view: CameraFeedView, context: Context) {
        if let connection = view.feed.connection, connection.isVideoOrientationSupported, let pose = view.window?.windowScene?.interfaceOrientation, let orientation = AVCaptureVideoOrientation(rawValue:pose.rawValue) { connection.videoOrientation = orientation }
    }
}
struct GPUPreview: UIViewRepresentable {
    let camera: Camera
    let enabled: Bool
    final class Driver: NSObject, MTKViewDelegate {
        let camera: Camera
        let device = MTLCreateSystemDefaultDevice()
        lazy var queue = device?.makeCommandQueue()
        lazy var renderer = Renderer(gpu: device)
        let slots = DispatchSemaphore(value: 2)
        init(_ camera: Camera) { self.camera = camera }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let (buffer, recipe) = camera.previewFrame(), slots.wait(timeout: .now()) == .success else { return }
            guard let command = queue?.makeCommandBuffer(), let drawable = view.currentDrawable else { slots.signal(); return }
            let source = CIImage(cvPixelBuffer: buffer)
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            let scale = max(bounds.width/source.extent.width, bounds.height/source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let image = (try? renderer.image(scaled, recipe)) ?? scaled
            let centered = image.transformed(by: CGAffineTransform(translationX: bounds.midX-image.extent.midX, y: bounds.midY-image.extent.midY)).composited(over: CIImage(color: .black)).cropped(to: bounds)
            renderer.context.render(centered, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: renderer.space)
            command.addCompletedHandler { [slots] _ in slots.signal() }; command.present(drawable); command.commit()
        }
    }
    func makeCoordinator() -> Driver { Driver(camera) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.framebufferOnly = false; view.colorPixelFormat = .bgra8Unorm; view.preferredFramesPerSecond = 60; view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: MTKView, context: Context) { view.isPaused = !enabled || !camera.ready }
}

@main struct StudioApp: App {
    var body: some Scene { WindowGroup { CameraScreen().preferredColorScheme(.dark) } }
}

struct CameraScreen: View {
    @StateObject private var camera = Camera()
    @Environment(\.scenePhase) private var phase
    @State private var recipe = Recipe(aspect:"4:3")
    @State private var focusPoint: CGPoint?
    @State private var initialEV: Double?
    @State private var bottomPicker = ""
    @State private var pinchStart: Double?
    @State private var timerSeconds = 0
    @State private var countdown: Task<Void,Never>?
    @State private var remaining = 0
    @State private var file = FileSettings()
    @State private var editRecipe = Recipe()
    @State private var editPreview: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var railStart: CGFloat?
    @State private var railOffset: CGFloat?
    private var expanded: Bool { !bottomPicker.isEmpty }
    @State private var grid = true
    @State private var flash = false
    @State private var albumOpen = false
    @State private var imported: Data?
    @State private var importing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showPanel("格式") } label: { Text(file.format.rawValue).font(.system(size:12,weight:.semibold)).padding(7).background(.ultraThinMaterial,in:Capsule()) }
                Spacer()
                Button { flash.toggle(); if flash { file.night = false } } label: { Image(systemName: flash && camera.flashAvailable ? "bolt.fill" : "bolt.slash.fill").frame(width: 44, height: 44) }.disabled(!camera.flashAvailable).accessibilityLabel("闪光灯")
                Button { toggleLive() } label: { Image(systemName:file.live ? "livephoto" : "livephoto.slash").foregroundStyle(file.live ? Color.yellow : .white) }.disabled(!camera.liveAvailable)
                Button { showPanel("滤镜") } label: { Image(systemName:"camera.filters").frame(width:44,height:44) }.accessibilityLabel("滤镜")
            }.padding(.horizontal)
            Spacer(minLength: 0)
            GeometryReader { frame in
                let portrait = frame.size.height >= frame.size.width
                let ratio:CGFloat = recipe.aspect == "1:1" ? 1 : recipe.aspect == "16:9" ? (portrait ? 9.0/16 : 16.0/9) : (portrait ? 3.0/4 : 4.0/3)
                let width = min(frame.size.width,frame.size.height*ratio)
                ZStack(alignment:.bottom) {
                Color.black.overlay {
                    ZStack { CameraFeed(session:camera.session); GPUPreview(camera:camera,enabled:recipe.look != .original || recipe.ev != 0).opacity(recipe.look != .original || recipe.ev != 0 ? 1 : 0) }.clipped().overlay { GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                            if !bottomPicker.isEmpty { bottomPicker = ""; return }; guard !expanded, camera.ready else { return }; focusPoint = tap.location; camera.focus(at:tap.location, in:geometry.size, aspect:recipe.aspect)
                        }).simultaneousGesture(MagnificationGesture().onChanged { scale in
                            guard camera.ready, !camera.busy, !expanded, bottomPicker.isEmpty else { return }
                            let start = pinchStart ?? camera.lens; pinchStart = start; camera.selectLens(start * Double(scale))
                        }.onEnded { _ in pinchStart = nil })
                        if let point = focusPoint, bottomPicker.isEmpty && !expanded {
                            Rectangle().stroke(.yellow,lineWidth:1).frame(width:48,height:48).position(point).allowsHitTesting(false)
                            Image(systemName:"sun.max.fill").foregroundStyle(.yellow).frame(width:44,height:48).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { drag in
                                let base = initialEV ?? recipe.ev; initialEV = base; recipe.ev = min(2,max(-2,base-Double(drag.translation.height)/65))
                            }.onEnded { _ in initialEV = nil }).position(x:point.x + (point.x > geometry.size.width-60 ? -40 : 40),y:point.y)
                        }
                    } }
                    if grid { Canvas { context, size in
                        var path = Path(); for part in [1.0/3, 2.0/3] { let x = size.width * CGFloat(part), y = size.height * CGFloat(part); path.move(to: CGPoint(x:x,y:0)); path.addLine(to: CGPoint(x:x,y:size.height)); path.move(to: CGPoint(x:0,y:y)); path.addLine(to: CGPoint(x:size.width,y:y)) }; context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.6)
                    }.allowsHitTesting(false) }
                }.clipped()
                if !expanded { HStack(spacing: 6) { ForEach(camera.lenses,id: \.self) { value in
                    let active = value == (camera.lenses.filter { $0 <= camera.lens + 0.001 }.max() ?? 1)
                    Button { camera.selectLens(value) } label: { Text(active ? camera.lens.formatted(.number.precision(.fractionLength(0...1))) + "×" : value == 0.5 ? ".5" : value.formatted()).font(.subheadline.monospacedDigit()).frame(width: 42,height: 42).background(.black.opacity(active ? 0.55 : 0),in: Circle()).foregroundStyle(active ? Color.yellow : .white) }.disabled(!camera.ready || camera.busy)
                } }.padding(.bottom,12) }
                }.frame(width:width,height:width/ratio).frame(maxWidth:.infinity,maxHeight:.infinity).animation(reduceMotion ? nil : .easeInOut(duration:0.24),value:recipe.aspect)
            }.layoutPriority(1)
            Spacer(minLength:0)
            ZStack { Button { shutter() } label: { ZStack { Circle().fill(.ultraThinMaterial).overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75) }; Circle().fill(.white).padding(6); if remaining > 0 { Text("\(remaining)").foregroundStyle(.black) }; if camera.busy { ProgressView().tint(.black) } }.frame(width:76,height:76) }.disabled(!camera.ready || camera.busy || importing).accessibilityLabel("拍照")
                HStack { Spacer(); Button { showPanel("控制") } label: { sixDots.frame(width:46,height:46).background(.white.opacity(0.12),in: Circle()) }.accessibilityLabel("相机控制") }.padding(.horizontal,32)
            }
            HStack {
                Button { albumOpen = true } label: {
                    Group { if let still = camera.still { Image(uiImage: still).resizable().scaledToFill() } else { Image(systemName: "photo.on.rectangle").font(.title2) } }.frame(width: 46,height: 46).background(.ultraThinMaterial,in:Circle()).clipShape(Circle())
                }.disabled(camera.busy || importing).accessibilityLabel("从相册导入")
                Spacer()
                HStack(spacing:16) { Text("视频").foregroundStyle(.secondary); Text("照片").foregroundStyle(.yellow); Text("人像").foregroundStyle(.secondary) }.font(.system(size:15,weight:.medium)).fixedSize().padding(10).background(.ultraThinMaterial,in:Capsule())
                Spacer()
                Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 46,height: 46).background(.ultraThinMaterial,in:Circle()) }.disabled(!camera.ready || camera.busy).accessibilityLabel("翻转摄像头")
            }.padding(.horizontal,24).padding(.vertical,14)
        }.overlay { panelOverlay }.foregroundStyle(.white).background(Color.black.ignoresSafeArea()).statusBarHidden().onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications(); camera.start(); camera.setPose(UIDevice.current.orientation) }.onDisappear { camera.enableThumbnails(false); UIDevice.current.endGeneratingDeviceOrientationNotifications(); camera.stop() }
        .onReceive(NotificationCenter.default.publisher(for:UIDevice.orientationDidChangeNotification)) { _ in camera.setPose(UIDevice.current.orientation) }
        .onChange(of:bottomPicker) { value in camera.enableThumbnails(value == "滤镜") }
        .onAppear { camera.update(recipe) }
        .onChange(of: file.format) { value in if value == .raw { file.night = false; file.live = false; recipe.aspect = "4:3"; camera.update(recipe) } }
        .onChange(of: file.night) { camera.setNight($0) }
        .onChange(of: file.megapixels) { value in if value > 12 { file.live = false } }
        .onChange(of: recipe.ev) { value in if value != 0 { file.live = false } }
        .onChange(of: camera.liveAvailable) { available in if !available { file.live = false } }
        .onChange(of: phase) { value in if value == .active { camera.start() } else { countdown?.cancel(); countdown = nil; remaining = 0; if value == .background { camera.stop() } } }
        .onChange(of: recipe.strength) { _ in camera.update(recipe) }.onChange(of: recipe.ev) { _ in camera.update(recipe) }
        .onChange(of: camera.sizesMP) { sizes in if !sizes.contains(file.megapixels), let fallback = sizes.first { file.megapixels = fallback } }
        .onChange(of: camera.rawAvailable) { available in if !available && file.format == .raw { file.format = camera.heifAvailable ? .heif : .jpeg } }
        .onChange(of: camera.heifAvailable) { available in if file.format != .raw { file.format = available ? .heif : .jpeg } }
        .sheet(isPresented:$albumOpen) { LibraryWorkspace() }
        .alert("FL Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) { Button("好") { camera.message = nil } } message: { Text(camera.message ?? "") }
    }
    private var sixDots: some View {
        VStack(spacing:3) { ForEach(0..<2) { _ in HStack(spacing:3) { ForEach(0..<3) { _ in Circle().fill(.white).frame(width:4,height:4) } } } }
    }
    private func showPanel(_ page:String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration:0.24)) { bottomPicker = page; railOffset = nil; railStart = nil }
    }
    private var panelOverlay: some View {
        GeometryReader { bounds in
            ZStack(alignment:.bottom) {
                if expanded { Color.clear.contentShape(Rectangle()).onTapGesture { showPanel("") } }
                VStack(spacing:8) {
                    if expanded {
                        Capsule().fill(.white.opacity(0.85)).frame(width:38,height:4).frame(width:100,height:30).contentShape(Rectangle()).onTapGesture { showPanel("") }.gesture(DragGesture(minimumDistance:6).onEnded { if $0.translation.height > 14 { showPanel("") } })
                        panelContents.id(bottomPicker).transition(.opacity)
                        Spacer(minLength:0)
                    }
                }
                .padding(.horizontal,expanded ? 12 : 0)
                .frame(width:expanded ? max(1,bounds.size.width-16) : 130,height:expanded ? (bottomPicker == "控制" ? min(400,bounds.size.height*0.50) : min(214,bounds.size.height*0.45)) : 42)
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:26)).clipShape(RoundedRectangle(cornerRadius:26))
                .opacity(expanded ? 1 : 0).padding(.bottom,expanded ? 6 : 16)
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom).allowsHitTesting(expanded)
        }
    }
    @ViewBuilder private var panelContents: some View {
        if bottomPicker == "控制" {
            GeometryReader { geo in
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:0) {
                    ForEach(["闪光灯","实况","计时器","曝光","滤镜","宽高比","夜间模式","参考线","格式"],id:\.self) { name in
                        Button { tapControl(name) } label: { VStack(spacing:3) {
                            Group { if name == "格式" { VStack(spacing:0) { Text(file.format.rawValue); Text("\(file.megapixels)").font(.system(size:10)) }.font(.system(size:13)) } else { Image(systemName:symbol(name)).font(.system(size:19)) } }.frame(width:min(60,geo.size.height/5),height:min(60,geo.size.height/5)).background(.black.opacity(0.4),in:Circle()); Text(name).font(.system(size:11))
                        }.foregroundStyle(highlight(name) ? Color.yellow : .white).frame(maxWidth:.infinity).frame(height:geo.size.height/3) }.disabled((name == "闪光灯" && !camera.flashAvailable) || (name == "实况" && !camera.liveAvailable))
                    }
                }
            }
        } else {
            ZStack { Text(bottomPicker).font(.system(size:13)); HStack { Button { showPanel("控制") } label: { Image(systemName:"chevron.left").frame(width:44,height:32) }.accessibilityLabel("返回相机控制"); Spacer() } }
            switch bottomPicker {
            case "格式":
                HStack { ForEach(PhotoFormat.allCases,id:\.self) { fmt in
                    if (fmt == .jpeg && !camera.heifAvailable) || (fmt == .heif && camera.heifAvailable) || (fmt == .raw && camera.rawAvailable) { choice(fmt.rawValue,file.format == fmt) { file.format = fmt } }
                } }; HStack { ForEach(camera.sizesMP,id:\.self) { size in choice("\(size) MP",file.megapixels == size) { file.megapixels = size } } }
            case "计时器": HStack { ForEach([0,3,10],id:\.self) { seconds in choice(seconds == 0 ? "关闭" : "\(seconds) 秒",seconds == timerSeconds) { timerSeconds = seconds } } }
            case "曝光": HStack { Slider(value:$recipe.ev,in:-2...2,step:0.1); Text(String(format:"%+.1f",recipe.ev)).monospacedDigit() }.padding().tint(.yellow)
            case "宽高比": HStack { ForEach(["4:3","16:9","1:1"],id:\.self) { ratio in choice(ratio,recipe.aspect == ratio) { if recipe.aspect != ratio { choose(ratio) } } } }
            case "滤镜": filterRail
            default: EmptyView()
            }
        }
    }
    private func choice(_ text:String,_ active:Bool,action:@escaping ()->Void)->some View {
        Button(action:action) { Text(text).font(.system(size:13)).frame(minWidth:54,minHeight:38).foregroundStyle(active ? Color.yellow : .white) }
    }
    private func symbol(_ name:String)->String {
        ["闪光灯":flash ? "bolt.fill" : "bolt.slash.fill","实况":"livephoto","计时器":"timer","曝光":"plusminus","滤镜":"camera.filters","宽高比":"aspectratio","夜间模式":"moon.fill","参考线":"grid"][name] ?? "photo"
    }
    private func highlight(_ name:String)->Bool {
        ["闪光灯":flash,"实况":file.live,"计时器":timerSeconds != 0,"曝光":recipe.ev != 0,"滤镜":recipe.look != .original,"宽高比":recipe.aspect != "4:3","夜间模式":file.night,"参考线":grid][name] ?? false
    }
    private func tapControl(_ name:String) {
        switch name {
        case "闪光灯": flash.toggle(); if flash { file.night = false }
        case "实况": toggleLive()
        case "参考线": grid.toggle()
        case "夜间模式": file.night.toggle(); if file.night { flash = false; file.live = false; if file.format == .raw { file.format = camera.heifAvailable ? .heif : .jpeg } }
        default: showPanel(name)
        }
    }
    private var filterRail: some View {
        GeometryReader { geo in
            let looks = Look.allCases, pitch = min(88,geo.size.width*0.30), side = pitch-8
            let selected = looks.firstIndex(of:recipe.look) ?? 0
            ZStack(alignment:.topLeading) {
                HStack(spacing:0) { ForEach(looks,id:\.self) { look in
                    Button { if recipe.look == look { showPanel("") } else { withAnimation(reduceMotion ? nil : .easeOut(duration:0.2)) { choose(look.title) } } } label: {
                        VStack(spacing:4) { Group { if let thumb = camera.thumbnails[look] { Image(uiImage:thumb).resizable().scaledToFill() } else { Color.black } }.frame(width:side,height:side).clipShape(RoundedRectangle(cornerRadius:8)); Text(look.title).font(.system(size:11)).foregroundStyle(look == recipe.look ? Color.yellow : .white) }.frame(width:pitch)
                    }
                } }.fixedSize().offset(x:geo.size.width/2-pitch/2-(railOffset ?? CGFloat(selected))*pitch)
                RoundedRectangle(cornerRadius:8).strokeBorder(.white,lineWidth:2).frame(width:side,height:side).offset(x:(geo.size.width-side)/2).allowsHitTesting(false)
            }.frame(width:geo.size.width,alignment:.leading).clipped().contentShape(Rectangle()).simultaneousGesture(DragGesture(minimumDistance:6).onChanged { drag in
                let start = railStart ?? CGFloat(selected); railStart = start; let pos = min(CGFloat(looks.count-1),max(0,start-drag.translation.width/pitch)); railOffset = pos
                let look = looks[Int(pos.rounded())]; if recipe.look != look { choose(look.title) }
            }.onEnded { _ in withAnimation(reduceMotion ? nil : .easeOut(duration:0.2)) { railOffset = nil; railStart = nil } })
        }
    }
    private func choose(_ value:String) {
        if bottomPicker == "滤镜",let look = Look.allCases.first(where:{$0.title == value}) { recipe.look = look; if look != .original { file.live = false } }
        else if file.format != .raw { recipe.aspect = value; if value != "4:3" { file.live = false } } else { camera.message = "RAW 原片保留传感器比例" }; camera.update(recipe)
    }
    private func toggleLive() {
        if file.live { file.live = false; return }; guard camera.liveAvailable,camera.heifAvailable,let size = camera.sizesMP.last(where:{$0 <= 12}) else { camera.message = "当前配置不支持实况"; return }; file.night = false; flash = false; file.format = .heif; file.megapixels = size; recipe = Recipe(aspect:"4:3"); camera.update(recipe); file.live = true
    }
    private func shutter() {
        if countdown != nil { countdown?.cancel(); countdown = nil; remaining = 0; return }; if timerSeconds == 0 { camera.take(flash,file:file); return }; remaining = timerSeconds; countdown = Task { @MainActor in while remaining > 0 { do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return }; remaining -= 1 }; countdown = nil; camera.take(flash,file:file) }
    }
}
