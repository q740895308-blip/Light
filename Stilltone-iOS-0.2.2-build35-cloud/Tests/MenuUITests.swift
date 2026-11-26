import XCTest

final class MenuUITests: XCTestCase {
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
