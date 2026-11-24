import SwiftUI
import PhotosUI

@main struct StudioApp: App {
    var body: some Scene { WindowGroup { CameraScreen().preferredColorScheme(.dark) } }
}

struct CameraScreen: View {
    @StateObject private var camera = Camera()
    @Environment(\.scenePhase) private var phase
    @State private var recipe = Recipe()
    @State private var expanded = false
    @State private var flash = false
    @State private var selection: PhotosPickerItem?
    @State private var imported: Data?
    @State private var importing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { flash.toggle() } label: { Image(systemName: flash && camera.flashAvailable ? "bolt.fill" : "bolt.slash.fill").frame(width: 44, height: 44) }.disabled(!camera.flashAvailable).accessibilityLabel("闪光灯")
                Spacer()
                Button { withAnimation { expanded.toggle() } } label: { Image(systemName: expanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill").frame(width: 44,height: 44) }.accessibilityLabel("拍摄控制")
                Spacer()
                Button { withAnimation { expanded.toggle() } } label: { Image(systemName: "camera.filters").foregroundStyle(recipe.look == .original ? Color.white : .yellow).frame(width: 44,height: 44) }.accessibilityLabel("更换滤镜")
            }.padding(.horizontal)
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                Color(white: 0.06).aspectRatio(3/4, contentMode: .fit).overlay {
                    if let frame = camera.frame { Image(uiImage: frame).resizable().scaledToFit() }
                    else { Image(systemName: "camera").font(.largeTitle).foregroundStyle(.secondary) }
                }.clipped()
                if expanded { VStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(Look.allCases, id: \.self) { look in
                        Button(look.title) { recipe.look = look; camera.update(recipe) }.font(.subheadline.weight(.medium)).foregroundStyle(recipe.look == look ? Color.yellow : .white).padding(7)
                    } } }
                    HStack { Text("强度"); Slider(value: $recipe.strength, in: 0...1); Text(recipe.strength, format: .percent.precision(.fractionLength(0))) }.disabled(recipe.look == .original)
                    HStack { Text("曝光"); Slider(value: $recipe.ev, in: -2...2, step: 0.1); Text(String(format: "%+.1f", recipe.ev)) }
                }.font(.caption.monospacedDigit()).tint(.yellow).padding(12).background(.black.opacity(0.8)) }
            }.layoutPriority(1)
            Spacer(minLength: 0)
            Text("照片").font(.subheadline.weight(.semibold)).foregroundStyle(.yellow).padding(10)
            HStack {
                PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                    Group { if let still = camera.still { Image(uiImage: still).resizable().scaledToFill() } else { Image(systemName: "photo.on.rectangle").font(.title2) } }.frame(width: 46,height: 46).clipped().cornerRadius(6)
                }.disabled(camera.busy || importing).accessibilityLabel("从相册导入")
                Spacer()
                Button { camera.take(flash) } label: { ZStack { Circle().strokeBorder(.white,lineWidth: 4); Circle().fill(.white).padding(7); if camera.busy { ProgressView().tint(.black) } }.frame(width: 76,height: 76) }.disabled(!camera.ready || camera.busy || importing).accessibilityLabel("拍照")
                Spacer()
                Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 46,height: 46).background(Color(white: 0.16),in: Circle()) }.disabled(!camera.ready || camera.busy).accessibilityLabel("翻转摄像头")
            }.padding(.horizontal,32).padding(.bottom,14)
        }.foregroundStyle(.white).background(Color.black.ignoresSafeArea()).statusBarHidden().onAppear { camera.start() }.onDisappear { camera.stop() }
        .onChange(of: phase) { value in if value == .active { camera.start() } else if value == .background { camera.stop() } }
        .onChange(of: recipe.strength) { _ in camera.update(recipe) }.onChange(of: recipe.ev) { _ in camera.update(recipe) }
        .onChange(of: selection) { item in guard let item else { return }; importing = true; Task { @MainActor in
            defer { selection = nil; importing = false }; do { guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }; imported = data } catch { camera.message = "导入失败：" + error.localizedDescription }
        } }
        .confirmationDialog("将当前滤镜和曝光应用到所选照片？", isPresented: Binding(get: { imported != nil }, set: { _ in }), titleVisibility: .visible) {
            Button("另存到相册") { if let data = imported { camera.importPhoto(data, recipe: recipe) }; imported = nil }
            Button("取消",role: .cancel) { imported = nil }
        }
        .alert("FL Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) { Button("好") { camera.message = nil } } message: { Text(camera.message ?? "") }
    }
}
