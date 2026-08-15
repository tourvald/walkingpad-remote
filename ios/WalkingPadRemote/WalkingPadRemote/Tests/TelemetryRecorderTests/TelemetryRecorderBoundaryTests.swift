import Foundation
import XCTest

final class TelemetryRecorderBoundaryTests: XCTestCase {
    func testRecorderTargetHasNoSwiftDataOrPersistenceHotPathDependency() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recorderDirectory = root.appendingPathComponent("Sources/TelemetryRecorder")
        let sources = try swiftSources(in: recorderDirectory)

        XCTAssertFalse(sources.contains("import SwiftData"))
        XCTAssertFalse(sources.contains("ModelContext"))
        XCTAssertFalse(sources.contains("JSONEncoder"))
        XCTAssertFalse(sources.contains("JSONDecoder"))
        XCTAssertFalse(sources.contains("UserDefaults"))
        XCTAssertFalse(sources.contains("FileManager"))
    }

    func testProducerFacingYieldContainsNoTaskAwaitOrSlowWork() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recorder = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/TelemetryRecorder/TelemetryRecorder.swift"
            ),
            encoding: .utf8
        )
        let ingressStart = try XCTUnwrap(recorder.range(of: "public final class TelemetryIngress"))
        let recorderStart = try XCTUnwrap(recorder.range(of: "public final class TelemetryRecorder"))
        let ingress = recorder[ingressStart.lowerBound..<recorderStart.lowerBound]

        for forbidden in [
            "Task", "await", "SwiftData", "ModelContext", "JSON", "FileManager",
            "UserDefaults", "URLSession", "removeFirst", ".sorted(",
        ] {
            XCTAssertFalse(ingress.contains(forbidden), "Ingress contains forbidden \(forbidden)")
        }
        XCTAssertEqual(recorder.components(separatedBy: "Task.detached").count - 1, 1)
    }

    func testProductionApplicationSourcesDoNotWireRecorder() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtimeSources = try swiftSources(in: root.appendingPathComponent("WalkingPadRemote"))

        XCTAssertFalse(runtimeSources.contains("import TelemetryRecorder"))
        XCTAssertFalse(runtimeSources.contains("TelemetryIngress"))
        XCTAssertFalse(runtimeSources.contains("TelemetryRecorder("))
        XCTAssertFalse(runtimeSources.contains("TelemetryStoreFactory.make"))
    }

    func testPackageDependencyDirectionKeepsRecorderAboveDomainAndBelowPersistence() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains(
                ".target(\n            name: \"TelemetryRecorder\",\n            dependencies: [\"TelemetryDomain\"]"
            )
        )
        XCTAssertTrue(
            manifest.contains(
                "name: \"TelemetryPersistence\",\n            dependencies: [\"TelemetryDomain\", \"TelemetryRecorder\"]"
            )
        )
        XCTAssertFalse(manifest.contains("name: \"TelemetryRecorder\",\n            dependencies: [\"TelemetryPersistence\"]"))
    }

    func testPersistenceAdapterIsNotMainActorBound() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/TelemetryPersistence/TelemetryStore.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("@ModelActor\npublic actor TelemetryStore"))
        XCTAssertTrue(store.contains("extension TelemetryStore: TelemetryRecorderPersistence"))
        XCTAssertFalse(store.contains("@MainActor\nextension TelemetryStore: TelemetryRecorderPersistence"))
    }

    private func swiftSources(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var result = ""
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else {
                continue
            }
            result += try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }
}
