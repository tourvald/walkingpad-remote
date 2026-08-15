import Foundation
import TelemetryDomain
import TelemetryPersistence
import XCTest

final class TelemetryStoreRoundTripTests: XCTestCase {
    func testInsertFetchOrderAndFilterAllConceptualRecords() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let sharedConfiguration = TelemetryPersistenceFixtures.configuration(seed: 1)
        let later = TelemetryPersistenceFixtures.session(
            seed: 2,
            profile: "profile-b",
            configuration: sharedConfiguration,
            startedOffset: 100
        )
        let earlier = TelemetryPersistenceFixtures.session(
            seed: 1,
            profile: "profile-a",
            configuration: sharedConfiguration,
            startedOffset: 0
        )
        try await store.insertSession(later)
        try await store.insertSession(earlier)

        let unknownSource = TelemetryPersistenceFixtures.source(seed: 1, kind: .unknown)
        let treadmillSource = TelemetryPersistenceFixtures.source(seed: 2, kind: .treadmillProtocol)
        try await store.insertSource(
            treadmillSource,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate.addingTimeInterval(2)
        )
        try await store.insertSource(
            unknownSource,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate.addingTimeInterval(1)
        )

        let laterHR = TelemetryPersistenceFixtures.heartRate(
            seed: 1,
            session: earlier,
            source: unknownSource,
            arrivalOrder: 2,
            bpm: 122
        )
        let earlierHR = TelemetryPersistenceFixtures.heartRate(
            seed: 2,
            session: earlier,
            source: unknownSource,
            arrivalOrder: 1,
            bpm: 121
        )
        try await store.insertHeartRate(laterHR)
        try await store.insertHeartRate(earlierHR)

        let factualTreadmill = TelemetryPersistenceFixtures.treadmill(
            seed: 1,
            session: earlier,
            source: treadmillSource,
            arrivalOrder: 2,
            unit: .kilometresPerHour
        )
        let unknownTreadmill = TelemetryPersistenceFixtures.treadmill(
            seed: 2,
            session: earlier,
            source: treadmillSource,
            arrivalOrder: 1,
            unit: .unknown
        )
        try await store.insertTreadmill(factualTreadmill)
        try await store.insertTreadmill(unknownTreadmill)

        let laterEvent = TelemetryPersistenceFixtures.event(
            seed: 1,
            session: earlier,
            kind: .manualStop,
            elapsed: 3_000_000
        )
        let earlierEvent = TelemetryPersistenceFixtures.event(
            seed: 2,
            session: earlier,
            kind: .sessionLifecycle,
            elapsed: 1_000_000
        )
        try await store.insertEvent(laterEvent)
        try await store.insertEvent(earlierEvent)

        let frameThree = TelemetryPersistenceFixtures.frame(
            seed: 1,
            session: earlier,
            elapsedSecond: 3,
            heartRate: laterHR
        )
        let frameOne = TelemetryPersistenceFixtures.frame(
            seed: 2,
            session: earlier,
            elapsedSecond: 1,
            heartRate: earlierHR
        )
        try await store.insertFrame(frameThree)
        try await store.insertFrame(frameOne)

        let analysisV2 = TelemetryPersistenceFixtures.analysis(seed: 1, session: earlier, version: "v2")
        let analysisV1 = TelemetryPersistenceFixtures.analysis(seed: 2, session: earlier, version: "v1")
        try await store.insertAnalysis(analysisV2)
        try await store.insertAnalysis(analysisV1)

        let allSessions = try await store.fetchSessions()
        let profileSessions = try await store.fetchSessions(profileLocalIdentifier: "profile-b")
        XCTAssertEqual(allSessions.map(\.sessionID), [earlier.sessionID, later.sessionID])
        XCTAssertEqual(profileSessions, [later])

        let unknownSources = try await store.fetchSources(providerKindKey: "unknown")
        XCTAssertEqual(unknownSources.map(\.identity), [unknownSource])
        XCTAssertNil(unknownSources.first?.identity.knownDevice)

        let heartRates = try await store.fetchHeartRate(sessionID: earlier.sessionID)
        XCTAssertEqual(heartRates, [earlierHR, laterHR])
        let treadmill = try await store.fetchTreadmill(sessionID: earlier.sessionID)
        XCTAssertEqual(treadmill, [unknownTreadmill, factualTreadmill])
        XCTAssertNil(treadmill[0].factualSpeed)
        XCTAssertEqual(treadmill[1].factualSpeed?.value, 5.5)

