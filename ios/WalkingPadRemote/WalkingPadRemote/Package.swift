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
            name: "TelemetryInstrumentation",
            targets: ["TelemetryInstrumentation"]
        ),
        .library(
            name: "TelemetryAnalysis",
            targets: ["TelemetryAnalysis"]
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
        ),
        .library(
            name: "TelemetryParity",
            targets: ["TelemetryParity"]
        ),
        .library(
            name: "TelemetrySoak",
            targets: ["TelemetrySoak"]
        ),
        .executable(
            name: "telemetry-soak",
            targets: ["TelemetrySoakCLI"]
        )
    ],
    targets: [
        .target(
            name: "TelemetryDomain"
        ),
        .target(
            name: "TelemetryInstrumentation"
        ),
        .target(
            name: "TelemetryAnalysis",
            dependencies: ["TelemetryDomain"]
        ),
        .target(
            name: "TelemetryRecorder",
            dependencies: ["TelemetryDomain", "TelemetryInstrumentation"]
        ),
        .target(
            name: "TelemetryPersistence",
            dependencies: [
                "TelemetryDomain",
                "TelemetryAnalysis",
                "TelemetryInstrumentation",
                "TelemetryRecorder",
            ]
        ),
        .target(
            name: "TelemetryRuntime",
            dependencies: [
                "TelemetryDomain",
                "TelemetryInstrumentation",
                "TelemetryRecorder",
            ]
        ),
        .target(
            name: "TelemetryParity",
            dependencies: [
                "TelemetryDomain",
                "TelemetryPersistence",
                "TelemetryRuntime",
            ]
        ),
        .target(
            name: "TelemetrySoak",
            dependencies: [
                "TelemetryDomain",
                "TelemetryInstrumentation",
                "TelemetryPersistence",
                "TelemetryRecorder",
                "TelemetryRuntime",
                "WalkingPadCoreLogic",
            ]
        ),
        .executableTarget(
            name: "TelemetrySoakCLI",
            dependencies: ["TelemetrySoak"]
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
                "IPhoneHealthKitLiveHeartRateProvider.swift",
                "PlankTimerView.swift",
                "StatsRightAlignedBlock.swift",
                "StatusPillsRow.swift",
                "WalkingPadRemote.entitlements",
                "WalkingPadRemoteApp.swift"
            ],
            sources: [
                "AutoConnectRetryPolicy.swift",
                "BLETransportCodec.swift",
                "ControllerUnitsSafetyPolicy.swift",
                "CooldownRuntimeEngine.swift",
                "DeterministicControlReplay.swift",
                "DiscoveryUIPublicationPolicy.swift",
                "HRDomainService.swift",
                "HRSettingsDefaults.swift",
                "IPhoneHealthKitHeartRateProviderCore.swift",
                "NativeHeartRatePreflightEngine.swift",
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
                "ZonePlanProgress.swift",
                "CommandQueueService.swift",
                "TreadmillSpeedBoundsService.swift",
                "TrainingUIHeartRatePublicationPolicy.swift",
                "TrainingUIHeartRateReadinessPresentationPolicy.swift",
                "TrainingUIObservationBoundary.swift",
                "TrainingUITreadmillPublicationPolicy.swift",
                "TreadmillControlReadinessPolicy.swift",
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
            name: "TelemetryAnalysisTests",
            dependencies: ["TelemetryAnalysis", "TelemetryDomain"]
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
            name: "TelemetryParityTests",
            dependencies: [
                "TelemetryDomain",
                "TelemetryParity",
                "TelemetryPersistence",
                "TelemetryRuntime",
            ]
        ),
        .testTarget(
            name: "TelemetryInstrumentationTests",
            dependencies: ["TelemetryInstrumentation"]
        ),
        .testTarget(
            name: "TelemetrySoakTests",
            dependencies: [
                "TelemetryInstrumentation",
                "TelemetryRecorder",
                "TelemetryRuntime",
                "TelemetrySoak",
                "WalkingPadCoreLogic",
            ]
        ),
        .testTarget(
            name: "TelemetryPersistenceTests",
            dependencies: [
                "TelemetryAnalysis",
                "TelemetryDomain",
                "TelemetryRecorder",
                "TelemetryPersistence",
            ]
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
