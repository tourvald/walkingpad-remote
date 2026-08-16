import Foundation
import TelemetrySoak

@main
enum TelemetrySoakCommand {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            print(usage)
            return
        }

        let minutes = try integerValue("--minutes", in: &arguments, default: 2)
        let heartRateMilliseconds = try integerValue(
            "--hr-ms",
            in: &arguments,
            default: 1_000
        )
        let treadmillMilliseconds = try integerValue(
            "--treadmill-ms",
            in: &arguments,
            default: 1_000
        )
        let burstEvery = try integerValue(
            "--burst-every-seconds",
            in: &arguments,
            default: 30
        )
        let burstNative = try integerValue(
            "--burst-native-records",
            in: &arguments,
            default: 32
        )
        let flushEvery = try integerValue(
            "--flush-every-seconds",
            in: &arguments,
            default: 5
        )
        let batchCount = try optionalIntegerValue(
            "--batch-count",
            in: &arguments
        )
        let candidateBatch = try optionalIntegerValue(
            "--compare-batch-count",
            in: &arguments
        )
        let instrumentationEnabled = !consume("--instrumentation-off", in: &arguments)
        guard arguments.isEmpty else {
            throw CommandError.unknownArguments(arguments)
        }
        guard (1...120).contains(minutes) else {
            throw CommandError.invalidRange("--minutes must be within 1...120")
        }
        guard heartRateMilliseconds > 0, treadmillMilliseconds > 0 else {
            throw CommandError.invalidRange("cadence values must be positive")
        }
        guard (0...512).contains(burstNative) else {
            throw CommandError.invalidRange(
                "--burst-native-records must be within 0...512"
            )
        }
        guard burstNative == 0 || burstEvery > 0 else {
            throw CommandError.invalidRange(
                "--burst-every-seconds must be positive when bursts are enabled"
            )
        }
        guard flushEvery > 0 else {
            throw CommandError.invalidRange("--flush-every-seconds must be positive")
        }
        guard batchCount.map({ $0 > 0 }) ?? true,
              candidateBatch.map({ $0 > 0 }) ?? true
        else {
            throw CommandError.invalidRange("batch counts must be positive")
        }

        let workload = TelemetrySoakWorkload(
            simulatedMinutes: minutes,
            heartRateCadenceMilliseconds: heartRateMilliseconds,
            treadmillCadenceMilliseconds: treadmillMilliseconds,
            burst: burstNative == 0
                ? nil
                : TelemetrySoakBurst(
                    everySeconds: burstEvery,
                    nativeRecordCount: burstNative
                ),
            flushEverySeconds: flushEvery
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let candidateBatch {
            guard batchCount == nil else {
                throw CommandError.conflictingArguments(
                    "--batch-count and --compare-batch-count"
                )
            }
            let baseline = TelemetrySoakRecorderConfiguration.provisionalDefault
            let candidate = TelemetrySoakRecorderConfiguration(
                name: "candidate-batch-\(candidateBatch)",
                bufferCapacity: baseline.bufferCapacity,
                criticalReserve: baseline.criticalReserve,
                nativeReserveFromBulk: baseline.nativeReserveFromBulk,
                batchRecordCount: candidateBatch,
                batchIntervalMilliseconds: baseline.batchIntervalMilliseconds,
                maximumPrecommitRetries: baseline.maximumPrecommitRetries,
                retryDelayMilliseconds: baseline.retryDelayMilliseconds
            )
            let comparison = try await TelemetrySoakRunner.compare(
                workload: workload,
                candidate: candidate,
                instrumentationEnabled: instrumentationEnabled
            )
            print(String(decoding: try encoder.encode(comparison), as: UTF8.self))
        } else {
            let recorderConfiguration: TelemetrySoakRecorderConfiguration
            if let batchCount {
                let baseline = TelemetrySoakRecorderConfiguration.provisionalDefault
                recorderConfiguration = TelemetrySoakRecorderConfiguration(
                    name: "candidate-batch-\(batchCount)",
                    bufferCapacity: baseline.bufferCapacity,
                    criticalReserve: baseline.criticalReserve,
                    nativeReserveFromBulk: baseline.nativeReserveFromBulk,
                    batchRecordCount: batchCount,
                    batchIntervalMilliseconds: baseline.batchIntervalMilliseconds,
                    maximumPrecommitRetries: baseline.maximumPrecommitRetries,
                    retryDelayMilliseconds: baseline.retryDelayMilliseconds
                )
            } else {
                recorderConfiguration = .provisionalDefault
            }
            let report = try await TelemetrySoakRunner.run(
                workload: workload,
                recorderConfiguration: recorderConfiguration,
                instrumentationEnabled: instrumentationEnabled
            )
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
    }

    private static func consume(_ name: String, in arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func integerValue(
        _ name: String,
        in arguments: inout [String],
        default defaultValue: Int
    ) throws -> Int {
        try optionalIntegerValue(name, in: &arguments) ?? defaultValue
    }

    private static func optionalIntegerValue(
        _ name: String,
        in arguments: inout [String]
    ) throws -> Int? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex,
              let value = Int(arguments[valueIndex])
        else {
            throw CommandError.invalidInteger(name)
        }
        arguments.removeSubrange(index...valueIndex)
        return value
    }

    private static let usage = """
    telemetry-soak [options]
      --minutes N                    Simulated duration (1...120)
      --hr-ms N                      Simulated HR delivery cadence
      --treadmill-ms N               Simulated treadmill cadence
      --burst-every-seconds N        Interval between bounded native bursts
      --burst-native-records N       Records per burst (0 disables bursts)
      --flush-every-seconds N        Deterministic explicit flush cadence
      --batch-count N                Run one injected batch-count candidate
      --compare-batch-count N        Run provisional defaults and one A/B candidate
      --instrumentation-off          Disable signposts for isolation comparison
    """
}

private enum CommandError: Error, CustomStringConvertible {
    case conflictingArguments(String)
    case invalidInteger(String)
    case invalidRange(String)
    case unknownArguments([String])

    var description: String {
        switch self {
        case let .conflictingArguments(arguments):
            "Conflicting arguments: \(arguments)"
        case let .invalidInteger(name): "Invalid integer for \(name)"
        case let .invalidRange(message): "Invalid value: \(message)"
        case let .unknownArguments(arguments):
            "Unknown arguments: \(arguments.joined(separator: " "))"
        }
    }
}
