import Foundation

enum StopTruthExperimentEvidenceEvent: String, Codable {
    case experimentStarted = "experiment_started"
    case commandEnqueued = "command_enqueued"
    case transportInvoked = "transport_invoked"
    case transportResult = "transport_result"
    case fe01Raw = "fe01_raw"
    case stopObservation = "stop_observation"
    case stopFinalResult = "stop_final_result"
    case postWindowFreshness = "post_window_freshness"
    case physicalMarker = "physical_marker"
    case abortBarrier = "abort_barrier"
    case rejectedAfterAbort = "rejected_after_abort"
    case timingInvalid = "timing_invalid"
    case conditionalRetryEvaluation = "conditional_retry_evaluation"
    case a6Bounds = "a6_bounds"
}

struct StopTruthExperimentEvidenceRecord: Codable, Equatable {
    let event: StopTruthExperimentEvidenceEvent
    let experimentID: UUID
    let caseID: String
    let repetition: Int
    let timestamp: StopTruthExperimentTimestamp
    let fields: [String: String]
}

protocol StopTruthExperimentEvidenceSink: AnyObject {
    func append(_ record: StopTruthExperimentEvidenceRecord)
}

final class StopTruthExperimentMemoryEvidenceSink: StopTruthExperimentEvidenceSink {
    private(set) var records: [StopTruthExperimentEvidenceRecord] = []
    func append(_ record: StopTruthExperimentEvidenceRecord) { records.append(record) }
}

final class StopTruthExperimentEvidenceWriter: StopTruthExperimentEvidenceSink {
    private let queue = DispatchQueue(label: "StopTruthExperimentEvidenceWriter")
    private let fileHandle: FileHandle
    let fileURL: URL

    init(experimentID: UUID, rootDirectory: URL) throws {
        let directory = rootDirectory.appendingPathComponent("TrainingLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("issue11_stop_truth_\(experimentID.uuidString).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileHandle = handle
    }

    deinit { try? fileHandle.close() }

    func append(_ record: StopTruthExperimentEvidenceRecord) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(record) else { return }
            fileHandle.write(data)
            fileHandle.write(Data([0x0A]))
            try? fileHandle.synchronize()
        }
    }
}
