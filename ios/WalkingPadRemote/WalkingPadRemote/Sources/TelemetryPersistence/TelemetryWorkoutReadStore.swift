import Foundation
import SwiftData
import TelemetryAnalysis
import TelemetryDomain

private struct TelemetrySessionConfigurationProjection: Decodable {
    let targetHeartRate: Int?
}

private enum StoredWorkoutProjectionCandidate {
    case native(TelemetryWorkoutSessionV1)
    case imported(TelemetryLegacyImportedWorkoutV2)

    var cursor: WorkoutHistoryCursor {
        switch self {
        case let .native(model):
            WorkoutHistoryCursor(
                startedAt: model.startedAt,
                stableTieBreaker: "native:\(model.sessionID)"
            )
        case let .imported(model):
            WorkoutHistoryCursor(
                startedAt: model.startedAt,
                stableTieBreaker: "imported:\(model.importedWorkoutID)"
            )
        }
    }
}

private struct WorkoutReadDiagnosticsAccumulator {
    var storeFetchCount = 0
    var maximumStoreFetchLimit = 0
    var exactNativeDuplicateCount = 0

    mutating func recordFetch(limit: Int) {
        storeFetchCount += 1
        maximumStoreFetchLimit = max(maximumStoreFetchLimit, limit)
    }

    mutating func merge(_ diagnostics: WorkoutReadDiagnostics) {
        storeFetchCount += diagnostics.storeFetchCount
        maximumStoreFetchLimit = max(
            maximumStoreFetchLimit,
            diagnostics.maximumStoreFetchLimit
        )
        exactNativeDuplicateCount += diagnostics.exactNativeDuplicateCount
    }

    var snapshot: WorkoutReadDiagnostics {
        WorkoutReadDiagnostics(
            storeFetchCount: storeFetchCount,
            maximumStoreFetchLimit: maximumStoreFetchLimit,
            hydratedTimeSeriesRecordCount: 0,
            exactNativeDuplicateCount: exactNativeDuplicateCount
        )
    }
}

public extension TelemetryStore {
    func fetchWorkoutHistoryPage(
        filter: WorkoutReadFilter,
        after cursor: WorkoutHistoryCursor?,
        limit: Int
    ) async throws -> WorkoutHistoryPage {
        guard limit > 0, limit <= 100 else {
            throw TelemetryWorkoutReadError.invalidPageSize
        }

        let batchLimit = min(256, max(32, limit * 2))
        var scanCursor = cursor ?? filter.startedBefore.map {
            WorkoutHistoryCursor(
                startedAt: $0,
                stableTieBreaker: "range-upper-bound"
            )
        }
        var projections: [WorkoutHistoryProjection] = []
        var diagnostics = WorkoutReadDiagnosticsAccumulator()

        while projections.count < limit {
            let nativeBatch = try fetchNativeProjectionCandidates(
                scope: filter.profileScope,
                after: scanCursor,
                limit: batchLimit + 1
            )
            diagnostics.recordFetch(limit: batchLimit + 1)
            let importedBatch = try fetchImportedProjectionCandidates(
                scope: filter.profileScope,
                after: scanCursor,
                limit: batchLimit + 1
            )
            diagnostics.recordFetch(limit: batchLimit + 1)

            let nativeHasMore = nativeBatch.count > batchLimit
            let importedHasMore = importedBatch.count > batchLimit
            let merged = mergeProjectionCandidates(
                native: Array(nativeBatch.prefix(batchLimit)),
                imported: Array(importedBatch.prefix(batchLimit))
            )
            guard !merged.isEmpty else {
                return WorkoutHistoryPage(
                    items: projections,
                    nextCursor: nil,
                    diagnostics: diagnostics.snapshot
                )
            }

            for (index, candidate) in merged.enumerated() {
                try Task.checkCancellation()
                scanCursor = candidate.cursor
                if let lowerBound = filter.startedAtOrAfter {
                    guard let startedAt = candidate.cursor.startedAt,
                          startedAt >= lowerBound else {
                        return WorkoutHistoryPage(
                            items: projections,
                            nextCursor: nil,
                            diagnostics: diagnostics.snapshot
                        )
                    }
                }
                guard matchesDateFilter(candidate.cursor.startedAt, filter: filter) else {
                    continue
                }

                switch candidate {
                case let .native(model):
                    projections.append(try nativeProjection(model))
                case let .imported(model):
                    let candidateModels = try importedCandidateModels(model)
                    diagnostics.recordFetch(limit: max(1, try modelCandidateIDs(model).count))
                    if try hasExactNativeSession(
                        for: candidateModels,
                        profileScope: filter.profileScope
                    ) {
                        diagnostics.exactNativeDuplicateCount += 1
                        continue
                    }
                    projections.append(try importedProjection(model, candidates: candidateModels))
                }

                if projections.count == limit {
                    let hasUnprocessed = index + 1 < merged.count
                        || nativeHasMore
                        || importedHasMore
                    return WorkoutHistoryPage(
                        items: projections,
                        nextCursor: hasUnprocessed ? scanCursor : nil,
                        diagnostics: diagnostics.snapshot
                    )
                }
            }

            guard nativeHasMore || importedHasMore else {
                return WorkoutHistoryPage(
                    items: projections,
                    nextCursor: nil,
                    diagnostics: diagnostics.snapshot
                )
            }
        }

        return WorkoutHistoryPage(
            items: projections,
            nextCursor: scanCursor,
            diagnostics: diagnostics.snapshot
        )
    }

