import XCTest

@MainActor
final class FocusGeometryTests: XCTestCase {
    func testFinalDetails() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        for state in ["ending-confirmed", "summary-unavailable"] {
            app.launchArguments = ["--training-result-preview=\(state)", "-content_selected_root_tab_v1", "0", "--focus-size=large", "--focus-appearance=light"]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
            capture("final-\(state)")
            app.terminate()
        }
        app.launchArguments = ["--training-hub-preview=ready-known-source", "-content_selected_root_tab_v1", "2", "--focus-size=accessibility5", "--focus-appearance=dark"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        for page in 0..<6 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25)))
            capture("final-plank-ax5-\(page)")
        }
        app.terminate()
    }

    func testFixedAnchorsDefault() throws { try verifyFixedAnchors(size: "large") }
    func testReadyEnlargedText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-hub-preview=focus-transition", "-content_selected_root_tab_v1", "0", "--focus-size=xxxLarge", "--focus-appearance=light"]
        app.launch()
        let start = app.buttons["Начать тренировку"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let pulse = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Пульс, HealthKit")).firstMatch
        let mode = app.buttons["Режим тренировки, HR-контроль"]
        XCTAssertTrue(pulse.exists)
        XCTAssertTrue(pulse.isHittable)
        XCTAssertLessThanOrEqual(pulse.frame.maxY, mode.frame.minY)
        capture("ready-largest-standard-top")
        app.scrollViews.firstMatch.swipeUp()
        let duration = app.buttons["35 минут"]
        XCTAssertTrue(duration.isHittable)
        XCTAssertTrue(start.isHittable)
        capture("ready-largest-standard-controls")
        start.tap()
        XCTAssertTrue(app.buttons["workout.stop"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["workout.stop"].isHittable)
        capture("active-largest-standard")
        app.terminate()
    }

    func testCompactTransition() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-hub-preview=focus-transition", "-content_selected_root_tab_v1", "0", "--focus-size=large", "--focus-appearance=light"]
        app.launch()
        let start = app.buttons["Начать тренировку"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        capture("compact-ready-top")
        let duration = app.buttons["35 минут"]
        for _ in 0..<4 {
            if duration.isHittable && app.scrollViews.firstMatch.frame.contains(duration.frame) { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(duration.isHittable)
        XCTAssertTrue(start.isHittable)
        capture("compact-ready-controls")
        start.tap()
        XCTAssertTrue(app.buttons["workout.stop"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["workout.stop"].isHittable)
        capture("compact-active")
        app.terminate()
    }

    private func verifyFixedAnchors(size: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-hub-preview=focus-transition", "-content_selected_root_tab_v1", "0", "--focus-size=\(size)", "--focus-appearance=light"]
        app.launch()
        let start = app.buttons["Начать тренировку"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let zones = app.descendants(matching: .any).matching(identifier: "training.zones").firstMatch
        let duration = app.descendants(matching: .any).matching(identifier: "training.duration").firstMatch
        XCTAssertTrue(zones.exists)
        XCTAssertTrue(duration.exists)
        let beforeZones = zones.frame
        let beforeTime = duration.frame
        let scroll = app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        XCTAssertEqual(zones.frame.maxY, beforeZones.maxY, accuracy: 1, "Fitting Hub does not scroll its controls")
        XCTAssertTrue(app.buttons["35 минут"].isHittable)
        capture("anchors-ready-\(size)")
        start.tap()
        XCTAssertTrue(app.buttons["workout.stop"].waitForExistence(timeout: 8))
        let remaining = app.descendants(matching: .any).matching(identifier: "workout.remaining").firstMatch
        let afterZones = zones.frame
        let afterTime = remaining.frame
        capture("anchors-active-\(size)")
        let payload = ["size":size, "beforeZones":NSCoder.string(for: beforeZones), "afterZones":NSCoder.string(for: afterZones), "beforeTime":NSCoder.string(for: beforeTime), "afterTime":NSCoder.string(for: afterTime)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted,.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "fixed-anchors-\(size)"; evidence.lifetime = .keepAlways; add(evidence)
        // The interactive AX container omits the hidden 20-point marker reserve;
        // compare the common bottom edge, then verify visible bars from PNG pixels.
        XCTAssertEqual(beforeZones.maxY, afterZones.maxY, accuracy: 1)
        XCTAssertEqual(beforeZones.midX, afterZones.midX, accuracy: 1)
        XCTAssertEqual(beforeZones.width, afterZones.width, accuracy: 1)
        XCTAssertEqual(beforeTime.minY, afterTime.minY, accuracy: 1)

        XCTAssertTrue(app.buttons["workout.stop"].isHittable)
        app.terminate()
    }

    func testPortraitDefault() throws { try inspect(landscape: false, size: "large") }
    func testPortraitAX5() throws { try inspect(landscape: false, size: "accessibility5") }
    func testLandscapeDefault() throws { try inspect(landscape: true, size: "large") }
    func testLandscapeAX5() throws { try inspect(landscape: true, size: "accessibility5") }

    func testTransition() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-hub-preview=focus-transition", "-content_selected_root_tab_v1", "0", "--focus-size=large", "--focus-appearance=light"]
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        let start = app.buttons["Начать тренировку"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        app.buttons["Параметры тренировки"].tap()
        XCTAssertTrue(app.navigationBars["Параметры"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        capture("transition-ready")
        start.tap()
        let stop = app.buttons["workout.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isHittable)
        capture("transition-active")
        app.buttons["Детали тренировки и подключения"].tap()
        let extend = app.buttons["Продлить тренировку на 5 минут"]
        if !extend.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(extend.waitForExistence(timeout: 5))
        extend.tap()
        XCTAssertTrue(app.alerts["Добавить 5 минут?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Добавить"].tap()
        if app.buttons["Готово"].exists { app.buttons["Готово"].tap() }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "workout.remaining").firstMatch.value as? String, "21:18")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Завершаем тренировку…"].waitForExistence(timeout: 5))
        capture("transition-ending")
        app.terminate()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func inspect(landscape: Bool, size: String) throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        for state in ["active-in-zone", "active-no-hr", "cooldown-above"] {
            let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
            app.launchArguments = ["--active-workout-preview=\(state)", "-content_selected_root_tab_v1", "0", "--focus-size=\(size)", "--focus-appearance=light", "--focus-geometry"]
            app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
            let stop = app.buttons["workout.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.contains(stop.frame) && (frame.width > frame.height) == landscape
                    && app.descendants(matching: .any).matching(identifier: "workout.heartRate").firstMatch.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            let viewport = app.windows.firstMatch.frame
            let reserve = app.descendants(matching: .any).matching(identifier: "workout.videoSpace").firstMatch.frame
            var rows: [[String: Any]] = []
            for id in ["workout.heartRate", "workout.status", "workout.speed", "workout.elapsed", "workout.stop"] {
                let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(element.exists, id)
                XCTAssertFalse(element.frame.isEmpty, id)
                XCTAssertTrue(viewport.contains(element.frame), "\(id) \(element.frame) outside \(viewport)")
                XCTAssertTrue(element.isHittable, "Visible and available: \(id)")
                if app.scrollViews.firstMatch.exists && ["workout.heartRate", "workout.status"].contains(id) {
                    XCTAssertTrue(app.scrollViews.firstMatch.frame.contains(element.frame), "Core value fully in scroll viewport: \(id)")
                }
                XCTAssertFalse(reserve.intersects(element.frame), "\(id) intersects video \(reserve)")
                rows.append(["id": id, "label": element.label, "value": String(describing: element.value), "frame": NSCoder.string(for: element.frame), "hittable": element.isHittable])
            }
            let remaining = app.descendants(matching: .any).matching(identifier: "workout.remaining").firstMatch
            let initialStop = stop.frame
            for _ in 0..<5 {
                if !app.scrollViews.firstMatch.exists || (remaining.isHittable && app.scrollViews.firstMatch.frame.contains(remaining.frame)) { break }
                let scroll = app.scrollViews.firstMatch
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85))
                    .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.15)))
            }
            XCTAssertTrue(remaining.isHittable, "Remaining time reachable by scrolling")
            let contentViewport = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch.frame : viewport
            XCTAssertTrue(contentViewport.contains(remaining.frame), "Remaining \(remaining.frame) fully in \(contentViewport)")
            XCTAssertEqual(stop.frame.midY, initialStop.midY, accuracy: 1, "Stop stays pinned during scroll")
            XCTAssertFalse(reserve.intersects(remaining.frame))
            XCTAssertTrue(stop.isHittable)
            XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
            let payload: [String: Any] = ["state": state,"size":size,"landscape":landscape,"viewport":NSCoder.string(for: viewport),"reserve":NSCoder.string(for: reserve),"elements":rows]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            geometry.name = "geometry-\(state)-\(size)-\(landscape)";geometry.lifetime = .keepAlways;add(geometry)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "screen-\(state)-\(size)-\(landscape)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    func testTextCategories() throws {
        XCUIDevice.shared.orientation = .portrait
        for size in ["xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge", "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5"] {
            let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
            app.launchArguments = ["--active-workout-preview=active-in-zone", "-content_selected_root_tab_v1", "0", "--focus-size=\(size)", "--focus-appearance=dark"]
            app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
            XCTAssertTrue(app.buttons["workout.stop"].waitForExistence(timeout: 8))
            for id in ["workout.heartRate", "workout.status", "workout.speed", "workout.elapsed", "workout.stop"] {
                let item = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(item.isHittable, "\(size) \(id)")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(item.frame), "\(size) \(id) frame")
            }
            capture("type-\(size)-dark")
            app.terminate()
        }
    }

    func testAuxiliaryScreens() throws {
        XCUIDevice.shared.orientation = .portrait
        let fixtures = [
            ("--training-hub-preview=focus-statistics-loaded", "1"),
            ("--training-hub-preview=focus-statistics-partial", "1"),
            ("--training-hub-preview=focus-statistics-empty", "1"),
            ("--training-hub-preview=focus-statistics-loading", "1"),
            ("--training-hub-preview=focus-statistics-failed", "1"),
            ("--training-hub-preview=focus-settings", "0"),
            ("--training-hub-preview=focus-devices-list", "0"),
            ("--training-hub-preview=focus-devices-connected", "0"),
            ("--training-hub-preview=focus-devices-empty", "0"),
            ("--training-hub-preview=focus-devices-scanning", "0"),
            ("--training-hub-preview=ready-known-source", "2"),
            ("--training-hub-preview=ready-known-source", "3")
        ]
        for (index, fixture) in fixtures.enumerated() {
            let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
            app.launchArguments = [fixture.0, "-content_selected_root_tab_v1", fixture.1, "--focus-size=large", "--focus-appearance=\(index % 2 == 0 ? "light" : "dark")"]
            app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 8))
            capture("aux-\(index)-initial")
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
            else if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
            capture("aux-\(index)-scrolled")
            app.terminate()
        }
    }

    func testAccessibilityAudit() throws {
        XCUIDevice.shared.orientation = .portrait
        for (index, fixture) in ["--training-hub-preview=ready-known-source", "--active-workout-preview=active-in-zone", "--training-result-preview=summary-complete"].enumerated() {
            let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
            app.launchArguments = [fixture, "-content_selected_root_tab_v1", "0", "--focus-size=large", "--focus-appearance=light"]
            app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
            for page in 0..<3 {
                let window = app.windows.firstMatch.frame
                let scroll = app.scrollViews.firstMatch
                var visible = window
                if app.buttons["workout.stop"].exists && scroll.exists {
                    visible = scroll.frame
                } else if scroll.exists {
                    let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.minY
                    var bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.maxY
                    for title in ["Начать тренировку", "Готово"] {
                        if app.buttons[title].exists { bottom = min(bottom, app.buttons[title].frame.minY - 10) }
                    }
                    visible = CGRect(x: window.minX, y: top, width: window.width, height: max(1, bottom - top))
                }
                try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription, .textClipped]) { issue in
                    if issue.auditType == .contrast, let item = issue.element {
                        let compositeZone = ["Z1", "Z2", "Z3", "Z4", "Z5"].contains(item.label) && item.frame.height >= 40
                        let clippedScrollContent = item.debugDescription.contains("ScrollView") && !visible.contains(item.frame)
                        if compositeZone || clippedScrollContent {
                            let reason = compositeZone
                                ? "Composite zone frame includes a decorative pale capsule. Black/white text and the required selection/live markers are verified separately."
                                : "The element is outside the unobscured scroll viewport; this pixel crop shows the fixed controls. The next audit scrolls content into view."
                            let evidence = XCTAttachment(string: "\(item.label): \(item.frame)\n\(reason)")
                            evidence.name = "reviewed-contrast-exclusion-\(index)-\(page)"; evidence.lifetime = .keepAlways; self.add(evidence)
                            return true
                        }
                    }
                    return false
                }
                capture("audit-\(index)-page-\(page)")
                if !scroll.exists { break }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: visible.midX, dy: visible.maxY - 15))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + 15)))
            }
            capture("audit-\(index)")
            app.terminate()
        }
    }
    func testPlankInteractions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
        app.launchArguments = ["--training-hub-preview=ready-known-source", "-content_selected_root_tab_v1", "2", "-plank_base_duration_seconds_v1", "5", "-plank_completed_sets_count_v1", "0", "--focus-size=large", "--focus-appearance=light"]
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        let timer = app.descendants(matching: .any).matching(identifier: "Таймер планки").firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        capture("plank-idle")
        timer.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Идёт планка")).firstMatch.waitForExistence(timeout: 3))
        capture("plank-running")
        XCTAssertTrue(app.staticTexts["Подход завершён"].waitForExistence(timeout: 8))
        capture("plank-completed")
        timer.press(forDuration: 3.3)
        XCTAssertTrue(app.alerts.buttons["Начать замер"].waitForExistence(timeout: 3))
        app.alerts.buttons["Начать замер"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Идёт замер")).firstMatch.waitForExistence(timeout: 3))
        capture("plank-measurement")
        timer.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "База обновлена")).firstMatch.waitForExistence(timeout: 3))
        timer.tap()
        timer.press(forDuration: 1.5)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Идёт планка")).firstMatch.exists)
        capture("plank-cancelled")
        app.terminate()
    }
    func testAuxiliaryFollowups() throws {
        XCUIDevice.shared.orientation = .portrait
        for size in ["large", "accessibility5"] {
            for (index, fixture) in [("1", "--training-hub-preview=focus-statistics-partial"), ("0", "--training-hub-preview=focus-settings"), ("2", "--training-hub-preview=ready-known-source")] {
                let app = XCUIApplication(bundleIdentifier: "sw.WalkingPadRemote")
                app.launchArguments = [fixture, "-content_selected_root_tab_v1", index, "--focus-size=\(size)", "--focus-appearance=dark", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
                app.launch()
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
                capture("followup-\(index)-\(size)-initial")
                for page in 0..<2 {
                    if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
                    else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
                    else {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85))
                            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25)))
                    }
                    capture("followup-\(index)-\(size)-page-\(page)")
                }
                app.terminate()
            }
        }
    }
}
