import Foundation
import SwiftData
import TelemetryDomain

struct LegacyMigrationSourceProgress: Sendable {
    let snapshot: LegacyMigrationSourceSnapshot
    let aggregateStatePayload: Data
}

extension TelemetryStore {
    func beginLegacyMigrationSource(
        _ definition: LegacyMigrationSourceDefinition,
        importerVersion: String,
        emptyAggregateStatePayload: Data,
        now: Date
    ) throws -> LegacyMigrationSourceProgress {
        if let existing = try legacySourceModel(definition.sourceID) {
            guard existing.sourceKindKey == definition.kind.rawValue,
                  existing.contentHashDigest == definition.contentHashDigest,
                  existing.importerVersion == importerVersion else {
                throw TelemetryStoreError.conflictingStableIdentity(definition.sourceID)
            }
            if existing.statusKey != LegacyMigrationSourceStatus.completed.rawValue {
                try explicitTransaction {
                    existing.statusKey = LegacyMigrationSourceStatus.inProgress.rawValue
                    existing.errorCode = nil
                    existing.errorDetail = nil
                    existing.updatedAt = now
                }
            }
            return try sourceProgress(existing)
        }

        let model = TelemetryLegacyMigrationSourceV2(
            sourceID: definition.sourceID,
            sourceKindKey: definition.kind.rawValue,
            contentHashDigest: definition.contentHashDigest,
            importerVersion: importerVersion,
            locator: definition.locator,
            exactProfileLocalIdentifier: definition.exactProfileLocalIdentifier,
            statusKey: LegacyMigrationSourceStatus.inProgress.rawValue,
            checkpointByteOffset: 0,
            checkpointRecordIndex: 0,
            parsedRecordCount: 0,
            malformedRecordCount: 0,
            warningCount: 0,
            aggregateStatePayload: emptyAggregateStatePayload,
            errorCode: nil,
            errorDetail: nil,
            updatedAt: now,
            completedAt: nil
        )
        try explicitTransaction {
            modelContext.insert(model)
        }
        return try sourceProgress(model)
    }

    @discardableResult
    func commitLegacyMigrationBatch(
        sourceID: String,
        records: [LegacyImportedRecordDraft],
        candidates: [LegacyWorkoutCandidateDraft],
        checkpointByteOffset: Int64,
        checkpointRecordIndex: Int64,
        parsedRecordCount: Int64,
        malformedRecordCount: Int64,
        warningCount: Int64,
        aggregateStatePayload: Data,
        completing: Bool,
        now: Date
    ) throws -> Int {
        guard let source = try legacySourceModel(sourceID) else {
            throw TelemetryStoreError.corruptStoredRecord("missing migration source \(sourceID)")
        }
        guard checkpointByteOffset >= source.checkpointByteOffset,
              checkpointRecordIndex >= source.checkpointRecordIndex,
              parsedRecordCount >= source.parsedRecordCount,
              malformedRecordCount >= source.malformedRecordCount,
              warningCount >= source.warningCount else {
            throw TelemetryStoreError.corruptStoredRecord(
                "regressed migration checkpoint \(sourceID)"
            )
        }
        var insertedRecordCount = 0
        try explicitTransaction {
            for record in records {
                if let existing = try legacyImportedRecordModel(
                    sourceItemIdentityKey: record.sourceItemIdentityKey
                ) {
                    guard try storedRecordMatches(existing, draft: record) else {
                        throw TelemetryStoreError.conflictingStableIdentity(
                            record.sourceItemIdentityKey
                        )
                    }
                    continue
                }
                modelContext.insert(try makeImportedRecordModel(record))
                insertedRecordCount += 1
            }
            for candidate in candidates {
                if let existing = try legacyCandidateModel(candidate.candidateID) {
                    guard try storedCandidateMatches(existing, draft: candidate) else {
                        throw TelemetryStoreError.conflictingStableIdentity(candidate.candidateID)
                    }
                    continue
                }
                modelContext.insert(try makeCandidateModel(candidate))
            }
            source.checkpointByteOffset = checkpointByteOffset
            source.checkpointRecordIndex = checkpointRecordIndex
            source.parsedRecordCount = parsedRecordCount
            source.malformedRecordCount = malformedRecordCount
            source.warningCount = warningCount
            source.aggregateStatePayload = aggregateStatePayload
            source.statusKey = completing
                ? LegacyMigrationSourceStatus.completed.rawValue
                : LegacyMigrationSourceStatus.inProgress.rawValue
            source.errorCode = nil
            source.errorDetail = nil
            source.updatedAt = now
            source.completedAt = completing ? now : nil
        }
        return insertedRecordCount
    }

    func pauseLegacyMigrationSource(sourceID: String, now: Date) throws {
        guard let source = try legacySourceModel(sourceID) else { return }
        try explicitTransaction {
            source.statusKey = LegacyMigrationSourceStatus.paused.rawValue
            source.updatedAt = now
        }
    }

    func failLegacyMigrationSource(
        sourceID: String,
        code: String,
        detail: String,
        now: Date
    ) throws {
        guard let source = try legacySourceModel(sourceID) else { return }
        try explicitTransaction {
            source.statusKey = LegacyMigrationSourceStatus.failed.rawValue
            source.errorCode = code
            source.errorDetail = detail
            source.updatedAt = now
        }
    }