    func fetchWorkoutStatistics(
        filter: WorkoutReadFilter,
        batchSize: Int = 100
    ) async throws -> WorkoutStatisticsProjection {
        let boundedBatchSize = min(100, max(1, batchSize))
        var cursor: WorkoutHistoryCursor?
        var queryableWorkoutCount = 0
        var includedWorkoutCount = 0
        var excludedWorkoutCount = 0
        var unavailableDurationCount = 0
        var unavailableZoneCount = 0
        var durationTotal = 0.0
        var durationValueCount = 0
        var beatsPerMetreWeightedTotal = 0.0
        var beatsPerMetreWeight = 0.0
        var zoneTotals = Array(repeating: 0.0, count: 5)
        var zoneValueCounts = Array(repeating: 0, count: 5)
        var diagnostics = WorkoutReadDiagnosticsAccumulator()

        repeat {
            try Task.checkCancellation()
            let page = try await fetchWorkoutHistoryPage(
                filter: filter,
                after: cursor,
                limit: boundedBatchSize
            )
            diagnostics.merge(page.diagnostics)
            cursor = page.nextCursor

            for item in page.items {
                queryableWorkoutCount += 1
                guard item.quality.includedInStatistics else {
                    excludedWorkoutCount += 1
                    continue
                }
                includedWorkoutCount += 1
                if let duration = item.durationSeconds {
                    durationTotal += duration
                    durationValueCount += 1
                    if let beatsPerMetre = item.beatsPerMetre {
                        beatsPerMetreWeightedTotal += beatsPerMetre * duration
                        beatsPerMetreWeight += duration
                    }
                } else {
                    unavailableDurationCount += 1
                }

                guard let zones = item.zoneSeconds, zones.count == 5 else {
                    unavailableZoneCount += 1
                    continue
                }
                var hasUnavailableZone = false
                for index in 0..<5 {
                    if let value = zones[index] {
                        zoneTotals[index] += value
                        zoneValueCounts[index] += 1
                    } else {
                        hasUnavailableZone = true
                    }
                }
                if hasUnavailableZone {
                    unavailableZoneCount += 1
                }
            }
        } while cursor != nil

        return WorkoutStatisticsProjection(
            totalDurationSeconds: durationValueCount > 0 ? durationTotal : nil,
            averageBeatsPerMetre: beatsPerMetreWeight > 0
                ? beatsPerMetreWeightedTotal / beatsPerMetreWeight
                : nil,
            zoneSeconds: zip(zoneTotals, zoneValueCounts).map { total, count in
                count > 0 ? total : nil
            },
            queryableWorkoutCount: queryableWorkoutCount,
            includedWorkoutCount: includedWorkoutCount,
            excludedWorkoutCount: excludedWorkoutCount,
            workoutsWithUnavailableDuration: unavailableDurationCount,
            workoutsWithUnavailableZones: unavailableZoneCount,
            isPartial: unavailableDurationCount > 0 || unavailableZoneCount > 0,
            diagnostics: diagnostics.snapshot
        )
    }
}