        let allEvents = try await store.fetchEvents(sessionID: earlier.sessionID)
        let manualStopEvents = try await store.fetchEvents(sessionID: earlier.sessionID, kind: .manualStop)
        let frames = try await store.fetchFrames(sessionID: earlier.sessionID)
        let v1Analyses = try await store.fetchAnalyses(
            sessionID: earlier.sessionID,
            analyzerVersion: AnalyzerVersion(rawValue: "v1")
        )
        XCTAssertEqual(allEvents, [earlierEvent, laterEvent])
        XCTAssertEqual(
            manualStopEvents,
            [laterEvent]
        )
        XCTAssertEqual(frames, [frameOne, frameThree])
        XCTAssertEqual(v1Analyses, [analysisV1])

        let counts = try await store.counts()
        XCTAssertEqual(counts.configurations, 1)
        XCTAssertEqual(counts.sessions, 2)
        XCTAssertEqual(counts.sources, 2)
        XCTAssertEqual(counts.heartRateSamples, 2)
        XCTAssertEqual(counts.treadmillSamples, 2)
        XCTAssertEqual(counts.events, 2)
        XCTAssertEqual(counts.frames, 2)
        XCTAssertEqual(counts.analyses, 2)
    }

    func testStableIdentityRejectsDuplicateFrameAndSourceWithoutFuzzyMatching() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 3)
        let source = TelemetryPersistenceFixtures.source(seed: 3)
        try await store.insertSession(session)
        try await store.insertSource(
            source,
            firstSeen: TelemetryPersistenceFixtures.baseDate,
            lastSeen: TelemetryPersistenceFixtures.baseDate
        )

        let frame = TelemetryPersistenceFixtures.frame(seed: 3, session: session, elapsedSecond: 7)
        let sameCanonicalSecond = TelemetryPersistenceFixtures.frame(seed: 4, session: session, elapsedSecond: 7)
        let heartRate = TelemetryPersistenceFixtures.heartRate(
            seed: 3,
            session: session,
            source: source,
            arrivalOrder: 1,
            bpm: 120
        )
        try await store.insertFrame(frame)
        try await store.insertHeartRate(heartRate)

        await XCTAssertThrowsErrorAsync(try await store.insertFrame(sameCanonicalSecond)) { error in
            guard case TelemetryStoreError.duplicateStableIdentity = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await store.insertSource(
                source,
                firstSeen: TelemetryPersistenceFixtures.baseDate,
                lastSeen: TelemetryPersistenceFixtures.baseDate
            )
        ) { error in
            guard case TelemetryStoreError.duplicateStableIdentity = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await store.insertHeartRate(heartRate)) { error in
            guard case TelemetryStoreError.duplicateStableIdentity = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let frames = try await store.fetchFrames(sessionID: session.sessionID)
        let counts = try await store.counts()
        XCTAssertEqual(frames.map(\.canonicalElapsedSecond), [7])
        XCTAssertEqual(counts.heartRateSamples, 1)
    }

    func testSessionDeletionCascadesOwnedRecordsButPreservesSourceAndConfiguration() async throws {
        let store = try TelemetryStoreFactory.make(.inMemory)
        let session = TelemetryPersistenceFixtures.session(seed: 5)
        let source = TelemetryPersistenceFixtures.source(seed: 5)
        try await store.insertSession(session)
        try await store.insertSource(source, firstSeen: TelemetryPersistenceFixtures.baseDate, lastSeen: TelemetryPersistenceFixtures.baseDate)
        try await store.insertHeartRate(
            TelemetryPersistenceFixtures.heartRate(
                seed: 5,
                session: session,
                source: source,
                arrivalOrder: 1,
                bpm: 120
            )
        )
        try await store.insertTreadmill(
            TelemetryPersistenceFixtures.treadmill(
                seed: 5,
                session: session,
                source: source,
                arrivalOrder: 1,
                unit: .unknown
            )
        )
        try await store.insertEvent(
            TelemetryPersistenceFixtures.event(seed: 5, session: session, kind: .manualStop, elapsed: 2_000_000)
        )
        try await store.insertFrame(
            TelemetryPersistenceFixtures.frame(seed: 5, session: session, elapsedSecond: 2)
        )
        try await store.insertAnalysis(
            TelemetryPersistenceFixtures.analysis(seed: 5, session: session, version: "v1")
        )

        try await store.deleteSession(session.sessionID)
        let counts = try await store.counts()
        XCTAssertEqual(counts.sessions, 0)
        XCTAssertEqual(counts.heartRateSamples, 0)
        XCTAssertEqual(counts.treadmillSamples, 0)
        XCTAssertEqual(counts.events, 0)
        XCTAssertEqual(counts.frames, 0)
        XCTAssertEqual(counts.analyses, 0)
        XCTAssertEqual(counts.sources, 1)
        XCTAssertEqual(counts.configurations, 1)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