    func failLegacyReconciliation(detail: String, now: Date) throws {
        let completed = LegacyMigrationSourceStatus.completed.rawValue
        let inProgress = LegacyMigrationSourceStatus.inProgress.rawValue
        while true {
            var descriptor = FetchDescriptor<TelemetryLegacyMigrationSourceV2>(
                predicate: #Predicate {
                    $0.statusKey == completed || $0.statusKey == inProgress
                },
                sortBy: [SortDescriptor(\.sourceID)]
            )
            descriptor.fetchLimit = 128
            let sources = try modelContext.fetch(descriptor)
            guard !sources.isEmpty else { return }
            try explicitTransaction {
                for source in sources {
                    source.statusKey = LegacyMigrationSourceStatus.failed.rawValue
                    source.errorCode = "legacy-reconciliation-failed"
                    source.errorDetail = detail
                    source.updatedAt = now
                }
            }
        }
    }

    public func fetchLegacyMigrationSources() throws -> [LegacyMigrationSourceSnapshot] {
        let descriptor = FetchDescriptor<TelemetryLegacyMigrationSourceV2>(
            sortBy: [SortDescriptor(\.sourceID)]
        )
        return try modelContext.fetch(descriptor).map(sourceSnapshot)
    }

    public func fetchLegacyImportedRecords(
        sourceID: String? = nil
    ) throws -> [LegacyImportedRecordSnapshot] {
        let models: [TelemetryLegacyImportedRecordV2]
        if let sourceID {
            models = try modelContext.fetch(
                FetchDescriptor(
                    predicate: #Predicate<TelemetryLegacyImportedRecordV2> {
                        $0.sourceID == sourceID
                    },
                    sortBy: [SortDescriptor(\.sourceRecordIndex)]
                )
            )
        } else {
            models = try modelContext.fetch(
                FetchDescriptor(sortBy: [SortDescriptor(\.importedRecordID)])
            )
        }
        return try models.map(importedRecordSnapshot)
    }

    public func fetchLegacyWorkoutCandidates() throws -> [LegacyWorkoutCandidateSnapshot] {
        let descriptor = FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
            sortBy: [SortDescriptor(\.candidateID)]
        )
        return try modelContext.fetch(descriptor).map(candidateSnapshot)
    }

    public func fetchLegacyImportedWorkouts(
        profileLocalIdentifier: String? = nil,
        includeUnassigned: Bool = true
    ) throws -> [LegacyImportedWorkoutSnapshot] {
        let models: [TelemetryLegacyImportedWorkoutV2]
        if let profileLocalIdentifier {
            models = try modelContext.fetch(
                FetchDescriptor(
                    predicate: #Predicate<TelemetryLegacyImportedWorkoutV2> {
                        $0.profileLocalIdentifier == profileLocalIdentifier
                    },
                    sortBy: [SortDescriptor(\.canonicalIdentityKey)]
                )
            )
        } else if !includeUnassigned {
            models = try modelContext.fetch(
                FetchDescriptor(
                    predicate: #Predicate<TelemetryLegacyImportedWorkoutV2> {
                        $0.profileLocalIdentifier != nil
                    },
                    sortBy: [SortDescriptor(\.canonicalIdentityKey)]
                )
            )
        } else {
            models = try modelContext.fetch(
                FetchDescriptor(sortBy: [SortDescriptor(\.canonicalIdentityKey)])
            )
        }
        return try models.map(importedWorkoutSnapshot)
    }

    public func fetchLegacyReconciliations() throws -> [LegacyReconciliationSnapshot] {
        let descriptor = FetchDescriptor<TelemetryLegacyReconciliationV2>(
            sortBy: [SortDescriptor(\.reconciliationID)]
        )
        return try modelContext.fetch(descriptor).map(reconciliationSnapshot)
    }

    @discardableResult
    func reconcileLegacyWorkoutCandidates(
        pageSize: Int = 64,
        maximumMatchesPerIdentity: Int = 64
    ) throws -> Int {
        let boundedPageSize = min(256, max(1, pageSize))
        let boundedMatchLimit = min(256, max(1, maximumMatchesPerIdentity))
        var offset = 0
        var insertedWorkoutCount = 0
        while true {
            var descriptor = FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
                sortBy: [SortDescriptor(\.candidateID)]
            )
            descriptor.fetchLimit = boundedPageSize
            descriptor.fetchOffset = offset
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }
            for candidate in page {
                insertedWorkoutCount += try reconcile(
                    candidate,
                    maximumMatches: boundedMatchLimit
                )
            }
            offset += page.count
        }
        return insertedWorkoutCount
    }

    private func reconcile(
        _ candidate: TelemetryLegacyWorkoutCandidateV2,
        maximumMatches: Int
    ) throws -> Int {
        let match = try strongestExactMatch(
            for: candidate,
            maximumMatches: maximumMatches
        )
        var compatible: [TelemetryLegacyWorkoutCandidateV2] = []
        var conflicting: [(TelemetryLegacyWorkoutCandidateV2, [String])] = []
        for other in match.candidates {
            let conflicts = identityConflicts(candidate, other)
            if conflicts.isEmpty {
                compatible.append(other)
            } else {
                conflicting.append((other, conflicts))
            }
        }

        let canonicalIdentityKey: String
        if !compatible.isEmpty, let kind = match.kind, let value = match.value {
            canonicalIdentityKey = exactCanonicalIdentityKey(
                kind: kind,
                value: value,
                candidates: [candidate] + compatible
            )
        } else if !conflicting.isEmpty {
            canonicalIdentityKey = "candidate:\(candidate.candidateID)"
        } else {
            canonicalIdentityKey = unreconciledIdentityKey(candidate)
        }
        let group = [candidate] + compatible
        let identityStatus: LegacyIdentityStatus = compatible.isEmpty && !conflicting.isEmpty
            ? .conflict
            : candidate.identityUncertain ? .uncertain : .exact
        let inserted = try upsertImportedWorkout(
            canonicalIdentityKey: canonicalIdentityKey,
            candidates: group,
            identityStatus: identityStatus,
            possibleDuplicate: candidate.possibleDuplicate && match.candidates.isEmpty
        )

        let importedWorkoutID = LegacyMigrationHashing.deterministicIdentifier(
            "legacy-imported-workout:\(canonicalIdentityKey)"
        )
        for other in compatible {
            try upsertReconciliation(
                left: candidate,
                right: other,
                outcome: .matched,
                kind: match.kind,
                value: match.value,
                importedWorkoutID: nil,
                detailCodes: []
            )
        }
        for (other, conflicts) in conflicting {
            try upsertReconciliation(
                left: candidate,
                right: other,
                outcome: .conflict,
                kind: match.kind,
                value: match.value,
                importedWorkoutID: importedWorkoutID,
                detailCodes: conflicts
            )
        }
        return inserted ? 1 : 0
    }

    private func strongestExactMatch(
        for candidate: TelemetryLegacyWorkoutCandidateV2,
        maximumMatches: Int
    ) throws -> (
        kind: LegacyReconciliationIdentityKind?,
        value: String?,
        candidates: [TelemetryLegacyWorkoutCandidateV2]
    ) {
        if let value = candidate.workoutIdentifier {
            let matches = try exactCandidates(
                excluding: candidate,
                kind: .workoutIdentifier,
                value: value,
                limit: maximumMatches
            )
            if !matches.isEmpty { return (.workoutIdentifier, value, matches) }
        }
        if let value = candidate.healthKitWorkoutIdentifier {
            let matches = try exactCandidates(
                excluding: candidate,
                kind: .healthKitWorkoutIdentifier,
                value: value,
                limit: maximumMatches
            )
            if !matches.isEmpty { return (.healthKitWorkoutIdentifier, value, matches) }
        }
        if let value = candidate.stableLegacySessionIdentifier {
            let matches = try exactCandidates(
                excluding: candidate,
                kind: .stableLegacySessionIdentifier,
                value: value,
                limit: maximumMatches
            )
            if !matches.isEmpty {
                return (.stableLegacySessionIdentifier, value, matches)
            }
        }
        return (nil, nil, [])
    }

    private func exactCandidates(
        excluding candidate: TelemetryLegacyWorkoutCandidateV2,
        kind: LegacyReconciliationIdentityKind,
        value: String,
        limit: Int
    ) throws -> [TelemetryLegacyWorkoutCandidateV2] {
        let oppositeOrigin = candidate.originKindKey == LegacyWorkoutCandidateOrigin.jsonl.rawValue
            ? LegacyWorkoutCandidateOrigin.workoutHistory.rawValue
            : LegacyWorkoutCandidateOrigin.jsonl.rawValue
        var result = try exactCandidates(
            excludingCandidateID: candidate.candidateID,
            kind: kind,
            value: value,
            originKindKey: oppositeOrigin,
            exactProfileLocalIdentifier: nil,
            limit: limit
        )
        if candidate.originKindKey == LegacyWorkoutCandidateOrigin.workoutHistory.rawValue,
           let profileLocalIdentifier = candidate.profileLocalIdentifier {
            result.append(contentsOf: try exactCandidates(
                excludingCandidateID: candidate.candidateID,
                kind: kind,
                value: value,
                originKindKey: LegacyWorkoutCandidateOrigin.workoutHistory.rawValue,
                exactProfileLocalIdentifier: profileLocalIdentifier,
                limit: limit
            ))
        }
        result.sort { $0.candidateID < $1.candidateID }
        guard result.count <= limit else {
            throw TelemetryStoreError.conflictingStableIdentity(
                "legacy-reconciliation-match-limit:\(kind.rawValue)"
            )
        }
        return result
    }

    private func exactCandidates(
        excludingCandidateID candidateID: String,
        kind: LegacyReconciliationIdentityKind,
        value: String,
        originKindKey: String,
        exactProfileLocalIdentifier: String?,
        limit: Int
    ) throws -> [TelemetryLegacyWorkoutCandidateV2] {
        var descriptor: FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>
        let requiresExactProfile = exactProfileLocalIdentifier != nil
        switch kind {
        case .workoutIdentifier:
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.candidateID != candidateID
                        && $0.originKindKey == originKindKey
                        && (!requiresExactProfile
                            || $0.profileLocalIdentifier == exactProfileLocalIdentifier)
                        && $0.workoutIdentifier == value
                },
                sortBy: [SortDescriptor(\.candidateID)]
            )
        case .healthKitWorkoutIdentifier:
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.candidateID != candidateID
                        && $0.originKindKey == originKindKey
                        && (!requiresExactProfile
                            || $0.profileLocalIdentifier == exactProfileLocalIdentifier)
                        && $0.healthKitWorkoutIdentifier == value
                },
                sortBy: [SortDescriptor(\.candidateID)]
            )
        case .stableLegacySessionIdentifier:
            descriptor = FetchDescriptor(
                predicate: #Predicate {
                    $0.candidateID != candidateID
                        && $0.originKindKey == originKindKey
                        && (!requiresExactProfile
                            || $0.profileLocalIdentifier == exactProfileLocalIdentifier)
                        && $0.stableLegacySessionIdentifier == value
                },
                sortBy: [SortDescriptor(\.candidateID)]
            )
        }
        descriptor.fetchLimit = limit + 1
        return try modelContext.fetch(descriptor)
    }

    private func exactCanonicalIdentityKey(
        kind: LegacyReconciliationIdentityKind,
        value: String,
        candidates: [TelemetryLegacyWorkoutCandidateV2]
    ) -> String {
        if let profileLocalIdentifier = candidates.first?.profileLocalIdentifier,
           candidates.allSatisfy({
               $0.profileLocalIdentifier == profileLocalIdentifier
           }) {
            return "history-profile:\(profileLocalIdentifier):\(kind.rawValue):\(value)"
        }
        return "\(kind.rawValue):\(value)"
    }

    private func identityConflicts(
        _ lhs: TelemetryLegacyWorkoutCandidateV2,
        _ rhs: TelemetryLegacyWorkoutCandidateV2
    ) -> [String] {
        var conflicts: [String] = []
        appendConflict(
            lhs.workoutIdentifier,
            rhs.workoutIdentifier,
            code: "conflicting-workout-identifier",
            into: &conflicts
        )
        appendConflict(
            lhs.healthKitWorkoutIdentifier,
            rhs.healthKitWorkoutIdentifier,
            code: "conflicting-healthkit-workout-identifier",
            into: &conflicts
        )
        appendConflict(
            lhs.stableLegacySessionIdentifier,
            rhs.stableLegacySessionIdentifier,
            code: "conflicting-stable-session-identifier",
            into: &conflicts
        )
        if lhs.profileLocalIdentifier != rhs.profileLocalIdentifier {
            conflicts.append("conflicting-profile-ownership")
        }
        return conflicts.sorted()
    }

    private func appendConflict(
        _ lhs: String?,
        _ rhs: String?,
        code: String,
        into conflicts: inout [String]
    ) {
        if let lhs, let rhs, lhs != rhs {
            conflicts.append(code)
        }
    }

    private func unreconciledIdentityKey(
        _ candidate: TelemetryLegacyWorkoutCandidateV2
    ) -> String {
        return "candidate:\(candidate.candidateID)"
    }

    private func upsertImportedWorkout(
        canonicalIdentityKey: String,
        candidates newCandidates: [TelemetryLegacyWorkoutCandidateV2],
        identityStatus: LegacyIdentityStatus,
        possibleDuplicate: Bool
    ) throws -> Bool {
        let importedWorkoutID = LegacyMigrationHashing.deterministicIdentifier(
            "legacy-imported-workout:\(canonicalIdentityKey)"
        )
        let existing = try importedWorkoutModel(canonicalIdentityKey)
        var candidateIDs = Set(newCandidates.map(\.candidateID))
        if let existing {
            candidateIDs.formUnion(
                try Self.decode([String].self, from: existing.candidateIDsPayload)
            )
        }
        var absorbedProvisionalWorkouts: [TelemetryLegacyImportedWorkoutV2] = []
        var absorbedImportedWorkoutIDs: Set<String> = []
        var pendingCandidateIDs = candidateIDs.sorted()
        var pendingIndex = 0
        while pendingIndex < pendingCandidateIDs.count {
            let candidateID = pendingCandidateIDs[pendingIndex]
            pendingIndex += 1
            let provisionalKey = "candidate:\(candidateID)"
            guard provisionalKey != canonicalIdentityKey,
                  let provisional = try importedWorkoutModel(provisionalKey),
                  absorbedImportedWorkoutIDs.insert(provisional.importedWorkoutID).inserted else {
                continue
            }
            absorbedProvisionalWorkouts.append(provisional)
            let provisionalCandidateIDs = try Self.decode(
                [String].self,
                from: provisional.candidateIDsPayload
            )
            for absorbedCandidateID in provisionalCandidateIDs
            where candidateIDs.insert(absorbedCandidateID).inserted {
                guard candidateIDs.count <= 256 else {
                    throw TelemetryStoreError.conflictingStableIdentity(
                        "legacy-imported-workout-candidate-limit"
                    )
                }
                pendingCandidateIDs.append(absorbedCandidateID)
            }
        }
        guard candidateIDs.count <= 256 else {
            throw TelemetryStoreError.conflictingStableIdentity(
                "legacy-imported-workout-candidate-limit"
            )
        }
        let candidates = try candidateIDs.sorted().compactMap(legacyCandidateModel)
        let resolved = try resolveSummary(candidates)
        let profiles = Set(candidates.compactMap(\.profileLocalIdentifier))
        let profile = profiles.count == 1 ? profiles.first : nil
        let hasIdentityConflict = profiles.count > 1
            || Set(candidates.compactMap(\.workoutIdentifier)).count > 1
            || Set(candidates.compactMap(\.healthKitWorkoutIdentifier)).count > 1
            || Set(candidates.compactMap(\.stableLegacySessionIdentifier)).count > 1
        let finalStatus: LegacyIdentityStatus
        if hasIdentityConflict || identityStatus == .conflict {
            finalStatus = .conflict
        } else if identityStatus == .uncertain || candidates.contains(where: \.identityUncertain) {
            finalStatus = .uncertain
        } else {
            finalStatus = .exact
        }
        let startedAt = candidates
            .filter { $0.originKindKey == LegacyWorkoutCandidateOrigin.jsonl.rawValue }
            .compactMap(\.startedAt)
            .min() ?? candidates.compactMap(\.startedAt).min()
        let endedAt = candidates
            .filter { $0.originKindKey == LegacyWorkoutCandidateOrigin.jsonl.rawValue }
            .compactMap(\.endedAt)
            .max() ?? candidates.compactMap(\.endedAt).max()
        let candidatePayload = try Self.encode(candidateIDs.sorted())
        let summaryPayload = try Self.encode(resolved)
        let retainedPossibleDuplicate = possibleDuplicate
            || absorbedProvisionalWorkouts.contains(where: \.possibleDuplicate)

        if let existing {
            try explicitTransaction {
                existing.profileLocalIdentifier = profile
                existing.startedAt = startedAt
                existing.endedAt = endedAt
                existing.identityStatusKey = finalStatus.rawValue
                existing.possibleDuplicate = existing.possibleDuplicate
                    || retainedPossibleDuplicate
                existing.adaptationQualityEligible = false
                existing.candidateIDsPayload = candidatePayload
                existing.resolvedSummaryPayload = summaryPayload
                for provisional in absorbedProvisionalWorkouts {
                    modelContext.delete(provisional)
                }
            }
            return false
        }
        try explicitTransaction {
            modelContext.insert(
                TelemetryLegacyImportedWorkoutV2(
                    importedWorkoutID: importedWorkoutID,
                    canonicalIdentityKey: canonicalIdentityKey,
                    profileLocalIdentifier: profile,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    identityStatusKey: finalStatus.rawValue,
                    possibleDuplicate: retainedPossibleDuplicate,
                    adaptationQualityEligible: false,
                    candidateIDsPayload: candidatePayload,
                    resolvedSummaryPayload: summaryPayload
                )
            )
            for provisional in absorbedProvisionalWorkouts {
                modelContext.delete(provisional)
            }
        }
        return absorbedProvisionalWorkouts.isEmpty
    }

    private func resolveSummary(
        _ candidates: [TelemetryLegacyWorkoutCandidateV2]
    ) throws -> LegacyResolvedWorkoutSummary {
        let summaries = try candidates.map { model in
            (
                origin: try requiredOrigin(model.originKindKey),
                summary: try Self.decode(
                    LegacyWorkoutCandidateSummary.self,
                    from: model.summaryPayload
                )
            )
        }
        let durationValues = summaries.flatMap { item -> [LegacySourcedValue<Int64>] in
            var values: [LegacySourcedValue<Int64>] = []
            if let value = item.summary.timestampDerivedDurationMicroseconds {
                values.append(.init(value: value, provenance: "legacy-jsonl-timestamp-derived"))
            }
            if let value = item.summary.legacySummaryDurationSeconds {
                values.append(
                    .init(
                        value: Int64(value) * 1_000_000,
                        provenance: item.origin == .jsonl
                            ? "legacy-jsonl-summary" : "workout_history_v1-summary"
                    )
                )
            }
            return values
        }
        let targetValues = summaries.compactMap { item in
            item.summary.targetBeatsPerMinute.map {
                LegacySourcedValue(
                    value: $0,
                    provenance: item.origin == .jsonl
                        ? "legacy-jsonl-timestamped-event"
                        : "workout_history_v1-summary"
                )
            }
        }
        let averageHeartRateValues = summaries.flatMap { item
            -> [LegacySourcedValue<Double>] in
            var values: [LegacySourcedValue<Double>] = []
            if let value = item.summary.timestampDerivedAverageHeartRateBeatsPerMinute {
                values.append(
                    .init(
                        value: value,
                        provenance: "legacy-jsonl-timestamp-derived"
                    )
                )
            }
            if let value = item.summary.legacySummaryAverageHeartRateBeatsPerMinute {
                values.append(
                    .init(
                        value: Double(value),
                        provenance: item.origin == .jsonl
                            ? "legacy-jsonl-summary"
                            : "workout_history_v1-summary"
                    )
                )
            }
            return values
        }
        let speedValues = summaries.compactMap { item in
            item.summary.legacyEstimatedAverageSpeedKilometresPerHour.map {
                LegacySourcedValue(
                    value: $0,
                    provenance: item.origin == .jsonl
                        ? "legacy-jsonl-estimated-summary"
                        : "workout_history_v1-estimated-summary"
                )
            }
        }
        let zoneValues = summaries.flatMap { item -> [LegacySourcedValue<[Int64?]>] in
            var values: [LegacySourcedValue<[Int64?]>] = []
            if let value = item.summary.timestampDerivedZoneMicroseconds {
                values.append(
                    .init(value: value, provenance: "legacy-jsonl-timestamp-derived")
                )
            }
            if let value = item.summary.legacySummaryZoneSeconds {
                values.append(
                    .init(
                        value: value.map { $0.map { Int64($0) * 1_000_000 } },
                        provenance: item.origin == .jsonl
                            ? "legacy-jsonl-summary" : "workout_history_v1-summary"
                    )
                )
            }
            return values
        }
        var conflicts = summaries.flatMap(\.summary.conflicts)
        var warnings = Set(summaries.flatMap(\.summary.warnings))
        let duration = resolvedValue(
            durationValues,
            preferredPrefixes: [
                "legacy-jsonl-timestamp-derived",
                "legacy-jsonl-summary",
            ]
        )
        let target = resolvedValue(targetValues, preferredPrefixes: ["legacy-jsonl"])
        let averageHR = resolvedValue(
            averageHeartRateValues,
            preferredPrefixes: [
                "legacy-jsonl-timestamp-derived",
                "legacy-jsonl-summary",
            ]
        )
        let speed = resolvedValue(speedValues, preferredPrefixes: ["legacy-jsonl"])
        let zones = resolvedValue(
            zoneValues,
            preferredPrefixes: ["legacy-jsonl-timestamp-derived"]
        )
        for (field, isConflict) in [
            ("duration", duration.conflict),
            ("target_bpm", target.conflict),
            ("average_hr_bpm", averageHR.conflict),
            ("estimated_average_speed_kmh", speed.conflict),
            ("zone_duration", zones.conflict),
        ] where isConflict {
            conflicts.append(
                LegacySummaryConflict(
                    field: field,
                    preferredProvenance: "legacy-jsonl-more-specific-when-present",
                    observedProvenances: []
                )
            )
            warnings.insert("conflicting-summary-\(field)")
        }
        return LegacyResolvedWorkoutSummary(
            durationMicroseconds: duration,
            targetBeatsPerMinute: target,
            averageHeartRateBeatsPerMinute: averageHR,
            estimatedAverageSpeedKilometresPerHour: speed,
            zoneMicroseconds: zones,
            warnings: warnings.sorted(),
            conflicts: Array(Set(conflicts)).sorted { $0.field < $1.field }
        )
    }

    private func resolvedValue<Value: Codable & Hashable & Sendable>(
        _ values: [LegacySourcedValue<Value>],
        preferredPrefixes: [String]
    ) -> LegacyResolvedValue<Value> {
        var distinct: [LegacySourcedValue<Value>] = []
        for value in values where !distinct.contains(value) {
            distinct.append(value)
        }
        let selected = preferredPrefixes.compactMap { preferredPrefix in
            distinct.first { $0.provenance.hasPrefix(preferredPrefix) }
        }.first
            ?? distinct.first
        let alternatives = distinct.filter { $0 != selected }
        let distinctValues = Set(distinct.map(\.value))
        return LegacyResolvedValue(
            selected: selected,
            alternatives: alternatives,
            conflict: distinctValues.count > 1
        )
    }

    private func upsertReconciliation(
        left: TelemetryLegacyWorkoutCandidateV2,
        right: TelemetryLegacyWorkoutCandidateV2,
        outcome: LegacyReconciliationOutcome,
        kind: LegacyReconciliationIdentityKind?,
        value: String?,
        importedWorkoutID: String?,
        detailCodes: [String]
    ) throws {
        let candidateIDs = [left.candidateID, right.candidateID].sorted()
        let key = candidateIDs.joined(separator: "|")
        let reconciliationID = LegacyMigrationHashing.deterministicIdentifier(
            "legacy-reconciliation:\(key)"
        )
        let details = try Self.encode(detailCodes.sorted())
        if let existing = try reconciliationModel(reconciliationID) {
            try explicitTransaction {
                existing.outcomeKey = outcome.rawValue
                existing.identityKindKey = kind?.rawValue
                existing.identityValue = value
                existing.importedWorkoutID = importedWorkoutID
                existing.detailPayload = details
            }
            return
        }
        try explicitTransaction {
            modelContext.insert(
                TelemetryLegacyReconciliationV2(
                    reconciliationID: reconciliationID,
                    leftCandidateID: candidateIDs[0],
                    rightCandidateID: candidateIDs[1],
                    outcomeKey: outcome.rawValue,
                    identityKindKey: kind?.rawValue,
                    identityValue: value,
                    importedWorkoutID: importedWorkoutID,
                    detailPayload: details
                )
            )
        }
    }

    private func legacySourceModel(
        _ sourceID: String
    ) throws -> TelemetryLegacyMigrationSourceV2? {
        var descriptor = FetchDescriptor<TelemetryLegacyMigrationSourceV2>(
            predicate: #Predicate { $0.sourceID == sourceID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func legacyImportedRecordModel(
        sourceItemIdentityKey: String
    ) throws -> TelemetryLegacyImportedRecordV2? {
        var descriptor = FetchDescriptor<TelemetryLegacyImportedRecordV2>(
            predicate: #Predicate { $0.sourceItemIdentityKey == sourceItemIdentityKey }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func legacyCandidateModel(
        _ candidateID: String
    ) throws -> TelemetryLegacyWorkoutCandidateV2? {
        var descriptor = FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
            predicate: #Predicate { $0.candidateID == candidateID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func importedWorkoutModel(
        _ canonicalIdentityKey: String
    ) throws -> TelemetryLegacyImportedWorkoutV2? {
        var descriptor = FetchDescriptor<TelemetryLegacyImportedWorkoutV2>(
            predicate: #Predicate { $0.canonicalIdentityKey == canonicalIdentityKey }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func reconciliationModel(
        _ reconciliationID: String
    ) throws -> TelemetryLegacyReconciliationV2? {
        var descriptor = FetchDescriptor<TelemetryLegacyReconciliationV2>(
            predicate: #Predicate { $0.reconciliationID == reconciliationID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func makeImportedRecordModel(
        _ draft: LegacyImportedRecordDraft
    ) throws -> TelemetryLegacyImportedRecordV2 {
        TelemetryLegacyImportedRecordV2(
            importedRecordID: draft.importedRecordID,
            sourceItemIdentityKey: draft.sourceItemIdentityKey,
            sourceID: draft.sourceID,
            candidateID: draft.candidateID,
            sourceRecordIndex: draft.sourceRecordIndex,
            sourceByteOffset: draft.sourceByteOffset,
            eventKind: draft.eventKind,
            occurredAt: draft.occurredAt,
            profileLocalIdentifier: draft.profileLocalIdentifier,
            workoutIdentifier: draft.workoutIdentifier,
            healthKitWorkoutIdentifier: draft.healthKitWorkoutIdentifier,
            stableLegacySessionIdentifier: draft.stableLegacySessionIdentifier,
            provenanceKey: draft.provenanceKey,
            normalizedPayload: try Self.encode(draft.payload),
            identityUncertain: draft.identityUncertain,
            adaptationQualityEligible: false
        )
    }

    private func makeCandidateModel(
        _ draft: LegacyWorkoutCandidateDraft
    ) throws -> TelemetryLegacyWorkoutCandidateV2 {
        TelemetryLegacyWorkoutCandidateV2(
            candidateID: draft.candidateID,
            sourceItemIdentityKey: draft.sourceItemIdentityKey,
            sourceID: draft.sourceID,
            originKindKey: draft.origin.rawValue,
            profileLocalIdentifier: draft.profileLocalIdentifier,
            workoutIdentifier: draft.workoutIdentifier,
            healthKitWorkoutIdentifier: draft.healthKitWorkoutIdentifier,
            stableLegacySessionIdentifier: draft.stableLegacySessionIdentifier,
            startedAt: draft.startedAt,
            endedAt: draft.endedAt,
            identityUncertain: draft.identityUncertain,
            possibleDuplicate: draft.possibleDuplicate,
            summaryPayload: try Self.encode(draft.summary)
        )
    }

    private func storedRecordMatches(
        _ model: TelemetryLegacyImportedRecordV2,
        draft: LegacyImportedRecordDraft
    ) throws -> Bool {
        let payload = try Self.decode(
            LegacyImportedRecordPayload.self,
            from: model.normalizedPayload
        )
        return model.importedRecordID == draft.importedRecordID
            && model.sourceItemIdentityKey == draft.sourceItemIdentityKey
            && model.sourceID == draft.sourceID
            && model.candidateID == draft.candidateID
            && model.sourceRecordIndex == draft.sourceRecordIndex
            && model.sourceByteOffset == draft.sourceByteOffset
            && model.eventKind == draft.eventKind
            && model.occurredAt == draft.occurredAt
            && model.profileLocalIdentifier == draft.profileLocalIdentifier
            && model.workoutIdentifier == draft.workoutIdentifier
            && model.healthKitWorkoutIdentifier == draft.healthKitWorkoutIdentifier
            && model.stableLegacySessionIdentifier == draft.stableLegacySessionIdentifier
            && model.provenanceKey == draft.provenanceKey
            && model.identityUncertain == draft.identityUncertain
            && !model.adaptationQualityEligible
            && payload == draft.payload
    }

    private func storedCandidateMatches(
        _ model: TelemetryLegacyWorkoutCandidateV2,
        draft: LegacyWorkoutCandidateDraft
    ) throws -> Bool {
        let summary = try Self.decode(
            LegacyWorkoutCandidateSummary.self,
            from: model.summaryPayload
        )
        return model.sourceItemIdentityKey == draft.sourceItemIdentityKey
            && model.sourceID == draft.sourceID
            && model.originKindKey == draft.origin.rawValue
            && model.profileLocalIdentifier == draft.profileLocalIdentifier
            && model.workoutIdentifier == draft.workoutIdentifier
            && model.healthKitWorkoutIdentifier == draft.healthKitWorkoutIdentifier
            && model.stableLegacySessionIdentifier == draft.stableLegacySessionIdentifier
            && model.startedAt == draft.startedAt
            && model.endedAt == draft.endedAt
            && model.identityUncertain == draft.identityUncertain
            && model.possibleDuplicate == draft.possibleDuplicate
            && summary == draft.summary
    }

    private func sourceProgress(
        _ model: TelemetryLegacyMigrationSourceV2
    ) throws -> LegacyMigrationSourceProgress {
        LegacyMigrationSourceProgress(
            snapshot: try sourceSnapshot(model),
            aggregateStatePayload: model.aggregateStatePayload
        )
    }

    private func sourceSnapshot(
        _ model: TelemetryLegacyMigrationSourceV2
    ) throws -> LegacyMigrationSourceSnapshot {
        guard let kind = LegacyMigrationSourceKind(rawValue: model.sourceKindKey),
              let status = LegacyMigrationSourceStatus(rawValue: model.statusKey) else {
            throw TelemetryStoreError.corruptStoredRecord(model.sourceID)
        }
        return LegacyMigrationSourceSnapshot(
            sourceID: model.sourceID,
            kind: kind,
            contentHashDigest: model.contentHashDigest,
            importerVersion: model.importerVersion,
            locator: model.locator,
            exactProfileLocalIdentifier: model.exactProfileLocalIdentifier,
            status: status,
            checkpointByteOffset: model.checkpointByteOffset,
            checkpointRecordIndex: model.checkpointRecordIndex,
            parsedRecordCount: model.parsedRecordCount,
            malformedRecordCount: model.malformedRecordCount,
            warningCount: model.warningCount,
            errorCode: model.errorCode,
            errorDetail: model.errorDetail
        )
    }

    private func importedRecordSnapshot(
        _ model: TelemetryLegacyImportedRecordV2
    ) throws -> LegacyImportedRecordSnapshot {
        LegacyImportedRecordSnapshot(
            importedRecordID: model.importedRecordID,
            sourceID: model.sourceID,
            candidateID: model.candidateID,
            sourceRecordIndex: model.sourceRecordIndex,
            eventKind: model.eventKind,
            occurredAt: model.occurredAt,
            profileLocalIdentifier: model.profileLocalIdentifier,
            workoutIdentifier: model.workoutIdentifier,
            healthKitWorkoutIdentifier: model.healthKitWorkoutIdentifier,
            stableLegacySessionIdentifier: model.stableLegacySessionIdentifier,
            payload: try Self.decode(
                LegacyImportedRecordPayload.self,
                from: model.normalizedPayload
            ),
            identityUncertain: model.identityUncertain,
            adaptationQualityEligible: model.adaptationQualityEligible
        )
    }

    private func candidateSnapshot(
        _ model: TelemetryLegacyWorkoutCandidateV2
    ) throws -> LegacyWorkoutCandidateSnapshot {
        LegacyWorkoutCandidateSnapshot(
            candidateID: model.candidateID,
            sourceID: model.sourceID,
            origin: try requiredOrigin(model.originKindKey),
            profileLocalIdentifier: model.profileLocalIdentifier,
            workoutIdentifier: model.workoutIdentifier,
            healthKitWorkoutIdentifier: model.healthKitWorkoutIdentifier,
            stableLegacySessionIdentifier: model.stableLegacySessionIdentifier,
            startedAt: model.startedAt,
            endedAt: model.endedAt,
            identityUncertain: model.identityUncertain,
            possibleDuplicate: model.possibleDuplicate,
            summary: try Self.decode(
                LegacyWorkoutCandidateSummary.self,
                from: model.summaryPayload
            )
        )
    }

    private func importedWorkoutSnapshot(
        _ model: TelemetryLegacyImportedWorkoutV2
    ) throws -> LegacyImportedWorkoutSnapshot {
        guard let status = LegacyIdentityStatus(rawValue: model.identityStatusKey) else {
            throw TelemetryStoreError.corruptStoredRecord(model.importedWorkoutID)
        }
        return LegacyImportedWorkoutSnapshot(
            importedWorkoutID: model.importedWorkoutID,
            canonicalIdentityKey: model.canonicalIdentityKey,
            profileLocalIdentifier: model.profileLocalIdentifier,
            startedAt: model.startedAt,
            endedAt: model.endedAt,
            identityStatus: status,
            possibleDuplicate: model.possibleDuplicate,
            adaptationQualityEligible: model.adaptationQualityEligible,
            candidateIDs: try Self.decode([String].self, from: model.candidateIDsPayload),
            resolvedSummary: try Self.decode(
                LegacyResolvedWorkoutSummary.self,
                from: model.resolvedSummaryPayload
            )
        )
    }

    private func reconciliationSnapshot(
        _ model: TelemetryLegacyReconciliationV2
    ) throws -> LegacyReconciliationSnapshot {
        guard let outcome = LegacyReconciliationOutcome(rawValue: model.outcomeKey) else {
            throw TelemetryStoreError.corruptStoredRecord(model.reconciliationID)
        }
        return LegacyReconciliationSnapshot(
            reconciliationID: model.reconciliationID,
            leftCandidateID: model.leftCandidateID,
            rightCandidateID: model.rightCandidateID,
            outcome: outcome,
            identityKind: model.identityKindKey.flatMap(
                LegacyReconciliationIdentityKind.init(rawValue:)
            ),
            identityValue: model.identityValue,
            importedWorkoutID: model.importedWorkoutID,
            detailCodes: try Self.decode([String].self, from: model.detailPayload)
        )
    }

    private func requiredOrigin(_ value: String) throws -> LegacyWorkoutCandidateOrigin {
        guard let origin = LegacyWorkoutCandidateOrigin(rawValue: value) else {
            throw TelemetryStoreError.corruptStoredRecord(value)
        }
        return origin
    }
}