private extension TelemetryStore {
    func fetchNativeProjectionCandidates(
        scope: WorkoutReadProfileScope,
        after cursor: WorkoutHistoryCursor?,
        limit: Int
    ) throws -> [TelemetryWorkoutSessionV1] {
        guard cursor?.startedAt != nil || cursor == nil else {
            return []
        }
        let descriptor: FetchDescriptor<TelemetryWorkoutSessionV1>
        let cursorDate = cursor?.startedAt
        let cursorSource = cursor?.stableTieBreaker.split(separator: ":", maxSplits: 1).first
        let cursorID = cursor?.stableTieBreaker.split(separator: ":", maxSplits: 1).last
        switch (scope, cursorDate, cursorSource, cursorID) {
        case let (.exact(profile), .some(date), .some("native"), .some(id)):
            let id = String(id)
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    ($0.profileLocalIdentifier == profile
                        || $0.profileLocalIdentifier == alternateProfile)
                        && ($0.startedAt < date || ($0.startedAt == date && $0.sessionID > id))
                },
                sortBy: nativeSortDescriptors
            )
        case let (.exact(profile), .some(date), _, _):
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    ($0.profileLocalIdentifier == profile
                        || $0.profileLocalIdentifier == alternateProfile)
                        && $0.startedAt <= date
                },
                sortBy: nativeSortDescriptors
            )
        case let (.exact(profile), nil, _, _):
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == profile
                        || $0.profileLocalIdentifier == alternateProfile
                },
                sortBy: nativeSortDescriptors
            )
        case (.unassigned, _, _, _):
            return []
        case let (.all, .some(date), .some("native"), .some(id)):
            let id = String(id)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.startedAt < date || ($0.startedAt == date && $0.sessionID > id)
                },
                sortBy: nativeSortDescriptors
            )
        case let (.all, .some(date), _, _):
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.startedAt <= date },
                sortBy: nativeSortDescriptors
            )
        case (.all, nil, _, _):
            descriptor = FetchDescriptor(sortBy: nativeSortDescriptors)
        }

        var bounded = descriptor
        bounded.fetchLimit = limit
        return try modelContext.fetch(bounded)
    }

    func fetchImportedProjectionCandidates(
        scope: WorkoutReadProfileScope,
        after cursor: WorkoutHistoryCursor?,
        limit: Int
    ) throws -> [TelemetryLegacyImportedWorkoutV2] {
        let descriptor: FetchDescriptor<TelemetryLegacyImportedWorkoutV2>
        let cursorDate = cursor?.startedAt
        let cursorSource = cursor?.stableTieBreaker.split(separator: ":", maxSplits: 1).first
        let cursorID = cursor?.stableTieBreaker.split(separator: ":", maxSplits: 1).last
        let nilAsNewestDate = Date.distantFuture

        switch (scope, cursorDate, cursorSource, cursorID) {
        case let (.exact(profile), .some(date), .some("imported"), .some(id)):
            let id = String(id)
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            return try fetchImportedSegments(
                [
                    FetchDescriptor(
                        predicate: #Predicate {
                            ($0.profileLocalIdentifier == profile
                                || $0.profileLocalIdentifier == alternateProfile)
                                && $0.startedAt == date
                                && $0.importedWorkoutID > id
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate {
                            ($0.profileLocalIdentifier == profile
                                || $0.profileLocalIdentifier == alternateProfile)
                                && $0.startedAt != nil
                                && ($0.startedAt ?? nilAsNewestDate) < date
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate {
                            ($0.profileLocalIdentifier == profile
                                || $0.profileLocalIdentifier == alternateProfile)
                                && $0.startedAt == nil
                        },
                        sortBy: importedSortDescriptors
                    ),
                ],
                limit: limit
            )
        case let (.exact(profile), .some(date), _, _):
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            return try fetchImportedSegments(
                [
                    FetchDescriptor(
                        predicate: #Predicate {
                            ($0.profileLocalIdentifier == profile
                                || $0.profileLocalIdentifier == alternateProfile)
                                && $0.startedAt != nil
                                && ($0.startedAt ?? nilAsNewestDate) < date
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate {
                            ($0.profileLocalIdentifier == profile
                                || $0.profileLocalIdentifier == alternateProfile)
                                && $0.startedAt == nil
                        },
                        sortBy: importedSortDescriptors
                    ),
                ],
                limit: limit
            )
        case let (.exact(profile), nil, .some("imported"), .some(id)):
            let id = String(id)
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    ($0.profileLocalIdentifier == profile
                        || $0.profileLocalIdentifier == alternateProfile)
                        && $0.startedAt == nil
                        && $0.importedWorkoutID > id
                },
                sortBy: importedSortDescriptors
            )
        case let (.exact(profile), nil, _, _):
            let alternateProfile = Self.alternateUUIDSpelling(for: profile)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == profile
                        || $0.profileLocalIdentifier == alternateProfile
                },
                sortBy: importedSortDescriptors
            )
        case let (.unassigned, .some(date), .some("imported"), .some(id)):
            let id = String(id)
            var equalDateDescriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == nil
                        && $0.startedAt == date
                        && $0.importedWorkoutID > id
                },
                sortBy: importedSortDescriptors
            )
            equalDateDescriptor.fetchLimit = limit
            var result = try modelContext.fetch(equalDateDescriptor)
            guard result.count < limit else { return result }

            var olderDatedDescriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == nil
                        && $0.startedAt != nil
                        && ($0.startedAt ?? nilAsNewestDate) < date
                },
                sortBy: importedSortDescriptors
            )
            olderDatedDescriptor.fetchLimit = limit - result.count
            result.append(contentsOf: try modelContext.fetch(olderDatedDescriptor))
            guard result.count < limit else { return result }

            var nilDateDescriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == nil && $0.startedAt == nil
                },
                sortBy: importedSortDescriptors
            )
            nilDateDescriptor.fetchLimit = limit - result.count
            result.append(contentsOf: try modelContext.fetch(nilDateDescriptor))
            return result
        case let (.unassigned, .some(date), _, _):
            return try fetchImportedSegments(
                [
                    FetchDescriptor(
                        predicate: #Predicate {
                            $0.profileLocalIdentifier == nil
                                && $0.startedAt != nil
                                && ($0.startedAt ?? nilAsNewestDate) < date
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate {
                            $0.profileLocalIdentifier == nil && $0.startedAt == nil
                        },
                        sortBy: importedSortDescriptors
                    ),
                ],
                limit: limit
            )
        case let (.unassigned, nil, .some("imported"), .some(id)):
            let id = String(id)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.profileLocalIdentifier == nil
                        && $0.startedAt == nil
                        && $0.importedWorkoutID > id
                },
                sortBy: importedSortDescriptors
            )
        case (.unassigned, nil, _, _):
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.profileLocalIdentifier == nil },
                sortBy: importedSortDescriptors
            )
        case let (.all, .some(date), .some("imported"), .some(id)):
            let id = String(id)
            return try fetchImportedSegments(
                [
                    FetchDescriptor(
                        predicate: #Predicate {
                            $0.startedAt == date && $0.importedWorkoutID > id
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate {
                            $0.startedAt != nil
                                && ($0.startedAt ?? nilAsNewestDate) < date
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate { $0.startedAt == nil },
                        sortBy: importedSortDescriptors
                    ),
                ],
                limit: limit
            )
        case let (.all, .some(date), _, _):
            return try fetchImportedSegments(
                [
                    FetchDescriptor(
                        predicate: #Predicate {
                            $0.startedAt != nil
                                && ($0.startedAt ?? nilAsNewestDate) < date
                        },
                        sortBy: importedSortDescriptors
                    ),
                    FetchDescriptor(
                        predicate: #Predicate { $0.startedAt == nil },
                        sortBy: importedSortDescriptors
                    ),
                ],
                limit: limit
            )
        case let (.all, nil, .some("imported"), .some(id)):
            let id = String(id)
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.startedAt == nil && $0.importedWorkoutID > id
                },
                sortBy: importedSortDescriptors
            )
        case (.all, nil, _, _):
            descriptor = FetchDescriptor(sortBy: importedSortDescriptors)
        }

        var bounded = descriptor
        bounded.fetchLimit = limit
        return try modelContext.fetch(bounded)
    }

    func fetchImportedSegments(
        _ descriptors: [FetchDescriptor<TelemetryLegacyImportedWorkoutV2>],
        limit: Int
    ) throws -> [TelemetryLegacyImportedWorkoutV2] {
        var result: [TelemetryLegacyImportedWorkoutV2] = []
        result.reserveCapacity(limit)
        for descriptor in descriptors where result.count < limit {
            var bounded = descriptor
            bounded.fetchLimit = limit - result.count
            result.append(contentsOf: try modelContext.fetch(bounded))
        }
        return result
    }

    var nativeSortDescriptors: [SortDescriptor<TelemetryWorkoutSessionV1>] {
        [
            SortDescriptor(\.startedAt, order: .reverse),
            SortDescriptor(\.sessionID),
        ]
    }

    var importedSortDescriptors: [SortDescriptor<TelemetryLegacyImportedWorkoutV2>] {
        [
            SortDescriptor(\.startedAt, order: .reverse),
            SortDescriptor(\.importedWorkoutID),
        ]
    }

    func mergeProjectionCandidates(
        native: [TelemetryWorkoutSessionV1],
        imported: [TelemetryLegacyImportedWorkoutV2]
    ) -> [StoredWorkoutProjectionCandidate] {
        var left = 0
        var right = 0
        var merged: [StoredWorkoutProjectionCandidate] = []
        merged.reserveCapacity(native.count + imported.count)
        while left < native.count || right < imported.count {
            if left == native.count {
                merged.append(.imported(imported[right]))
                right += 1
            } else if right == imported.count {
                merged.append(.native(native[left]))
                left += 1
            } else {
                let nativeCandidate = StoredWorkoutProjectionCandidate.native(native[left])
                let importedCandidate = StoredWorkoutProjectionCandidate.imported(imported[right])
                if projectionCursorPrecedes(nativeCandidate.cursor, importedCandidate.cursor) {
                    merged.append(nativeCandidate)
                    left += 1
                } else {
                    merged.append(importedCandidate)
                    right += 1
                }
            }
        }
        return merged
    }

    func projectionCursorPrecedes(
        _ lhs: WorkoutHistoryCursor,
        _ rhs: WorkoutHistoryCursor
    ) -> Bool {
        switch (lhs.startedAt, rhs.startedAt) {
        case let (.some(left), .some(right)) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.stableTieBreaker < rhs.stableTieBreaker
        }
    }

    func matchesDateFilter(_ date: Date?, filter: WorkoutReadFilter) -> Bool {
        guard let date else {
            return filter.startedAtOrAfter == nil && filter.startedBefore == nil
        }
        if let lower = filter.startedAtOrAfter, date < lower {
            return false
        }
        if let upper = filter.startedBefore, date >= upper {
            return false
        }
        return true
    }

    func nativeProjection(
        _ model: TelemetryWorkoutSessionV1
    ) throws -> WorkoutHistoryProjection {
        let configuration: TelemetrySessionConfigurationProjection? = try model.configuration.map {
            try Self.decode(
                TelemetrySessionConfigurationProjection.self,
                from: $0.canonicalPayload
            )
        }
        let analysis = try latestAnalysisModel(sessionID: model.sessionID)
        let analysisMetricsUsable = analysis.map {
            $0.qualityGradeKey != AnalysisQualityGrade.unusable.rawValue
        } ?? false
        let metricAnalysis = analysisMetricsUsable ? analysis : nil
        let detail: WorkoutAnalysisDetailV1? = try metricAnalysis.flatMap {
            guard $0.detailSchemaVersion == Int(WorkoutAnalysisDetailV1.schemaVersion) else {
                return nil
            }
            return try Self.decode(WorkoutAnalysisDetailV1.self, from: $0.detailPayload)
        }
        let durationSeconds = detail?.quality.sessionDurationSeconds
            ?? model.endedElapsedMicroseconds.map { Double($0) / 1_000_000 }
        let zoneSeconds = detail?.control.zoneDurations.isEmpty == false
            ? (1...5).map { zone in
                detail?.control.zoneDurations.first(where: { $0.zone == zone })?.seconds
            }
            : nil
        let averageSpeed = metricAnalysis?.averageFactualSpeedKilometresPerHour.map {
            WorkoutSpeedProjection(
                kilometresPerHour: $0,
                evidenceKind: .factual,
                provenance: "telemetry-v2-analysis-factual"
            )
        }
        var unavailable: [String] = []
        if durationSeconds == nil { unavailable.append("duration") }
        if configuration?.targetHeartRate == nil { unavailable.append("targetHeartRate") }
        if metricAnalysis?.averageHeartRate == nil { unavailable.append("averageHeartRate") }
        if averageSpeed == nil { unavailable.append("averageFactualSpeed") }
        unavailable.append("beatsPerMetre")
        if zoneSeconds == nil { unavailable.append("zoneSeconds") }

        let completed = model.lifecycleStateKey == SessionLifecycleState.completed.rawValue
        let adaptationEligible = completed
            && analysis?.qualityGradeKey == AnalysisQualityGrade.high.rawValue
        return WorkoutHistoryProjection(
            id: "native:\(model.sessionID)",
            origin: .nativeV2,
            startedAt: model.startedAt,
            endedAt: model.endedAt,
            durationSeconds: durationSeconds,
            targetHeartRate: configuration?.targetHeartRate,
            averageHeartRate: metricAnalysis?.averageHeartRate,
            averageSpeed: averageSpeed,
            beatsPerMetre: nil,
            zoneSeconds: zoneSeconds,
            healthKitWorkoutIdentifier: model.healthKitWorkoutIdentifier.flatMap(UUID.init),
            telemetrySchemaVersion: model.telemetrySchemaVersion,
            appVersion: model.appVersion,
            buildNumber: model.buildNumber,
            algorithmVersion: model.algorithmVersion,
            analyzerVersion: analysis?.analyzerVersion,
            quality: WorkoutProjectionQuality(
                lifecycleState: model.lifecycleStateKey,
                recorderComplete: model.recorderIsComplete,
                analysisGrade: analysis?.qualityGradeKey,
                identityStatus: "exact",
                possibleDuplicate: false,
                adaptationEligible: adaptationEligible,
                includedInStatistics: completed,
                provenance: ["telemetry-v2-native"],
                unavailableMetrics: unavailable,
                warnings: model.incompleteReason.map { [$0] } ?? []
            )
        )
    }

    func importedProjection(
        _ model: TelemetryLegacyImportedWorkoutV2,
        candidates: [TelemetryLegacyWorkoutCandidateV2]
    ) throws -> WorkoutHistoryProjection {
        let summary = try Self.decode(
            LegacyResolvedWorkoutSummary.self,
            from: model.resolvedSummaryPayload
        )
        let candidateSummaries = try candidates.map {
            try Self.decode(LegacyWorkoutCandidateSummary.self, from: $0.summaryPayload)
        }
        let healthKitIdentifiers = Set(
            candidates.compactMap(\.healthKitWorkoutIdentifier).compactMap(UUID.init)
        )
        let healthKitIdentifier = healthKitIdentifiers.count == 1
            ? healthKitIdentifiers.first
            : nil
        let durationSeconds = summary.durationMicroseconds.selected.map {
            Double($0.value) / 1_000_000
        }
        let averageSpeed = summary.estimatedAverageSpeedKilometresPerHour.selected.map {
            WorkoutSpeedProjection(
                kilometresPerHour: $0.value,
                evidenceKind: .legacyEstimated,
                provenance: $0.provenance
            )
        }
        let zoneSeconds = summary.zoneMicroseconds.selected.map { sourced in
            sourced.value.map { value in value.map { Double($0) / 1_000_000 } }
        }
        let isIncomplete = candidateSummaries.contains {
            $0.legacySessionEvidenceComplete == false || $0.malformedRecordCount > 0
        }
        let identityStatus = model.identityStatusKey
        let includedInStatistics = identityStatus == LegacyIdentityStatus.exact.rawValue
            && !model.possibleDuplicate
        var unavailable: [String] = []
        if durationSeconds == nil { unavailable.append("duration") }
        if summary.targetBeatsPerMinute.selected == nil { unavailable.append("targetHeartRate") }
        if summary.averageHeartRateBeatsPerMinute.selected == nil {
            unavailable.append("averageHeartRate")
        }
        if averageSpeed == nil { unavailable.append("averageSpeed") }
        unavailable.append("beatsPerMetre")
        if zoneSeconds == nil { unavailable.append("zoneSeconds") }

        let warnings = (
            summary.warnings
                + summary.conflicts.map { "conflict:\($0.field)" }
                + candidateSummaries.flatMap(\.warnings)
                + (healthKitIdentifiers.count > 1 ? ["conflicting-healthkit-workout-identifier"] : [])
        )

        return WorkoutHistoryProjection(
            id: "imported:\(model.importedWorkoutID)",
            origin: .importedLegacy,
            startedAt: model.startedAt,
            endedAt: model.endedAt,
            durationSeconds: durationSeconds,
            targetHeartRate: summary.targetBeatsPerMinute.selected?.value,
            averageHeartRate: summary.averageHeartRateBeatsPerMinute.selected?.value,
            averageSpeed: averageSpeed,
            beatsPerMetre: nil,
            zoneSeconds: zoneSeconds,
            healthKitWorkoutIdentifier: healthKitIdentifier,
            telemetrySchemaVersion: nil,
            appVersion: nil,
            buildNumber: nil,
            algorithmVersion: nil,
            analyzerVersion: nil,
            quality: WorkoutProjectionQuality(
                lifecycleState: isIncomplete ? "imported-incomplete" : "imported",
                recorderComplete: isIncomplete ? false : nil,
                analysisGrade: nil,
                identityStatus: identityStatus,
                possibleDuplicate: model.possibleDuplicate,
                adaptationEligible: model.adaptationQualityEligible,
                includedInStatistics: includedInStatistics,
                provenance: ["telemetry-v2-imported-legacy"],
                unavailableMetrics: unavailable,
                warnings: warnings
            )
        )
    }

    func latestAnalysisModel(
        sessionID: String
    ) throws -> TelemetryWorkoutAnalysisV1? {
        var descriptor = FetchDescriptor<TelemetryWorkoutAnalysisV1>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [
                SortDescriptor(\.generatedAt, order: .reverse),
                SortDescriptor(\.analysisID),
            ]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func importedCandidateModels(
        _ model: TelemetryLegacyImportedWorkoutV2
    ) throws -> [TelemetryLegacyWorkoutCandidateV2] {
        var candidates: [TelemetryLegacyWorkoutCandidateV2] = []
        for candidateID in try modelCandidateIDs(model) {
            var descriptor = FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
                predicate: #Predicate { $0.candidateID == candidateID }
            )
            descriptor.fetchLimit = 1
            guard let candidate = try modelContext.fetch(descriptor).first else {
                throw TelemetryWorkoutReadError.corruptProjection(
                    "missing imported candidate \(candidateID)"
                )
            }
            candidates.append(candidate)
        }
        return candidates.sorted { $0.candidateID < $1.candidateID }
    }

    func modelCandidateIDs(
        _ model: TelemetryLegacyImportedWorkoutV2
    ) throws -> [String] {
        do {
            return try Self.decode([String].self, from: model.candidateIDsPayload)
        } catch {
            throw TelemetryWorkoutReadError.corruptProjection(
                "invalid imported candidate linkage for \(model.importedWorkoutID)"
            )
        }
    }

    func hasExactNativeSession(
        for candidates: [TelemetryLegacyWorkoutCandidateV2],
        profileScope: WorkoutReadProfileScope
    ) throws -> Bool {
        guard case let .exact(profile) = profileScope else {
            return false
        }
        let alternateProfile = Self.alternateUUIDSpelling(for: profile)
        for candidate in candidates where candidate.profileLocalIdentifier == profile
            || candidate.profileLocalIdentifier == alternateProfile {
            if let stableSessionID = candidate.stableLegacySessionIdentifier {
                var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
                    predicate: #Predicate {
                        ($0.profileLocalIdentifier == profile
                            || $0.profileLocalIdentifier == alternateProfile)
                            && $0.sessionID == stableSessionID
                    }
                )
                descriptor.fetchLimit = 1
                if try !modelContext.fetch(descriptor).isEmpty {
                    return true
                }
            }
            if let healthKitID = candidate.healthKitWorkoutIdentifier {
                var descriptor = FetchDescriptor<TelemetryWorkoutSessionV1>(
                    predicate: #Predicate {
                        ($0.profileLocalIdentifier == profile
                            || $0.profileLocalIdentifier == alternateProfile)
                            && $0.healthKitWorkoutIdentifier == healthKitID
                    }
                )
                descriptor.fetchLimit = 1
                if try !modelContext.fetch(descriptor).isEmpty {
                    return true
                }
            }
        }
        return false
    }

    static func alternateUUIDSpelling(for value: String) -> String {
        guard let uuid = UUID(uuidString: value) else { return value }
        let canonical = uuid.uuidString
        return value == canonical ? canonical.lowercased() : canonical
    }
}
