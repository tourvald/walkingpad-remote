// Run in a standalone simulator UI-testing bundle against the installed preview app.
#if os(iOS)
import XCTest
import XCUIAutomation

final class ActiveWorkoutSimulatorUITests: XCTestCase {
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func launch(_ state: String, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--active-workout-preview=\(state)",
            "-UIPreferredContentSizeCategoryName",
            largestText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(element("active-workout-stop", in: app).waitForExistence(timeout: 20))
        return app
    }

    private func assertStopVisible(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let stop = element("active-workout-stop", in: app)
        XCTAssertTrue(stop.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44, file: file, line: line)
        XCTAssertTrue(app.frame.contains(stop.frame), file: file, line: line)
    }

    func testModesShareReadableTargetAndMetrics() {
        for state in ["active-in-zone", "interval-warmup", "active-intervals",
                      "interval-recovery", "interval-cooldown", "active-no-hr", "active-no-speed"] {
            let app = launch(state)
            let target = element("active-workout-target", in: app)
            let speed = element("active-workout-metric-speed", in: app)
            let elapsed = element("active-workout-metric-elapsed", in: app)
            XCTAssertTrue(target.exists, state)
            XCTAssertEqual(speed.label, "Скорость", state)
            XCTAssertEqual(elapsed.label, "Прошло", state)
            XCTAssertLessThanOrEqual(target.frame.maxY, speed.frame.minY, state)
            XCTAssertFalse(speed.frame.intersects(elapsed.frame), state)
            if state == "active-no-speed" { XCTAssertEqual(speed.value as? String, "—") }
            assertStopVisible(in: app)
            app.terminate()
        }
    }

    func testLongContentAndHourDurationAtLargestText() {
        let app = launch("active-long-content", largestText: true)
        defer { app.terminate() }
        XCTAssertTrue(element("active-workout-target", in: app).label.contains("восстановительного интервала"))
        for (id, value) in [("speed", "12.5 км/ч"), ("elapsed", "1:01:01")] {
            let metric = element("active-workout-metric-\(id)", in: app)
            for _ in 0..<15 {
                let stop = element("active-workout-stop", in: app)
                if metric.isHittable && metric.frame.maxY <= stop.frame.minY { break }
                // Keep the gesture above the pinned actions, even on compact screens.
                let bottom = stop.frame.minY - 16
                let top = app.frame.minY + 64
                let distance = min(bottom - top, max(44, metric.frame.maxY - bottom))
                let origin = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.midX, dy: bottom))
                origin.press(forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertEqual(metric.value as? String, value)
            XCTAssertTrue(metric.isHittable)
            XCTAssertLessThanOrEqual(metric.frame.maxY, element("active-workout-stop", in: app).frame.minY)
            assertStopVisible(in: app)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMetricSelectionRemainsAvailable() {
        let app = launch("active-in-zone")
        defer { app.terminate() }
        element("active-workout-metric-speed", in: app).press(forDuration: 1)
        let pulse = app.buttons["Пульс"]
        XCTAssertTrue(pulse.waitForExistence(timeout: 5))
        pulse.tap()
        XCTAssertTrue(element("active-workout-metric-heartRate", in: app).waitForExistence(timeout: 5))
        assertStopVisible(in: app)
    }

    func testLandscapeLargestTextKeepsStopVisible() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch("active-long-content", largestText: true)
        defer { app.terminate() }
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        assertStopVisible(in: app)
        let stop = element("active-workout-stop", in: app)
        let extend = app.buttons["Продлить тренировку на 5 минут"]
        XCTAssertTrue(extend.isHittable)
        XCTAssertTrue(app.frame.contains(extend.frame))
        XCTAssertLessThanOrEqual(stop.frame.maxX, extend.frame.minX)
        XCTAssertGreaterThan(stop.frame.minY - app.frame.minY, stop.frame.height)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
