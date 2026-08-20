import Foundation
import TelemetryDomain

private struct LegacyHistoryAggregateState: Codable, Hashable, Sendable {
    var occurrencesByCanonicalDigest: [String: Int] = [:]
}

private enum LegacySourceRunOutcome {
    case completed(importedRecords: Int)
    case skipped
    case paused(importedRecords: Int)
    case failed
}

public struct LegacyTelemetryMigrator: Sendable {
    public static let importerVersion = "legacy-to-v2-importer-v1"
    private static let maximumHistoryRepresentationBytes = 8 * 1_024 * 1_024
    private static let maximumHistoryEntryCount = 10_000

    private let store: TelemetryStore
    private let shouldPauseAfterCommittedBatch: @Sendable (Int) -> Bool

    public init(store: TelemetryStore) {
        self.init(store: store, shouldPauseAfterCommittedBatch: { _ in false })
    }

    init(
        store: TelemetryStore,
        shouldPauseAfterCommittedBatch: @escaping @Sendable (Int) -> Bool
    ) {
        self.store = store
        self.shouldPauseAfterCommittedBatch = shouldPauseAfterCommittedBatch
    }

    public func run(
        _ request: LegacyTelemetryMigrationRequest
    ) async -> LegacyTelemetryMigrationReport {
        let batchSize = min(512, max(1, request.maximumRecordsPerBatch))
        var completedSources = 0
        var skippedSources = 0
        var failedSources = 0
        var importedRecords = 0
        var wasPaused = false

        for source in request.jsonlSources.sorted(by: {
            $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path
        }) {
            let outcome = await runJSONLSource(
                source,
                knownProfiles: request.knownProfileLocalIdentifiers,
                batchSize: batchSize
            )
            switch outcome {
            case let .completed(count):
                completedSources += 1
                importedRecords += count
            case .skipped:
                skippedSources += 1
            case let .paused(count):
                importedRecords += count
                wasPaused = true
            case .failed:
                failedSources += 1
            }
            if wasPaused { break }
        }

        if !wasPaused {
            for source in request.workoutHistorySources.sorted(by: {
                $0.storageKey < $1.storageKey
            }) {
                let outcome = await runHistorySource(
                    source,
                    knownProfiles: request.knownProfileLocalIdentifiers,
                    batchSize: batchSize
                )
                switch outcome {
                case let .completed(count):
                    completedSources += 1
                    importedRecords += count
                case .skipped:
                    skippedSources += 1
                case let .paused(count):
                    importedRecords += count
                    wasPaused = true
                case .failed:
                    failedSources += 1
                }
                if wasPaused { break }
            }
        }

        let importedWorkoutCount: Int
        if wasPaused {
            importedWorkoutCount = 0
        } else {
            do {
                importedWorkoutCount = try await store.reconcileLegacyWorkoutCandidates()
            } catch {
                importedWorkoutCount = 0
                failedSources = max(1, failedSources)
                try? await store.failLegacyReconciliation(
                    detail: boundedErrorDetail(error),
                    now: Date()
                )
            }
        }
        let completion: LegacyTelemetryMigrationCompletion
        if failedSources > 0, completedSources == 0, skippedSources == 0 {
            completion = .failed
        } else if failedSources > 0 || wasPaused {
            completion = .partial
        } else {
            completion = .completed
        }
        return LegacyTelemetryMigrationReport(
            completion: completion,
            completedSourceCount: completedSources,
            skippedSourceCount: skippedSources,
            failedSourceCount: failedSources,
            importedRecordCount: importedRecords,
            importedWorkoutCount: importedWorkoutCount
        )
    }

