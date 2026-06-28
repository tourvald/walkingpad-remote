// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WalkingPadRemoteCoreLogic",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "WalkingPadCoreLogic",
            targets: ["WalkingPadCoreLogic"]
        )
    ],
    targets: [
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
                "DebugSharedUIComponents.swift",
                "DebugTrainingLogsCard.swift",
                "DevicePickerView.swift",
                "IPhoneHealthKitHeartRateManager.swift",
                "PlankTimerView.swift",
                "StatsRightAlignedBlock.swift",
                "StatusPillsRow.swift",
                "WalkingPadRemote.entitlements",
                "WalkingPadRemoteApp.swift"
            ],
            sources: [
                "BLETransportCodec.swift",
                "CooldownRuntimeEngine.swift",
                "HRControlDecisionEngine.swift",
                "HRDomainService.swift",
                "HRSettingsDefaults.swift",
                "NativeSpeedValue.swift",
                "RuntimeGapMonitor.swift",
                "TrainingTelemetryWriter.swift",
                "CommandQueueService.swift",
                "TreadmillSpeedBoundsService.swift",
                "TreadmillSpeedCommandProjection.swift",
                "TreadmillUnitsSafetyPolicy.swift",
                "TreadmillPhysicalSemanticsConfirmation.swift",
                "TreadmillTestRunPlanService.swift"
            ]
        ),
        .testTarget(
            name: "WalkingPadCoreLogicTests",
            dependencies: ["WalkingPadCoreLogic"],
            path: "WalkingPadRemoteCoreTests"
        )
    ]
)
