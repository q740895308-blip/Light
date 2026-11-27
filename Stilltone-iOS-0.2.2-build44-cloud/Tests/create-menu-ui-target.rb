require 'xcodeproj'

# Add the UI runner to a temporary copy; the shipping Xcode project stays untouched.
project = Xcodeproj::Project.open(ARGV.fetch(0))
app = project.targets.find { |target| target.name == 'FLCamera' }
app.add_file_references([project.main_group.new_file('Tests/MenuMaterialTestScene.swift')])
studio = project.path.dirname + 'StudioApp.swift'
source = studio.read
anchor = '.frame(width:frame.width,height:frame.height)'
raise 'Cannot locate the capture preview for the simulator scene' unless source.scan(anchor).size == 1
source = source.sub(anchor, <<~SWIFT)
  .overlay {
      if ProcessInfo.processInfo.arguments.contains("-menu-test-scene") {
          MenuMaterialTestScene().allowsHitTesting(false)
      }
  }
  #{anchor}
SWIFT
app.add_file_references([project.main_group.new_file('Tests/ZoomUITestDevice.swift')])
def inject_once(source, anchor, insert)
  raise "Cannot locate unique UI test injection: #{anchor}" unless source.scan(anchor).size == 1
  source.sub(anchor) { anchor + "\n" + insert }
end
source = inject_once(source, 'var ready = false, rail = false',
  '        private let zoomUITestDevice = ZoomUITestDevice()')
source = inject_once(source, 'guard ready,let web else { return }; let c = owner.camera',
  '            if zoomUITestDevice.enabled { zoomUITestDevice.publish(web,camera:c); return }')
source = inject_once(source, 'case "zoom":',
  '                if zoomUITestDevice.enabled, let web { zoomUITestDevice.accept(payload, in:web); return }')
source = inject_once(source, 'case "videoMode":',
  '                if zoomUITestDevice.testsVideoMode, let web { zoomUITestDevice.acceptVideoMode(payload, in:web); return }' + "\n")
zoom_preview = 'LiveCameraPreview(camera:camera, enabled:shooting, recipe:recipe)'
raise 'Missing filtered capture preview for UI test' unless source.scan(zoom_preview).size == 1
source = source.sub(zoom_preview, 'LiveCameraPreview(camera:camera, enabled:shooting, recipe:ProcessInfo.processInfo.arguments.contains("-zoom-ui-test") ? ZoomUITestDevice.previewRecipe : recipe)')
studio.write(source)
camera = project.path.dirname + 'Camera.swift'
camera_source = inject_once(camera.read,'func start() {', <<~SWIFT)
    if ProcessInfo.processInfo.arguments.contains("-zoom-ui-test") {
        lock.lock(); acceptingPreviewFrames = true; lock.unlock()
        ready = true
        return
    }
SWIFT
camera_source += <<~SWIFT
  extension Camera {
      func receiveZoomTestSample(_ sample: CMSampleBuffer) {
          frames.async {
              self.update(ZoomUITestDevice.previewRecipe)
              self.receiveVideoSample(sample,from:nil)
          }
      }
  }
SWIFT
camera.write(camera_source)
tests = project.new_target(:ui_test_bundle, 'MenuUITests', :ios, '16.0')
tests.add_dependency(app)
tests.add_file_references([project.main_group.new_file('Tests/MenuUITests.swift')])
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'TEST_TARGET_NAME' => app.name,
    'TARGETED_DEVICE_FAMILY' => '1',
    'PRODUCT_NAME' => 'MenuUITests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.flstudio.menu-ui-tests',
    'SWIFT_VERSION' => '5.0'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app, tests)
scheme.save_as(project.path, 'MenuUITests', true)