    private func runJSONLSource(
        _ descriptor: LegacyJSONLSourceDescriptor,
        knownProfiles: Set<String>,
        batchSize: Int
    ) async -> LegacySourceRunOutcome {
        var sourceID: String?
        var committedBatchCount = 0
        do {
            let digest = try LegacyMigrationHashing.fileSHA256(descriptor.url)
            let definition = LegacyMigrationSourceDefinition(
                sourceID: LegacyMigrationHashing.deterministicIdentifier(
                    "legacy-source:jsonl:\(digest)"
                ),
                kind: .jsonl,
                contentHashDigest: digest,
                locator: descriptor.url.standardizedFileURL.path,
                exactProfileLocalIdentifier:
                    descriptor.deterministicFallbackProfileLocalIdentifier
            )
            sourceID = definition.sourceID
            let emptyAggregate = try TelemetryStore.encode(LegacyJSONLAggregateState())
            let progress = try await store.beginLegacyMigrationSource(
                definition,
                importerVersion: Self.importerVersion,
                emptyAggregateStatePayload: emptyAggregate,
                now: Date()
            )
            if progress.snapshot.status == .completed {
                return .skipped
            }
            var aggregate = try TelemetryStore.decode(
                LegacyJSONLAggregateState.self,
                from: progress.aggregateStatePayload
            )
            let candidateID = LegacyMigrationHashing.deterministicIdentifier(
                "jsonl-candidate:\(definition.sourceID)"
            )
            let reader = try LegacyJSONLLineReader(
                url: descriptor.url,
                startingAt: progress.snapshot.checkpointByteOffset,
                nextRecordIndex: progress.snapshot.checkpointRecordIndex
            )
            var records: [LegacyImportedRecordDraft] = []
            var batchElementCount = 0
            var parsedRecordCount = progress.snapshot.parsedRecordCount
            var malformedRecordCount = progress.snapshot.malformedRecordCount
            var warningCount = progress.snapshot.warningCount
            var lastOffset = progress.snapshot.checkpointByteOffset
            var lastRecordIndex = progress.snapshot.checkpointRecordIndex
            var insertedRecords = 0

            while let element = try reader.next() {
                lastOffset = element.endOffset
                lastRecordIndex = element.recordIndex
                parsedRecordCount += 1
                batchElementCount += 1
                if let structuralWarning = element.structuralWarning {
                    malformedRecordCount += 1
                    warningCount += 1
                    aggregate.recordMalformed(structuralWarning)
                } else if let data = element.data {
                    do {
                        let parsed = try LegacyTelemetryMigrationParser.parseJSONL(
                            data,
                            sourceID: definition.sourceID,
                            candidateID: candidateID,
                            element: element,
                            knownProfiles: knownProfiles,
                            deterministicFallbackProfile:
                                descriptor.deterministicFallbackProfileLocalIdentifier
                        )
                        records.append(parsed.draft)
                        warningCount += Int64(parsed.draft.payload.warnings.count)
                        aggregate.observe(parsed.draft)
                    } catch {
                        malformedRecordCount += 1
                        warningCount += 1
                        aggregate.recordMalformed("malformed-jsonl-record")
                    }
                }

                if batchElementCount >= batchSize {
                    insertedRecords += try await store.commitLegacyMigrationBatch(
                        sourceID: definition.sourceID,
                        records: records,
                        candidates: [],
                        checkpointByteOffset: lastOffset,
                        checkpointRecordIndex: lastRecordIndex,
                        parsedRecordCount: parsedRecordCount,
                        malformedRecordCount: malformedRecordCount,
                        warningCount: warningCount,
                        aggregateStatePayload: try TelemetryStore.encode(aggregate),
                        completing: false,
                        now: Date()
                    )
                    records.removeAll(keepingCapacity: true)
                    batchElementCount = 0
                    committedBatchCount += 1
                    if shouldPauseAfterCommittedBatch(committedBatchCount) {
                        try await store.pauseLegacyMigrationSource(
                            sourceID: definition.sourceID,
                            now: Date()
                        )
                        return .paused(importedRecords: insertedRecords)
                    }
                }
            }

            let candidate = aggregate.candidate(
                sourceID: definition.sourceID,
                candidateID: candidateID,
                deterministicFallbackProfile:
                    descriptor.deterministicFallbackProfileLocalIdentifier
            )
            insertedRecords += try await store.commitLegacyMigrationBatch(
                sourceID: definition.sourceID,
                records: records,
                candidates: [candidate],
                checkpointByteOffset: lastOffset,
                checkpointRecordIndex: lastRecordIndex,
                parsedRecordCount: parsedRecordCount,
                malformedRecordCount: malformedRecordCount,
                warningCount: warningCount,
                aggregateStatePayload: try TelemetryStore.encode(aggregate),
                completing: true,
                now: Date()
            )
            committedBatchCount += 1
            return .completed(importedRecords: insertedRecords)
        } catch {
            if let sourceID {
                try? await store.failLegacyMigrationSource(
                    sourceID: sourceID,
                    code: "jsonl-source-failed",
                    detail: boundedErrorDetail(error),
                    now: Date()
                )
            }
            return .failed
        }
    }

