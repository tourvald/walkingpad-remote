import Foundation
import SwiftData
import TelemetryDomain

public enum ProfileErasureError: Error, Equatable {
    case busy
    case ambiguousOwnership(String)
    case erasedProfile
}

struct ProfileErasureJournal: Codable {
    var profiles: Set<String> = []
    var legacySources: Set<String> = []
}

extension TelemetryStore: TelemetryProfileErasureCapability {
    // A minimal durable denylist prevents stale asynchronous import/session work
    // from restoring erased UUIDs. It deliberately contains no workout or label.
    private func erasureJournal() throws -> ProfileErasureJournal {
        guard let url = erasureJournalURL,
              FileManager.default.fileExists(atPath: url.path) else { return memoryErasureJournal }
        return try JSONDecoder().decode(ProfileErasureJournal.self, from: Data(contentsOf: url))
    }

    public func erasedProfileIdentifiers() throws -> Set<String> {
        try erasureJournal().profiles
    }

    func requireWritableLegacySource(_ sourceID: String) throws {
        guard try !erasureJournal().legacySources.contains(sourceID) else {
            throw ProfileErasureError.erasedProfile
        }
    }

    func requireWritableProfile(_ identifier: String) throws {
        guard try !erasedProfileIdentifiers().contains(identifier.lowercased()) else {
            throw ProfileErasureError.erasedProfile
        }
    }

    private var erasureJournalURL: URL? {
        onDiskErasureStoreURL?.appendingPathExtension("erased-profiles.json")
    }

    private func recordErasure(_ identifier: String, sourceIDs: Set<String>) throws {
        var erased = try erasureJournal()
        erased.profiles.insert(identifier.lowercased())
        erased.legacySources.formUnion(sourceIDs)
        if let url = erasureJournalURL {
            try JSONEncoder().encode(erased).write(to: url, options: .atomic)
            if let storeURL = onDiskErasureStoreURL {
                _ = try TelemetryStoreFilePolicy.applyRequiredAttributes(primaryStoreURL: storeURL)
            }
        } else {
            memoryErasureJournal = erased
        }
    }

    public func eraseProfile(
        _ identifier: String,
        legacyFallback: String?,
        logsDirectory: URL?,
        temporaryDirectory: URL
    ) throws {
        try eraseProfile(identifier, legacyFallback: legacyFallback, logsDirectory: logsDirectory,
                         temporaryDirectory: temporaryDirectory, afterJournalForTesting: nil)
    }

