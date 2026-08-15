import TelemetryDomain
@testable import TelemetryRecorder
import XCTest

final class BoundedTelemetryBufferTests: XCTestCase {
    func testExactFrameCoalescingMovesLatestCandidateToGlobalSequenceTail() throws {
        let session = TelemetryRecorderFixtures.session()
        var buffer = BoundedTelemetryBuffer(
            policy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 6,
                    reservedCriticalCapacity: 2,
                    reservedNativeCapacity: 2
                )
            )
        )

        XCTAssertEqual(
            buffer.enqueue(sequenced(1, TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: 1)), at: .zero)
                .disposition,
            .enqueued
        )
        XCTAssertEqual(
            buffer.enqueue(sequenced(2, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 2)), at: .zero)
                .disposition,
            .enqueued
        )
        XCTAssertEqual(
            buffer.enqueue(sequenced(3, TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: 1)), at: .zero)
                .disposition,
            .coalescedFrame
        )

        XCTAssertEqual(buffer.drain(maximumCount: 10).map(\.recorderSequence), [2, 3])
    }

    func testCriticalAdmissionEvictsBulkWithoutReorderingSurvivors() throws {
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        var buffer = BoundedTelemetryBuffer(
            policy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 6,
                    reservedCriticalCapacity: 2,
                    reservedNativeCapacity: 2
                )
            )
        )
        _ = buffer.enqueue(sequenced(1, TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: 1)), at: .zero)
        _ = buffer.enqueue(sequenced(2, TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: 2)), at: .zero)
        _ = buffer.enqueue(sequenced(3, TelemetryRecorderFixtures.heartRate(sessionID: session.sessionID, source: source, order: 3)), at: .zero)
        _ = buffer.enqueue(sequenced(4, TelemetryRecorderFixtures.heartRate(sessionID: session.sessionID, source: source, order: 4)), at: .zero)
        _ = buffer.enqueue(sequenced(5, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 5)), at: .zero)
        _ = buffer.enqueue(sequenced(6, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 6)), at: .zero)

        let result = buffer.enqueue(
            sequenced(7, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 7)),
            at: .zero
        )

        XCTAssertTrue(result.evictedBulkFrame)
        XCTAssertEqual(
            buffer.drain(maximumCount: 10).map(\.recorderSequence),
            [2, 3, 4, 5, 6, 7]
        )
    }

    func testNativeReservePreventsFramesFromConsumingNonCriticalCapacity() throws {
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        var buffer = BoundedTelemetryBuffer(
            policy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 8,
                    reservedCriticalCapacity: 2,
                    reservedNativeCapacity: 3
                )
            )
        )

        for second in 0..<3 {
            XCTAssertEqual(
                buffer.enqueue(
                    sequenced(
                        UInt64(second + 1),
                        TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: Int64(second))
                    ),
                    at: .zero
                ).disposition,
                .enqueued
            )
        }
        XCTAssertEqual(
            buffer.enqueue(
                sequenced(
                    4,
                    TelemetryRecorderFixtures.frame(sessionID: session.sessionID, second: 4)
                ),
                at: .zero
            )
                .disposition,
            .droppedFrame
        )
        for order in 5...7 {
            XCTAssertEqual(
                buffer.enqueue(
                    sequenced(
                        UInt64(order),
                        TelemetryRecorderFixtures.heartRate(
                            sessionID: session.sessionID,
                            source: source,
                            order: UInt64(order),
                            bpm: 120
                        )
                    ),
                    at: .zero
                ).disposition,
                .enqueued
            )
        }

        XCTAssertEqual(buffer.bulkFrameCount, 3)
        XCTAssertEqual(buffer.nativeCount, 3)
        XCTAssertEqual(buffer.count, 6)
    }

    func testNativeRecordsAreNeverFuzzilyCoalesced() throws {
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        var buffer = BoundedTelemetryBuffer(
            policy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 4,
                    reservedCriticalCapacity: 1,
                    reservedNativeCapacity: 1
                )
            )
        )

        _ = buffer.enqueue(
            sequenced(1, TelemetryRecorderFixtures.heartRate(sessionID: session.sessionID, source: source, order: 1, bpm: 120)),
            at: .zero
        )
        _ = buffer.enqueue(
            sequenced(2, TelemetryRecorderFixtures.heartRate(sessionID: session.sessionID, source: source, order: 1, bpm: 120)),
            at: .zero
        )

        XCTAssertEqual(buffer.nativeCount, 2)
        XCTAssertEqual(buffer.drain(maximumCount: 4).map(\.recorderSequence), [1, 2])
    }

    func testCatastrophicFullBufferWithoutBulkAccountsIncomingCriticalLoss() throws {
        let session = TelemetryRecorderFixtures.session()
        let source = TelemetryRecorderFixtures.source()
        var buffer = BoundedTelemetryBuffer(
            policy: try XCTUnwrap(
                TelemetryBufferPolicy(
                    capacity: 3,
                    reservedCriticalCapacity: 1,
                    reservedNativeCapacity: 1
                )
            )
        )
        _ = buffer.enqueue(sequenced(1, TelemetryRecorderFixtures.heartRate(sessionID: session.sessionID, source: source, order: 1)), at: .zero)
        _ = buffer.enqueue(sequenced(2, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 2)), at: .zero)
        _ = buffer.enqueue(sequenced(3, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 3)), at: .zero)

        XCTAssertEqual(
            buffer.enqueue(sequenced(4, TelemetryRecorderFixtures.event(sessionID: session.sessionID, order: 4)), at: .zero)
                .disposition,
            .lostCritical
        )
        XCTAssertEqual(buffer.count, 3)
    }

    private func sequenced(
        _ sequence: UInt64,
        _ record: TelemetryPersistenceRecord
    ) -> SequencedTelemetryRecord {
        SequencedTelemetryRecord(recorderSequence: sequence, record: record)
    }
}