    private func runHistorySource(
        _ descriptor: LegacyWorkoutHistorySourceDescriptor,
        knownProfiles: Set<String>,
        batchSize: Int
    ) async -> LegacySourceRunOutcome {
        var sourceID: String?
        var committedBatchCount = 0
        do {
            let exactProfile = descriptor.exactProfileLocalIdentifier.flatMap {
                knownProfiles.contains($0) ? $0 : nil
            }
            let digest = LegacyMigrationHashing.dataSHA256(descriptor.representation)
            let sourceScopeKey = "history:\(exactProfile ?? "unassigned")"
            let definition = LegacyMigrationSourceDefinition(
                sourceID: LegacyMigrationHashing.deterministicIdentifier(
                    "legacy-source:\(sourceScopeKey):\(digest)"
                ),
                kind: .workoutHistory,
                contentHashDigest: digest,
                locator: descriptor.storageKey,
                exactProfileLocalIdentifier: exactProfile
            )
            sourceID = definition.sourceID
            let emptyAggregate = try TelemetryStore.encode(LegacyHistoryAggregateState())
            let progress = try await store.beginLegacyMigrationSource(
                definition,
                importerVersion: Self.importerVersion,
                emptyAggregateStatePayload: emptyAggregate,
                now: Date()
            )
            if progress.snapshot.status == .completed {
                return .skipped
            }
            guard descriptor.representation.count <= Self.maximumHistoryRepresentationBytes else {
                throw LegacyMigrationParsingError.unreadableSource
            }
            var aggregate = try TelemetryStore.decode(
                LegacyHistoryAggregateState.self,
                from: progress.aggregateStatePayload
            )
            var reader = try LegacyJSONArrayElementReader(
                data: descriptor.representation,
                startingAt: progress.snapshot.checkpointByteOffset,
                nextRecordIndex: progress.snapshot.checkpointRecordIndex
            )
            var records: [LegacyImportedRecordDraft] = []
            var candidates: [LegacyWorkoutCandidateDraft] = []
            var batchElementCount = 0
            var parsedRecordCount = progress.snapshot.parsedRecordCount
            var malformedRecordCount = progress.snapshot.malformedRecordCount
            var warningCount = progress.snapshot.warningCount
            var lastOffset = progress.snapshot.checkpointByteOffset
            var lastRecordIndex = progress.snapshot.checkpointRecordIndex
            var insertedRecords = 0

            while let element = try reader.next() {
                guard parsedRecordCount < Self.maximumHistoryEntryCount else {
                    throw LegacyMigrationParsingError.unreadableSource
                }
                lastOffset = element.endOffset
                lastRecordIndex = element.recordIndex
                parsedRecordCount += 1
                batchElementCount += 1
                if let data = element.data {
                    do {
                        let canonicalDigest = try LegacyTelemetryMigrationParser
                            .canonicalObjectDigest(data)
                        let occurrence = (aggregate.occurrencesByCanonicalDigest[
                            canonicalDigest
                        ] ?? 0) + 1
                        aggregate.occurrencesByCanonicalDigest[canonicalDigest] = occurrence
                        let parsed = try LegacyTelemetryMigrationParser.parseWorkoutHistory(
                            data,
                            sourceID: definition.sourceID,
                            element: element,
                            occurrence: occurrence,
                            exactProfile: exactProfile
                        )
                        records.append(parsed.record)
                        candidates.append(parsed.candidate)
                        warningCount += Int64(parsed.record.payload.warnings.count)
                    } catch {
                        malformedRecordCount += 1
                        warningCount += 1
                    }
                }

                if batchElementCount >= batchSize {
                    insertedRecords += try await store.commitLegacyMigrationBatch(
                        sourceID: definition.sourceID,
                        records: records,
                        candidates: candidates,
                        checkpointByteOffset: lastOffset,
                        checkpointRecordIndex: lastRecordIndex,
                        parsedRecordCount: parsedRecordCount,
                        malformedRecordCount: malformedRecordCount,
                        warningCount: warningCount,
                        aggregateStatePayload: try TelemetryStore.encode(aggregate),
                        completing: false,
                        now: Date()
                    )
                    records.removeAll(keepingCapacity: true)
                    candidates.removeAll(keepingCapacity: true)
                    batchElementCount = 0
                    committedBatchCount += 1
                    if shouldPauseAfterCommittedBatch(committedBatchCount) {
                        try await store.pauseLegacyMigrationSource(
                            sourceID: definition.sourceID,
                            now: Date()
                        )
                        return .paused(importedRecords: insertedRecords)
                    }
                }
            }

            insertedRecords += try await store.commitLegacyMigrationBatch(
                sourceID: definition.sourceID,
                records: records,
                candidates: candidates,
                checkpointByteOffset: lastOffset,
                checkpointRecordIndex: lastRecordIndex,
                parsedRecordCount: parsedRecordCount,
                malformedRecordCount: malformedRecordCount,
                warningCount: warningCount,
                aggregateStatePayload: try TelemetryStore.encode(aggregate),
                completing: true,
                now: Date()
            )
            committedBatchCount += 1
            return .completed(importedRecords: insertedRecords)
        } catch {
            if let sourceID {
                try? await store.failLegacyMigrationSource(
                    sourceID: sourceID,
                    code: "workout-history-source-failed",
                    detail: boundedErrorDetail(error),
                    now: Date()
                )
            }
            return .failed
        }
    }

    private func boundedErrorDetail(_ error: Error) -> String {
        String(describing: error).prefix(512).description
    }
}

extension TelemetryStore: LegacyTelemetryMigrationCapability {
    public func migrateLegacyTelemetry(
        _ request: LegacyTelemetryMigrationRequest
    ) async -> LegacyTelemetryMigrationReport {
        await LegacyTelemetryMigrator(store: self).run(request)
    }
}
