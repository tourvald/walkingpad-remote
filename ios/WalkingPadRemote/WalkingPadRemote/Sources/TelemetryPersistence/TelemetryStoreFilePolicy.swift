import Foundation

public enum TelemetryStoreLocation {
    public static func applicationSupportStoreURL(
        appIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return applicationSupport
            .appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("TelemetryV2", isDirectory: true)
            .appendingPathComponent("TelemetryV2.store", isDirectory: false)
    }
}

public struct TelemetryStoreFilePolicyResult: Sendable, Equatable {
    public let protectedURLs: [URL]
    public let deviceVerificationRequired: Bool

    public init(protectedURLs: [URL], deviceVerificationRequired: Bool) {
        self.protectedURLs = protectedURLs
        self.deviceVerificationRequired = deviceVerificationRequired
    }
}

public enum TelemetryStoreFilePolicy {
    public static func discoveredStoreFiles(
        primaryStoreURL: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let directory = primaryStoreURL.deletingLastPathComponent()
        let primaryName = primaryStoreURL.lastPathComponent
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { url in
                let name = url.lastPathComponent
                return name == primaryName
                    || name.hasPrefix(primaryName + "-")
                    || name.hasPrefix(primaryName + ".")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func applyRequiredAttributes(
        primaryStoreURL: URL,
        fileManager: FileManager = .default
    ) throws -> TelemetryStoreFilePolicyResult {
        let discovered = try discoveredStoreFiles(
            primaryStoreURL: primaryStoreURL,
            fileManager: fileManager
        )
        for url in discovered {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            // Apply backup exclusion last because other file-attribute updates may reset it.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
        return TelemetryStoreFilePolicyResult(
            protectedURLs: discovered,
            deviceVerificationRequired: true
        )
    }
}
