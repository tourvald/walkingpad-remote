import Foundation
import XCTest

final class StatisticsReadOwnershipTests: XCTestCase {
    func testActualManagerReadCancellationSupersessionRetentionAndFailures() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("WalkingPadRemote/BluetoothManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    @MainActor\n    func refreshWorkoutStatisticsFromV2("))
        let end = try XCTUnwrap(source.range(of: "    func prepareTelemetryV2Export(", range: start.upperBound..<source.endIndex))
        let method = String(source[start.lowerBound..<end.lowerBound])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = directory.appendingPathComponent("Ownership.swift")
        let executable = directory.appendingPathComponent("Ownership")
        // Compile the actual orchestration method against a controllable async reader.
        // This avoids production wrappers or a second implementation of its ownership rules.
        let program = #"""
        import Foundation

        struct WorkoutStatisticsProjection {
            let value: Int
            let isPartial: Bool
        }
        enum WorkoutReadState: Equatable {
            case loading, loaded, failed(String)
        }
        @MainActor final class Reader {
            var held = false
            var fail = false
            var partial = false
            var started = 0
            var active = 0
            var cancelled = 0
            func fetchWorkoutStatistics(filter: DateInterval, batchSize: Int) async throws -> WorkoutStatisticsProjection {
                started += 1
                active += 1
                defer { active -= 1 }
                do {
                    while held {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                    try Task.checkCancellation()
                } catch {
                    cancelled += 1
                    throw error
                }
                if fail { throw NSError(domain: "genuine-read-failure", code: 1) }
                return WorkoutStatisticsProjection(value: Int(filter.start.timeIntervalSince1970), isPartial: partial)
            }
        }
        @MainActor final class Manager {
            var activeUserProfileID: UUID? = UUID()
            var telemetryV2ProjectionGeneration: UInt = 0
            var telemetryV2Statistics: [String: WorkoutStatisticsProjection] = [:]
            var telemetryV2StatisticsState: [String: WorkoutReadState] = [:]
            let telemetryV2Coordinator = Reader()
            var errors = 0
            func appendLog(_ text: String) { errors += 1 }
            func activeWorkoutReadFilter(startedAtOrAfter: Date?, startedBefore: Date?) -> DateInterval? {
                guard activeUserProfileID != nil, let start = startedAtOrAfter, let end = startedBefore else { return nil }
                return DateInterval(start: start, end: end)
            }
            func workoutStatisticsKey(for interval: DateInterval) -> String {
                "\(activeUserProfileID!.uuidString)|\(interval.start.timeIntervalSince1970)|\(interval.end.timeIntervalSince1970)"
            }
        \#(method)
        }
        @main struct Verification {
            @MainActor static func main() async {
                func period(_ index: Int) -> DateInterval {
                    DateInterval(start: Date(timeIntervalSince1970: Double(index * 100)), duration: 60)
                }
                let manager = Manager()
                let reader = manager.telemetryV2Coordinator
                let week = period(1), month = period(2)
                reader.held = true
                let first = Task { @MainActor in
                    await manager.refreshWorkoutStatisticsFromV2(for: week, retaining: [week, month])
                }
                while reader.started == 0 { await Task.yield() }
                precondition(manager.telemetryV2StatisticsState[manager.workoutStatisticsKey(for: week)] == .loading)
                first.cancel()
                await first.value
                precondition(reader.active == 0 && reader.cancelled == 1)
                precondition(manager.telemetryV2Statistics.isEmpty && manager.errors == 0)

                // Supersede an old period while its underlying read is suspended.
                let old = Task { @MainActor in
                    await manager.refreshWorkoutStatisticsFromV2(for: week, retaining: [week, month])
                }
                while reader.started < 2 { await Task.yield() }
                let next = period(3)
                let fresh = Task { @MainActor in
                    await manager.refreshWorkoutStatisticsFromV2(for: next, retaining: [next, month])
                }
                while reader.started < 3 { await Task.yield() }
                old.cancel()
                await old.value
                reader.held = false
                await fresh.value
                precondition(manager.telemetryV2Statistics[manager.workoutStatisticsKey(for: week)] == nil)
                precondition(manager.telemetryV2Statistics[manager.workoutStatisticsKey(for: next)]?.value == 300)
                precondition(reader.active == 0 && reader.cancelled == 2)

                // Navigate many periods and profiles; only current week/month survive.
                for index in 4..<204 {
                    if index.isMultiple(of: 5) { manager.activeUserProfileID = UUID() }
                    let week = period(index), month = period(index + 1)
                    await manager.refreshWorkoutStatisticsFromV2(for: week, retaining: [week, month])
                    await manager.refreshWorkoutStatisticsFromV2(for: month, retaining: [week, month])
                    let keys = Set([week, month].map { manager.workoutStatisticsKey(for: $0) })
                    precondition(Set(manager.telemetryV2Statistics.keys) == keys)
                    precondition(Set(manager.telemetryV2StatisticsState.keys) == keys)
                }

                // The awaited reader's exact partial result and genuine failure are preserved.
                let current = period(204), other = period(205)
                reader.partial = true
                await manager.refreshWorkoutStatisticsFromV2(for: current, retaining: [current, other])
                let key = manager.workoutStatisticsKey(for: current)
                precondition(manager.telemetryV2Statistics[key]?.isPartial == true)
                reader.fail = true
                await manager.refreshWorkoutStatisticsFromV2(for: current, retaining: [current, other])
                guard case .failed? = manager.telemetryV2StatisticsState[key] else { fatalError("Missing genuine failure") }
                precondition(manager.errors == 1 && manager.telemetryV2Statistics[key]?.isPartial == true)
                reader.fail = false

                // Even a non-cooperative result cannot publish across a profile/generation change.
                reader.held = true
                let before = reader.started
                let stale = Task { @MainActor in
                    await manager.refreshWorkoutStatisticsFromV2(for: other, retaining: [current, other])
                }
                while reader.started == before { await Task.yield() }
                manager.telemetryV2ProjectionGeneration += 1
                manager.activeUserProfileID = UUID()
                reader.held = false
                await stale.value
                precondition(manager.telemetryV2Statistics.count == 1 && manager.errors == 1)
                print("Ownership verified: 2 cancelled reads stop; 200 periods/40 profile changes retain at most 2 entries; active partial/failure unchanged")
            }
        }
        """#
        try program.write(to: harness, atomically: true, encoding: .utf8)
        let output = try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-parse-as-library", harness.path, "-o", executable.path])
        XCTAssertFalse(output.contains("error:"))
        let result = try run(executable.path, [])
        XCTAssertTrue(result.contains("Ownership verified:"), result)
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, result)
        guard process.terminationStatus == 0 else { throw NSError(domain: "ownership-harness", code: Int(process.terminationStatus)) }
        return result
    }
}