    func eraseProfile(
        _ identifier: String, legacyFallback: String?, logsDirectory: URL?, temporaryDirectory: URL,
        afterJournalForTesting: (() throws -> Void)?
    ) throws {
        guard activeProfileExports == 0 else { throw ProfileErasureError.busy }
        let profile = identifier.lowercased()
        let sessions = try modelContext.fetch(FetchDescriptor<TelemetryWorkoutSessionV1>())
        let ownedSessions = sessions.filter { $0.profileLocalIdentifier.lowercased() == profile }
        guard !ownedSessions.contains(where: { ["created", "running", "paused"].contains($0.lifecycleStateKey) }) else {
            throw ProfileErasureError.busy
        }
        let ownedRecords = try modelContext.fetch(FetchDescriptor<TelemetryLegacyImportedRecordV2>(
            predicate: #Predicate { $0.profileLocalIdentifier == identifier || $0.profileLocalIdentifier == profile }
        ))
        let ownedCandidates = try modelContext.fetch(FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
            predicate: #Predicate { $0.profileLocalIdentifier == identifier || $0.profileLocalIdentifier == profile }
        ))
        let sourceIDs = Set(ownedRecords.map(\.sourceID) + ownedCandidates.map(\.sourceID))
        for sourceID in sourceIDs {
            let otherRecords = try modelContext.fetchCount(FetchDescriptor<TelemetryLegacyImportedRecordV2>(
                predicate: #Predicate { $0.sourceID == sourceID && $0.profileLocalIdentifier != identifier && $0.profileLocalIdentifier != profile }
            ))
            let otherCandidates = try modelContext.fetchCount(FetchDescriptor<TelemetryLegacyWorkoutCandidateV2>(
                predicate: #Predicate { $0.sourceID == sourceID && $0.profileLocalIdentifier != identifier && $0.profileLocalIdentifier != profile }
            ))
            guard otherRecords == 0, otherCandidates == 0 else {
                throw ProfileErasureError.ambiguousOwnership("mixed-legacy-source")
            }
        }
        let candidateIDs = Set(ownedCandidates.map(\.candidateID))
        let imported = try modelContext.fetch(FetchDescriptor<TelemetryLegacyImportedWorkoutV2>())
        let ownedImported = try imported.filter { workout in
            let ids = Set(try Self.decode([String].self, from: workout.candidateIDsPayload))
            let owned = workout.profileLocalIdentifier?.lowercased() == profile
            if !ids.isDisjoint(with: candidateIDs), !owned {
                throw ProfileErasureError.ambiguousOwnership("mixed-legacy-workout")
            }
            return owned
        }
        let files = try ProfileErasureFiles.ownedFiles(
            profile: profile, legacyFallback: legacyFallback?.lowercased(),
            logsDirectory: logsDirectory, temporaryDirectory: temporaryDirectory
        )
        let migrations = try modelContext.fetch(FetchDescriptor<TelemetryLegacyMigrationSourceV2>())
        let ownedLogPaths = Set(files.filter { $0.pathExtension.lowercased() == "jsonl" }.map { $0.standardizedFileURL.path })
        let erasedSourceIDs = sourceIDs.union(migrations.filter {
            ownedLogPaths.contains($0.locator)
                || ($0.sourceKindKey == LegacyMigrationSourceKind.workoutHistory.rawValue
                    && $0.exactProfileLocalIdentifier?.lowercased() == profile)
        }.map(\.sourceID))
        try recordErasure(profile, sourceIDs: erasedSourceIDs)
        try afterJournalForTesting?()
        for file in files { try FileManager.default.removeItem(at: file) }
        let configurationIDs = Set(ownedSessions.compactMap { $0.configuration?.snapshotID })
        let sources = try modelContext.fetch(FetchDescriptor<TelemetrySignalSourceV1>())
        var orphanedSources: [TelemetrySignalSourceV1] = []
        for source in sources {
            if try sourceIsReferenced(source.sourceID, profile: identifier, alternate: profile, excluding: false),
               try !sourceIsReferenced(source.sourceID, profile: identifier, alternate: profile, excluding: true) {
                orphanedSources.append(source)
            }
        }
        let reconciliations = try modelContext.fetch(FetchDescriptor<TelemetryLegacyReconciliationV2>())
        let ownedImportedIDs = Set(ownedImported.map(\.importedWorkoutID))
        try explicitTransaction {
            for session in ownedSessions { modelContext.delete(session) }
            for record in ownedRecords { modelContext.delete(record) }
            for candidate in ownedCandidates { modelContext.delete(candidate) }
            for workout in ownedImported { modelContext.delete(workout) }
            for row in reconciliations where candidateIDs.contains(row.leftCandidateID)
                || candidateIDs.contains(row.rightCandidateID)
                || row.importedWorkoutID.map(ownedImportedIDs.contains) == true {
                modelContext.delete(row)
            }
            for source in migrations where erasedSourceIDs.contains(source.sourceID) {
                modelContext.delete(source)
            }
            let retained = sessions.filter { $0.profileLocalIdentifier.lowercased() != profile }
            let retainedConfigurations = Set(retained.compactMap { $0.configuration?.snapshotID })
            for config in try modelContext.fetch(FetchDescriptor<TelemetryConfigurationSnapshotV1>())
                where configurationIDs.contains(config.snapshotID) && !retainedConfigurations.contains(config.snapshotID) {
                modelContext.delete(config)
            }
            for source in orphanedSources { modelContext.delete(source) }
        }
    }

    private func sourceIsReferenced(_ key: String, profile: String, alternate: String, excluding: Bool) throws -> Bool {
        let heart = FetchDescriptor<TelemetryHeartRateSampleV1>(predicate: #Predicate {
            $0.sourceID == key && ((excluding && $0.session?.profileLocalIdentifier != profile && $0.session?.profileLocalIdentifier != alternate)
                || (!excluding && ($0.session?.profileLocalIdentifier == profile || $0.session?.profileLocalIdentifier == alternate)))
        })
        if try modelContext.fetchCount(heart) > 0 { return true }
        let treadmill = FetchDescriptor<TelemetryTreadmillSampleV1>(predicate: #Predicate {
            $0.sourceID == key && ((excluding && $0.session?.profileLocalIdentifier != profile && $0.session?.profileLocalIdentifier != alternate)
                || (!excluding && ($0.session?.profileLocalIdentifier == profile || $0.session?.profileLocalIdentifier == alternate)))
        })
        if try modelContext.fetchCount(treadmill) > 0 { return true }
        let events = FetchDescriptor<TelemetryWorkoutEventV1>(predicate: #Predicate {
            $0.sourceID == key && ((excluding && $0.session?.profileLocalIdentifier != profile && $0.session?.profileLocalIdentifier != alternate)
                || (!excluding && ($0.session?.profileLocalIdentifier == profile || $0.session?.profileLocalIdentifier == alternate)))
        })
        return try modelContext.fetchCount(events) > 0
    }

}

