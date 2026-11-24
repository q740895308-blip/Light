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
            let scale = min(bounds.width/source.extent.width, bounds.height/source.extent.height)
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
    func updateUIView(_ view: MTKView, context: Context) { view.isPaused = !camera.ready }
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
    @State private var formatMenu = false
    @State private var editRecipe = Recipe()
    @State private var editPreview: UIImage?
    @State private var expanded = false
    @State private var grid = true
    @State private var tool = ""
    @State private var flash = false
    @State private var albumOpen = false
    @State private var imported: Data?
    @State private var importing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { formatMenu = true } label: { Text(file.format.rawValue).font(.system(size:12,weight:.semibold)).padding(7).background(.ultraThinMaterial,in:Capsule()) }
                Spacer()
                Button { flash.toggle(); if flash { file.night = false } } label: { Image(systemName: flash && camera.flashAvailable ? "bolt.fill" : "bolt.slash.fill").frame(width: 44, height: 44) }.disabled(!camera.flashAvailable).accessibilityLabel("闪光灯")
                Button { toggleLive() } label: { Image(systemName:file.live ? "livephoto" : "livephoto.slash").foregroundStyle(file.live ? Color.yellow : .white) }.disabled(!camera.liveAvailable)
                Button { expanded = false; bottomPicker = bottomPicker == "滤镜" ? "" : "滤镜" } label: { Image(systemName:"camera.filters").frame(width:44,height:44) }.accessibilityLabel("滤镜")
            }.padding(.horizontal)
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                Color(white: 0.06).aspectRatio(3/4, contentMode: .fit).overlay {
                    ZStack { CameraFeed(session:camera.session); if recipe.look != .original || recipe.ev != 0 || recipe.aspect != "4:3" { GPUPreview(camera:camera) } }.clipped().overlay { GeometryReader { geometry in
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
                if expanded { VStack(spacing: 8) {
                    Capsule().fill(.secondary).frame(width:38,height:4)
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3)) {
                        tile("闪光灯",flash ? "bolt.fill" : "bolt.slash",enabled:camera.flashAvailable) { flash.toggle(); if flash { file.night = false } }; tile("实况",file.live ? "livephoto" : "livephoto.slash",enabled:camera.liveAvailable) { toggleLive() }; tile("宽高比","aspectratio") { expanded = false; bottomPicker = "宽高比" }
                        tile(timerSeconds == 0 ? "计时器" : "\(timerSeconds) 秒","timer") { timerSeconds = timerSeconds == 0 ? 3 : timerSeconds == 3 ? 10 : 0 }; tile("曝光","plusminus") { tool = "曝光" }; tile("参考线","grid") { grid.toggle() }
                        tile("滤镜","camera.filters") { expanded = false; bottomPicker = "滤镜" }; tile(file.night ? "低光已开" : "夜间模式",file.night ? "moon.fill" : "moon",enabled:camera.ready && !camera.busy) { file.night.toggle(); if file.night { flash = false; file.live = false; if file.format == .raw { file.format = camera.heifAvailable ? .heif : .jpeg }; camera.message = "低光辅助已开启，请保持稳定" } }; tile("\(file.format.rawValue) \(file.megapixels)","photo") { formatMenu = true }
                    }
                    if tool == "曝光" { HStack { Text("曝光"); Slider(value: $recipe.ev, in: -2...2, step: 0.1); Text(String(format: "%+.1f", recipe.ev)) } }
                }.font(.caption.monospacedDigit()).tint(.yellow).padding(12).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:26)).padding(.horizontal,8) }
            }.layoutPriority(1)
            Spacer(minLength: 0)
            if !bottomPicker.isEmpty { VStack { HStack { Button { bottomPicker = ""; expanded = true } label: { Image(systemName:"chevron.left") }; Spacer(); Text(bottomPicker); Spacer(); Button("完成") { bottomPicker = "" } }; Text(bottomPicker == "滤镜" ? recipe.look.title : recipe.aspect).font(.title); HStack { ForEach(visiblePickerValues,id: \.self) { value in Button { if isSelected(value) { bottomPicker = "" } else { choose(value) } } label: { VStack(spacing:8) { if bottomPicker == "滤镜",let look = Look.allCases.first(where:{$0.title == value}) { Group { if let thumb = camera.thumbnails[look] { Image(uiImage:thumb).resizable().scaledToFill() } else { Color.black } }.frame(height:48) }; Text(value).font(.caption).lineLimit(1) }.padding(3).foregroundStyle(isSelected(value) ? Color.yellow : .white).overlay(RoundedRectangle(cornerRadius:5).stroke(isSelected(value) ? Color.yellow : .clear,lineWidth:1.5)) } } } }.padding().frame(maxWidth:.infinity).background(Color.clear.contentShape(Rectangle()).onTapGesture { bottomPicker = "" }).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:24)).contentShape(Rectangle()).simultaneousGesture(DragGesture(minimumDistance:24).onEnded { drag in let values = pickerValues; guard let index = values.firstIndex(of:bottomPicker == "滤镜" ? recipe.look.title : recipe.aspect) else { return }; choose(values[max(0,min(values.count-1,index+(drag.translation.width < 0 ? 1 : -1)))]) }) } else {
            ZStack { Button { shutter() } label: { ZStack { Circle().fill(.ultraThinMaterial).overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75) }; Circle().fill(.white).padding(6); if remaining > 0 { Text("\(remaining)").foregroundStyle(.black) }; if camera.busy { ProgressView().tint(.black) } }.frame(width:76,height:76) }.disabled(!camera.ready || camera.busy || importing).accessibilityLabel("拍照")
                HStack { Spacer(); Button { withAnimation { expanded.toggle(); tool = "" } } label: { Image(systemName:"circle.grid.3x2.fill").frame(width:46,height:46).background(.white.opacity(0.12),in: Circle()) }.accessibilityLabel("相机控制") }.padding(.horizontal,32)
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
            }
        }.foregroundStyle(.white).background(Color.black.ignoresSafeArea()).statusBarHidden().onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications(); camera.start(); camera.setPose(UIDevice.current.orientation) }.onDisappear { camera.enableThumbnails(false); UIDevice.current.endGeneratingDeviceOrientationNotifications(); camera.stop() }
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
        .sheet(isPresented:$formatMenu) {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text("拍摄格式").font(.headline); Spacer(); Button("完成") { formatMenu = false } }
                Text("格式").font(.caption)
                Picker("格式",selection:$file.format) { if camera.heifAvailable { Text("HEIF").tag(PhotoFormat.heif) } else { Text("JPEG").tag(PhotoFormat.jpeg) }; if camera.rawAvailable { Text("RAW").tag(PhotoFormat.raw) } }.pickerStyle(.segmented)
                Text("分辨率").font(.caption)
                Picker("分辨率",selection:$file.megapixels) { ForEach(camera.sizesMP,id: \.self) { size in Text("\(size) MP").tag(size) } }.pickerStyle(.segmented)
            }.padding(20).presentationDetents([.height(240)]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented:$albumOpen) { LibraryWorkspace() }
        .alert("FL Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) { Button("好") { camera.message = nil } } message: { Text(camera.message ?? "") }
    }
    private func tile(_ title:String,_ symbol:String,enabled:Bool = true, action:@escaping () -> Void) -> some View {
        Button(action:action) { VStack(spacing:4) { Image(systemName:symbol).font(.title3).frame(width:44,height:44).background(.black.opacity(0.4),in:Circle()); Text(title) } }.disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
    private func isSelected(_ value:String) -> Bool { value == (bottomPicker == "滤镜" ? recipe.look.title : recipe.aspect) }
    private var visiblePickerValues:[String] { let all = pickerValues; guard bottomPicker == "滤镜", let index = all.firstIndex(of:recipe.look.title) else { return all }; let start = min(max(0,all.count-3),max(0,index-1)); return Array(all.dropFirst(start).prefix(3)) }
    private var pickerValues:[String] { bottomPicker == "滤镜" ? Look.allCases.map(\.title) : ["4:3","16:9","1:1"] }
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
