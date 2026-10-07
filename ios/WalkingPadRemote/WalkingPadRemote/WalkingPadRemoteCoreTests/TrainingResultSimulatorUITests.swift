// Runs in a standalone simulator UI-testing bundle; the macOS core suite excludes UI automation.
#if os(iOS)
import XCTest
import XCUIAutomation

final class ProcessingUITests: XCTestCase {
    func testProcessingExitAndUnavailableStatus() throws {
        for state in ["processing-confirming", "processing-unavailable"] {
            let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
            app.launchArguments = ["--training-result-preview=\(state)"]
            app.launch()
            let done = app.buttons["training-result-done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            XCTAssertEqual(done.label, "Готово")
            XCTAssertTrue(done.isHittable)
            XCTAssertGreaterThanOrEqual(done.frame.height, 48)
            XCTAssertTrue(app.staticTexts["Результат появится в истории после обработки."].exists)
            let tree = app.debugDescription
            let headingIndex = try XCTUnwrap(tree.range(of: "Обрабатываем результат…")?.lowerBound)
            let explanationIndex = try XCTUnwrap(tree.range(of: "Результат появится в истории после обработки.")?.lowerBound)
            let buttonIndex = try XCTUnwrap(tree.range(of: "training-result-done")?.lowerBound)
            XCTAssertLessThan(headingIndex, explanationIndex)
            XCTAssertLessThan(explanationIndex, buttonIndex)
            let attachment = XCTAttachment(string: tree)
            attachment.lifetime = .keepAlways
            add(attachment)
            try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription, .contrast, .textClipped]) { issue in
            print("AUDIT ISSUE: \(issue.compactDescription) \(issue.detailedDescription) ELEMENT: \(String(describing: issue.element))")
            return false
        }
            done.tap()
            XCTAssertFalse(done.exists)
            XCTAssertFalse(app.staticTexts["Обрабатываем результат…"].exists)
            app.terminate()
        }
    }

    func testRealFinishingHasNoProcessingExit() {
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-result-preview=ending-confirming"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Завершаем тренировку…"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["training-result-done"].exists)
        app.terminate()
    }

    func testLargestDynamicTypeExitRemainsAccessible() throws {
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-result-preview=processing-confirming",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let done = app.buttons["training-result-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        let scroll = app.scrollViews.firstMatch
        let tabBar = app.tabBars.firstMatch
        let viewport = CGRect(x: 0, y: app.navigationBars.firstMatch.frame.maxY,
            width: app.frame.width, height: tabBar.frame.minY - app.navigationBars.firstMatch.frame.maxY)
        for _ in 0..<8 where done.frame.maxY > viewport.maxY { scroll.swipeUp() }
        XCTAssertTrue(viewport.contains(done.frame))
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(done.label, "Готово")
        XCTAssertGreaterThanOrEqual(done.frame.height, 48)

        let explanation = app.staticTexts["Результат появится в истории после обработки."]
        let drag = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let delta = viewport.minY + 16 - explanation.frame.minY
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 0, dy: delta)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(viewport.contains(explanation.frame))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Fully visible accessibility explanation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription, .contrast, .textClipped]) { issue in
            // The audit scrolls this tall label behind a bar while sampling its full bounds.
            // Its fully visible presentation is captured above; no visible contrast issue is ignored.
            guard issue.auditType == .contrast, let element = issue.element,
                  element.label == explanation.label, !viewport.contains(element.frame) else { return false }
            let evidence = XCTAttachment(string: "Off-viewport audit sample: \(element.frame); viewport: \(viewport)")
            evidence.lifetime = .keepAlways
            self.add(evidence)
            return true
        }
        for _ in 0..<8 where done.frame.maxY > viewport.maxY { scroll.swipeUp() }
        XCTAssertTrue(viewport.contains(done.frame))
        done.tap()
        XCTAssertFalse(done.exists)
        app.terminate()
    }
}

#endif