/// File ownership is checked before any erasure; uncertain or mixed artifacts
/// remain intact and prevent a false complete-success result.
public enum ProfileErasureFiles {
    static let ownerFileName = ".profile-owner.json"

    public static func mark(_ directory: URL, profiles: Set<String>) throws {
        try JSONEncoder().encode(Set(profiles.map { $0.lowercased() }))
            .write(to: directory.appendingPathComponent(ownerFileName), options: .atomic)
    }

    static func ownedFiles(profile: String, legacyFallback: String?, logsDirectory: URL?, temporaryDirectory: URL) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        if let logsDirectory, fm.fileExists(atPath: logsDirectory.path) {
            for file in try fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                where file.pathExtension.lowercased() == "jsonl" {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw ProfileErasureError.ambiguousOwnership(file.lastPathComponent)
                }
                let reader = try LegacyJSONLLineReader(url: file, startingAt: 0, nextRecordIndex: 0)
                var owners = Set<String>()
                while let element = try reader.next() {
                    guard let data = element.data else { throw ProfileErasureError.ambiguousOwnership(file.lastPathComponent) }
                    if data.allSatisfy({ $0 == 13 || $0 == 32 }) { continue }
                    guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw ProfileErasureError.ambiguousOwnership(file.lastPathComponent)
                    }
                    let explicit = LegacyTelemetryMigrationParser.explicitProfileIdentifiers(in: row)
                    guard explicit.count <= 1,
                          !(explicit.isEmpty && LegacyTelemetryMigrationParser.profileIdentifierKeys.contains(where: { row[$0] != nil })),
                          let owner = LegacyTelemetryMigrationParser.explicitProfileIdentifier(in: row) ?? legacyFallback else {
                        throw ProfileErasureError.ambiguousOwnership(file.lastPathComponent)
                    }
                    owners.insert(owner.lowercased())
                }
                if owners.contains(profile) {
                    guard owners == [profile] else { throw ProfileErasureError.ambiguousOwnership(file.lastPathComponent) }
                    result.append(file)
                } else if owners.isEmpty, legacyFallback == profile {
                    result.append(file)
                }
            }
        }
        for file in try fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            let directory = ["TelemetryV2Export_", "WorkoutAnalysisExport_", "WalkingPadSupportExport_"].contains { name.hasPrefix($0) }
            let legacy = ["Training_History_", "Training_Summary_", "Training_Session_Summary_", "WalkingPad_Diagnostics_", "HR_Failures_"].contains { name.hasPrefix($0) }
            guard directory || legacy else { continue }
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ProfileErasureError.ambiguousOwnership(name)
            }
            guard directory else { throw ProfileErasureError.ambiguousOwnership(name) }
            let marker = file.appendingPathComponent(ownerFileName)
            guard fm.fileExists(atPath: marker.path) else { throw ProfileErasureError.ambiguousOwnership(name) }
            let owners = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: marker))
            guard !owners.isEmpty, !owners.contains("*") else { throw ProfileErasureError.ambiguousOwnership(name) }
            if owners.contains(profile) {
                guard owners == [profile] else { throw ProfileErasureError.ambiguousOwnership(name) }
                result.append(file)
            }
        }
        return result
    }
}

/// Existing profile preference keys share the same stable legacy owner as imports.
public enum ProfileErasureSettings {
    private static let keys = ["hr_settings_v1", "zone_plan_v1", "workout_history_v1"]

    @discardableResult
    public static func migrateLegacySettings(userDefaults: UserDefaults, profileID: String, legacyFallback: String?, erasedProfiles: Set<String>) -> Bool {
        let profile = profileID.lowercased()
        guard legacyFallback?.lowercased() == profile, !erasedProfiles.contains(profile) else { return false }
        var changed = false
        for key in keys.prefix(2) {
            let scoped = "\(key)_profile_\(profile)"
            if userDefaults.object(forKey: scoped) == nil, let value = userDefaults.object(forKey: key) {
                userDefaults.set(value, forKey: scoped)
                changed = true
            }
        }
        return changed
    }

    public static func removeProfileSettings(userDefaults: UserDefaults, profileID: String, legacyFallback: String?) {
        for key in keys {
            for variant in Set([profileID, profileID.lowercased()]) {
                userDefaults.removeObject(forKey: "\(key)_profile_\(variant)")
            }
            if legacyFallback?.lowercased() == profileID.lowercased() { userDefaults.removeObject(forKey: key) }
        }
    }
}
