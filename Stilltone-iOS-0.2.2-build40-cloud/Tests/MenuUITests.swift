import XCTest

final class MenuUITests: XCTestCase {
    func testZoomButtonsSendOrderedRequestsAndCenterOnIPhone14Pro() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier:"com.example.flstudio.camera")
        app.launchArguments = ["-zoom-ui-test"]
        app.launch()
        addTeardownBlock { [self] in
            if (testRun?.failureCount ?? 0) > 0 {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "Zoom geometry, pointer hits and native receipts"
                tree.lifetime = .keepAlways
                add(tree)
                let screen = XCTAttachment(screenshot: app.screenshot())
                screen.lifetime = .keepAlways
                add(screen)
            }
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
        let alert = app.buttons["好"].firstMatch
        if alert.waitForExistence(timeout:4) { alert.tap() }
        XCTAssertTrue(app.staticTexts["zoom receipt 0 20 1 1"].waitForExistence(timeout:15))
        XCTAssertEqual(app.frame.width,393,accuracy:1)
        func center(of step: String, request: Int) throws -> CGVector {
            let prefix = "zoom point \(request) \(step) "
            let point = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@",prefix)).firstMatch
            XCTAssertTrue(point.waitForExistence(timeout:5),prefix)
            let fields = point.label.dropFirst(prefix.count).split(separator:" ")
            XCTAssertEqual(fields.count,3,point.label)
            let x = try XCTUnwrap(Double(fields[0]))
            let y = try XCTUnwrap(Double(fields[1]))
            XCTAssertEqual(String(fields[2]),step,"The visible button center must hit its own control")
            return CGVector(dx:CGFloat(x),dy:CGFloat(y))
        }
        for (index, step) in ["0.5","1","2","3","2"].enumerated() {
            let target = try center(of:step,request:20+index)
            let coordinate = app.coordinate(withNormalizedOffset:target)
            let verifyDuringContact = step == "2" || step == "3"
            if verifyDuringContact { coordinate.press(forDuration:0.8) } else { coordinate.tap() }
            let receipt = "zoom receipt \(index+1) \(21+index) \(step) \(step)"
            XCTAssertTrue(app.staticTexts[receipt].waitForExistence(timeout:5),receipt)
            if verifyDuringContact {
                XCTAssertTrue(app.staticTexts["zoom acknowledged before release \(21+index)"].exists,
                              "The camera must receive \(step)× while the finger is still down")
            }
            let selected = try center(of:step,request:21+index)
            XCTAssertEqual(selected.dx * app.frame.width,app.frame.width/2,accuracy:1.5,step)
        }
    }

    // Read a narrow band between the grabber and the first row of icons.
    // The scene behind that part of the drawer contains alternating four-point stripes.
    private func stripeSample(in screenshot: XCUIScreenshot, area: CGRect, screenWidth: CGFloat) throws -> (red: Int, blue: Int, contrast: Int) {
        let image = screenshot.image
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / screenWidth
        let pixels = area.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = try XCTUnwrap(source.cropping(to: pixels))
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            bitmap.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let red = stride(from: 0, to: bytes.count, by: 4).map { Int(bytes[$0]) }
        let blue = stride(from: 2, to: bytes.count, by: 4).map { Int(bytes[$0]) }
        return (red.reduce(0,+)/red.count, blue.reduce(0,+)/blue.count,
                max(red.max()! - red.min()!, blue.max()! - blue.min()!))
    }

    func testLiveMenuMaterialOverChangingPreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.flstudio.camera")
        app.launchArguments = ["-menu-test-scene"]
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        let alert = app.buttons["好"].firstMatch
        if alert.waitForExistence(timeout: 5) { alert.tap() }
        let toggle = app.buttons["拍摄控制"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let original = app.screenshot()
        toggle.tap()
        let grip = app.buttons["收起拍摄菜单"].firstMatch
        XCTAssertTrue(grip.waitForExistence(timeout: 5))
        let width = app.frame.width
        let area = CGRect(x: width * 0.25, y: grip.frame.maxY + 3, width: 34, height: 3)
        let uncovered = try stripeSample(in: original, area: area, screenWidth: width)
        XCTAssertGreaterThan(uncovered.contrast, 100, "The simulated camera stripes must be visible at this position")
        var sawWarm = false, sawCool = false
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let sample = try? self.stripeSample(in: app.screenshot(), area: area, screenWidth: width) else { return false }
            print("UI material ROI \(area), original \(uncovered), current \(sample)")
            if sample.contrast < uncovered.contrast / 4 {
                sawWarm = sawWarm || sample.red > sample.blue + 3
                sawCool = sawCool || sample.blue > sample.red + 3
            }
            return sawWarm && sawCool
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 12), .completed,
                       "An open drawer must show a changed underlying scene with its detail still blurred")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Live blur over changing simulated viewfinder"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGripAndSubmenusOnIPhone14Pro() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.flstudio.camera")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.frame.width, 393, accuracy: 1)
        XCTAssertEqual(app.frame.height, 852, accuracy: 1)

        let toggle = app.buttons["拍摄控制"].firstMatch
        let cameraMessage = app.buttons["好"].firstMatch
        if cameraMessage.waitForExistence(timeout: 4) { cameraMessage.tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        toggle.tap()
        let grip = app.buttons["收起拍摄菜单"].firstMatch
        XCTAssertTrue(grip.waitForExistence(timeout: 5))
        let original = grip.frame
        func drag(_ distance: CGFloat) {
            let start = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.12, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 0.2)
        }
        drag(19)
        XCTAssertTrue(grip.exists, "A short drag must leave the sheet open")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            grip.exists && abs(grip.frame.midY - original.midY) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed,
                       "A short pull must spring back to the original handle position")
        func attach(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name
            image.lifetime = .keepAlways
            add(image)
        }
        attach("Six-dot menu after a short pull")
        drag(42)
        func waitForDismissal() {
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: grip)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        }
        waitForDismissal()
        XCTAssertTrue(toggle.isHittable, "The control button must respond again after the sheet closes")
        toggle.tap()

        // WKWebView exposes some tiles as toggles and some as buttons. Hit the
        // four enabled grid cells on the 14 Pro simulator through the real screen.
        // Format, night mode and flash require camera capabilities it lacks.
        let tiles: [(label: String, offset: CGVector)] = [
            ("宽高比", CGVector(dx: 113, dy: 63)),
            ("计时器", CGVector(dx: -113, dy: 192)),
            ("曝光", CGVector(dx: 0, dy: 192)),
            ("滤镜", CGVector(dx: -113, dy: 321))
        ]
        for (label, offset) in tiles {
            XCTAssertTrue(grip.waitForExistence(timeout: 5))
            let center = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.withOffset(offset).tap()
            let back = app.buttons["返回拍摄控制"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), label)
            if label == "滤镜" {
                for name in ["富士", "徕卡"] {
                    let brand = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
                    XCTAssertTrue(brand.waitForExistence(timeout: 5), name)
                    brand.tap()
                    let up = app.buttons["返回滤镜品牌"].firstMatch
                    XCTAssertTrue(up.waitForExistence(timeout: 5), name)
                    attach(name + "滤镜")
                    up.tap()
                    XCTAssertTrue(back.waitForExistence(timeout: 5))
                }
            }
            attach(label)
            back.tap()
            XCTAssertTrue(grip.waitForExistence(timeout: 5))
        }
        grip.tap()
        waitForDismissal()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
    }
}
