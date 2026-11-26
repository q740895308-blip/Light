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
        XCTAssertEqual(grip.frame.midY, original.midY, accuracy: 1)
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

        for label in ["宽高比", "滤镜", "曝光", "计时器", "格式", "夜间模式", "闪光灯"] {
            XCTAssertTrue(grip.waitForExistence(timeout: 5))
            let matching = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label))
            let tile = try XCTUnwrap(matching.allElementsBoundByIndex.first { $0.frame.midY > grip.frame.midY }, label)
            if !tile.isEnabled && ["格式", "夜间模式", "闪光灯"].contains(label) {
                continue // The simulator has no camera hardware to advertise these options.
            }
            XCTAssertTrue(tile.isEnabled, label)
            tile.tap()
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
