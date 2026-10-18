import XCTest
@testable import WalkingPadCoreLogic

final class HeartRateZoneSettingsTests: XCTestCase {
    func testLegacyBoundsRemainManualAndMaximumIsOptional() {
        let settings = HeartRateZoneSettings.restored(nil, legacyBounds: [120, 140, 160, 180])
        XCTAssertEqual(settings.source, .manual)
        XCTAssertEqual(settings.effectiveUpperBounds, [120, 140, 160, 180])
        XCTAssertNil(settings.maximumHeartRate)
    }

    func testAppleThresholdsPreserveFractionalBoundaries() {
        let snapshot = snapshot([136.8, 147.6, 158.4, 169.2])
        XCTAssertEqual(snapshot.upperBounds, [136, 147, 158, 169])
        XCTAssertEqual(self.snapshot([120, 140, 160, 180]).upperBounds, [119, 139, 159, 179])
    }

    func testUnsupportedAppleConfigurationsAreRejected() {
        for thresholds in [[120, 140, 160], [120, 120, 160, 180], [120, 140, .nan, 180],
                           [120, 140, .infinity, 180], [70, 140, 160, 180], [120, 140, 160, 221]] {
            XCTAssertNil(snapshot(thresholds).upperBounds)
        }
    }

    func testCodableRoundTripAndManualRestoration() throws {
        var settings = HeartRateZoneSettings()
        settings.manualUpperBounds = [125, 145, 165, 185]
        settings.appleSnapshot = snapshot([120, 140, 160, 180])
        settings.source = .appleHealth
        settings.maximumHeartRate = 192
        let decoded = try JSONDecoder().decode(HeartRateZoneSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.effectiveUpperBounds, [119, 139, 159, 179])
        settings.source = .manual
        XCTAssertEqual(settings.effectiveUpperBounds, [125, 145, 165, 185])
    }

    func testNewProfileDoesNotInheritHealthOwnershipOrMaximum() {
        var original = HeartRateZoneSettings()
        original.source = .appleHealth
        original.appleSnapshot = snapshot([120, 140, 160, 180])
        original.maximumHeartRate = 192
        let copy = original.copiedForNewProfile()
        XCTAssertEqual(copy.source, .manual)
        XCTAssertNil(copy.appleSnapshot)
        XCTAssertNil(copy.maximumHeartRate)
        XCTAssertEqual(copy.effectiveUpperBounds, original.effectiveUpperBounds)
    }

    func testValidationRejectsOverlappingBoundsAndAllowsClearingMaximum() {
        XCTAssertFalse(HeartRateZoneSettings.validBounds([130, 120, 160, 180]))
        XCTAssertFalse(HeartRateZoneSettings.validBounds([79, 140, 160, 180]))
        XCTAssertTrue(HeartRateZoneSettings.validMaximum(nil))
        XCTAssertTrue(HeartRateZoneSettings.validMaximum(192))
        XCTAssertFalse(HeartRateZoneSettings.validMaximum(0))
        XCTAssertFalse(HeartRateZoneSettings.validMaximum(251))
    }

    func testInvalidCacheRestoresManualSource() {
        var settings = HeartRateZoneSettings()
        settings.source = .appleHealth
        settings.appleSnapshot = snapshot([120, 120, 160, 180])
        let restored = HeartRateZoneSettings.restored(settings, legacyBounds: [110, 130, 150, 170])
        XCTAssertEqual(restored.source, .manual)
        XCTAssertEqual(restored.effectiveUpperBounds, settings.manualUpperBounds)
    }

    private func snapshot(_ thresholds: [Double]) -> HeartRateZoneSettings.AppleSnapshot {
        .init(thresholds: thresholds, origin: "system", configuration: "automatic", fetchedAt: Date(timeIntervalSince1970: 100))
    }
}
