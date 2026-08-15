// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WalkingPadRemoteCoreLogic",
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
            name: "TelemetryPersistence",
            targets: ["TelemetryPersistence"]
        )
    ],
    targets: [
        .target(
            name: "TelemetryDomain"
        ),
        .target(
            name: "TelemetryPersistence",
            dependencies: ["TelemetryDomain"]
        ),
        .target(
            name: "WalkingPadCoreLogic",
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
                "TreadmillSpeedBoundsService.swift"
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
            name: "TelemetryPersistenceTests",
            dependencies: ["TelemetryDomain", "TelemetryPersistence"]
        )
    ]
)
