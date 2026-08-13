import Foundation

struct StopTruthExperimentBuildIdentity: Equatable {
    static let requiredCapability = "issue14-stop-truth-v1"
    static let executableBindingPrefix = "-issue14-stop-truth-v1-e"

    let capabilityCompiled: Bool
    let capabilityBinding: String?
    let expectedGitSHA: String?
    let actualGitSHA: String?
    let bundleIdentifier: String?
    let version: String?
    let build: String?

    var isEnabled: Bool {
        guard capabilityCompiled,
              capabilityBinding == Self.requiredCapability,
              let expectedGitSHA,
              let actualGitSHA,
              Self.isExactGitSHA(expectedGitSHA),
              expectedGitSHA == actualGitSHA else {
            return false
        }
        return true
    }

    static func current(bundle: Bundle = .main) -> StopTruthExperimentBuildIdentity {
#if STOP_TRUTH_EXPERIMENT_CAPABILITY
        let compiled = true
#else
        let compiled = false
#endif
        let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        let binding = executable.flatMap(parseExecutableBinding)
        return StopTruthExperimentBuildIdentity(
            capabilityCompiled: compiled,
            capabilityBinding: binding == nil ? nil : requiredCapability,
            expectedGitSHA: binding?.expected,
            actualGitSHA: binding?.actual,
            bundleIdentifier: bundle.bundleIdentifier,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    nonisolated static func parseExecutableBinding(_ executable: String) -> (expected: String, actual: String)? {
        let pattern = "-issue14-stop-truth-v1-e([0-9a-f]{40})-a([0-9a-f]{40})$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: executable,
                range: NSRange(executable.startIndex..., in: executable)
              ),
              match.numberOfRanges == 3,
              let expectedRange = Range(match.range(at: 1), in: executable),
              let actualRange = Range(match.range(at: 2), in: executable) else {
            return nil
        }
        return (String(executable[expectedRange]), String(executable[actualRange]))
    }

    private static func isExactGitSHA(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }
}
