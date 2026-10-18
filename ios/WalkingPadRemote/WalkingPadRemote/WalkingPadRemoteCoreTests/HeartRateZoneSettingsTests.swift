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
        XCTAssertEqual(copy.effectiveUpperBounds, original.manualUpperBounds)
        XCTAssertNotEqual(copy.effectiveUpperBounds, original.effectiveUpperBounds)
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

    func testLegacyDTOStillDecodesWithoutNestedZoneSettings() throws {
        let dto = try legacyDTO()
        XCTAssertEqual(dto.targetBpm, 132)
        XCTAssertEqual(dto.cooldownTargetBpm, 112)
        XCTAssertNil(dto.heartRateZones)
        let bounds = [dto.zone1Max!, dto.zone2Max!, dto.zone3Max!, dto.zone4Max!]
        XCTAssertEqual(HeartRateZoneSettings.restored(dto.heartRateZones, legacyBounds: bounds).effectiveUpperBounds,
                       [125, 145, 165, 185])
    }

    func testProfileCopyRemovesImportedValuesFromBothDTOFormats() throws {
        var dto = try legacyDTO()
        var zones = HeartRateZoneSettings()
        zones.manualUpperBounds = [125, 145, 165, 185]
        zones.source = .appleHealth
        zones.appleSnapshot = snapshot([120, 140, 160, 180])
        zones.maximumHeartRate = 192
        dto.heartRateZones = zones
        dto.zone1Max = 119
        dto.zone2Max = 139
        dto.zone3Max = 159
        dto.zone4Max = 179
        let copied = try JSONDecoder().decode(HRSettingsDTO.self,
            from: JSONEncoder().encode(dto.copiedForNewProfile()))
        XCTAssertEqual([copied.zone1Max, copied.zone2Max, copied.zone3Max, copied.zone4Max], [125, 145, 165, 185])
        XCTAssertEqual(copied.heartRateZones?.effectiveUpperBounds, [125, 145, 165, 185])
        XCTAssertEqual(copied.heartRateZones?.source, .manual)
        XCTAssertNil(copied.heartRateZones?.appleSnapshot)
        XCTAssertNil(copied.heartRateZones?.maximumHeartRate)
        XCTAssertEqual(copied.targetBpm, dto.targetBpm)
        XCTAssertEqual(dto.heartRateZones, zones)
    }

    func testReadCannotApplyAfterCancellationProfileChangeOrWorkoutOwnership() {
        let profile = UUID()
        let request = HeartRateZoneSettings.AppleReadRequest(profileID: profile)
        XCTAssertTrue(request.canApply(current: request, activeProfileID: profile, settingsEditable: true, taskCancelled: false))
        // Closing/backgrounding or starting a workout invalidates current ownership.
        XCTAssertFalse(request.canApply(current: nil, activeProfileID: profile, settingsEditable: true, taskCancelled: false))
        XCTAssertFalse(request.canApply(current: .init(profileID: profile), activeProfileID: profile, settingsEditable: true, taskCancelled: false))
        XCTAssertFalse(request.canApply(current: request, activeProfileID: UUID(), settingsEditable: true, taskCancelled: false))
        XCTAssertFalse(request.canApply(current: request, activeProfileID: profile, settingsEditable: false, taskCancelled: false))
        XCTAssertFalse(request.canApply(current: request, activeProfileID: profile, settingsEditable: true, taskCancelled: true))
    }

    func testAppleImportRejectsZoneFiveOutsideExistingTrainingEnvelope() {
        // Manual persistence supports 230, but hrZoneRanges currently truncates at
        // 220. Importing this would misrepresent Apple's zone 5 during training.
        XCTAssertTrue(HeartRateZoneSettings.validBounds([129, 154, 179, 224]))
        XCTAssertNil(snapshot([130, 155, 180, 225]).upperBounds)
        XCTAssertEqual(snapshot([130, 155, 180, 220]).upperBounds, [129, 154, 179, 219])
    }

    private func legacyDTO() throws -> HRSettingsDTO {
        let json = #"{"targetBpm":132,"durationMinutes":25,"adaptiveStepEnabled":true,"decisionIntervalSeconds":10,"speedStepKmh":0.5,"zone1Max":125,"zone2Max":145,"zone3Max":165,"zone4Max":185,"cooldownTargetBpm":112}"#
        return try JSONDecoder().decode(HRSettingsDTO.self, from: Data(json.utf8))
    }

    private func snapshot(_ thresholds: [Double]) -> HeartRateZoneSettings.AppleSnapshot {
        .init(thresholds: thresholds, origin: "system", configuration: "automatic", fetchedAt: Date(timeIntervalSince1970: 100))
    }
}
