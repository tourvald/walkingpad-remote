// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WalkingPadRemoteCoreLogic",
    // SwiftData #Index requires macOS 15; tools and language mode remain unchanged.
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "WalkingPadCoreLogic",
            targets: ["WalkingPadCoreLogic"]
        ),
        .library(
            name: "TelemetryDomain",
            targets: ["TelemetryDomain"]
        ),
        .library(
            name: "TelemetryRecorder",
            targets: ["TelemetryRecorder"]
        ),
        .library(
            name: "TelemetryPersistence",
            targets: ["TelemetryPersistence"]
        ),
        .library(
            name: "TelemetryRuntime",
            targets: ["TelemetryRuntime"]
        )
    ],
    targets: [
        .target(
            name: "TelemetryDomain"
        ),
        .target(
            name: "TelemetryRecorder",
            dependencies: ["TelemetryDomain"]
        ),
        .target(
            name: "TelemetryPersistence",
            dependencies: ["TelemetryDomain", "TelemetryRecorder"]
        ),
        .target(
            name: "TelemetryRuntime",
            dependencies: ["TelemetryDomain", "TelemetryRecorder"]
        ),
        .executableTarget(
            name: "TelemetryGateCrashWorker",
            dependencies: ["TelemetryDomain", "TelemetryPersistence"]
        ),
        .target(
            name: "WalkingPadCoreLogic",
            dependencies: ["TelemetryDomain"],
            path: "WalkingPadRemote",
            exclude: [
                "Assets.xcassets",
                "BluetoothManager.swift",
                "CommonInfoCard.swift",
                "ContentSharedUIComponents.swift",
                "ContentView.swift",
                "DebugHrFailuresCard.swift",
                "DebugStopTruthExperimentCard.swift",
                "DebugSharedUIComponents.swift",
                "DebugTrainingLogsCard.swift",
                "DevicePickerView.swift",
                "PlankTimerView.swift",
                "StatsRightAlignedBlock.swift",
                "StatusPillsRow.swift",
                "WalkingPadRemote.entitlements",
                "WalkingPadRemoteApp.swift"
            ],
            sources: [
                "BLETransportCodec.swift",
                "ControllerUnitsSafetyPolicy.swift",
                "CooldownRuntimeEngine.swift",
                "HRDomainService.swift",
                "HRSettingsDefaults.swift",
                "StopObservationService.swift",
                "StopTruthExperimentBuildIdentity.swift",
                "StopTruthExperimentClock.swift",
                "StopTruthExperimentController.swift",
                "StopTruthExperimentEvidence.swift",
                "StopTruthExperimentExecutor.swift",
                "StopTruthExperimentObservationService.swift",
                "StopTruthExperimentPlanService.swift",
                "StopTruthExperimentSessionService.swift",
                "TreadmillTestRunService.swift",
                "TrainingTelemetryWriter.swift",
                "CommandQueueService.swift",
                "TreadmillSpeedBoundsService.swift",
                "TreadmillCommandTelemetrySidecar.swift"
            ]
        ),
        .testTarget(
            name: "WalkingPadCoreLogicTests",
            dependencies: ["WalkingPadCoreLogic"],
            path: "WalkingPadRemoteCoreTests"
        ),
        .testTarget(
            name: "TelemetryDomainTests",
            dependencies: ["TelemetryDomain"]
        ),
        .testTarget(
            name: "TelemetryRecorderTests",
            dependencies: ["TelemetryDomain", "TelemetryRecorder"]
        ),
        .testTarget(
            name: "TelemetryRuntimeTests",
            dependencies: ["TelemetryDomain", "TelemetryRecorder", "TelemetryRuntime"]
        ),
        .testTarget(
            name: "TelemetryPersistenceTests",
            dependencies: ["TelemetryDomain", "TelemetryRecorder", "TelemetryPersistence"]
        ),
        .testTarget(
            name: "TelemetrySwiftDataGateTests",
            dependencies: [
                "TelemetryDomain",
                "TelemetryPersistence",
                "TelemetryGateCrashWorker",
            ]
        )
    ]
)
