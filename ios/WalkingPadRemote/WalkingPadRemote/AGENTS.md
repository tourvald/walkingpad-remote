# WalkingPad iOS Agent Guide

## Scope

This file applies to the Xcode project and Swift package under this directory.
It extends the repository root instructions; do not repeat or weaken the root
safety and approval boundaries here.

## Project Layout

- Xcode project: `WalkingPadRemote.xcodeproj`.
- iOS app target: `WalkingPadRemote/`.
- watchOS app target: `WalkingPadRemoteWatch Watch App/`.
- Pure logic package: `Package.swift` (`WalkingPadCoreLogic`).
- Pure logic tests: `WalkingPadRemoteCoreTests/`.
- Main iOS composition: `WalkingPadRemote/ContentView.swift`.
- Runtime orchestrator: `WalkingPadRemote/BluetoothManager.swift`.
- iPhone HealthKit integration: `WalkingPadRemote/IPhoneHealthKitHeartRateManager.swift`.
- Watch HR integration: `WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift`.

## Swift And Architecture Rules

- Follow Swift API Design Guidelines and existing project conventions.
- Avoid force unwraps. Handle asynchronous failures and state transitions
  explicitly.
- Keep SwiftUI views presentation-focused. Views may assemble presentation
  props and forward user actions; they must not own BLE packet rules, HR
  decisions, stop confirmation, or persistence policy.
- Keep `BluetoothManager` as an adapter/orchestrator. Add pure calculations or
  state machines to focused services and cover them in the Swift package.
- Build and parse WalkingPad/FTMS/FitShow packets in `BLETransportCodec.swift`.
- Keep command queue semantics in `CommandQueueService.swift` and speed bounds
  in `TreadmillSpeedBoundsService.swift`.
- Keep HR decision math in `HRDomainService.swift` and cooldown transitions in
  `CooldownRuntimeEngine.swift`.
- Keep telemetry schema, CSV conversion, JSONL retention, and cleanup in
  `TrainingTelemetryWriter.swift`.
- Preserve backward-compatible persisted keys and exported CSV columns unless
  a task explicitly approves a migration or breaking change.
- Add new pure source files to `Package.swift` explicitly and exclude UI or
  platform-only resources so `swift test` remains warning-free.

## Runtime Invariants

### Heart Rate

- Supported source modes are legacy Apple Watch via WatchConnectivity and
  iPhone HealthKit via `HKWorkoutSession`/`HKLiveWorkoutBuilder`.
- iPhone HealthKit mode must not start a second watch HR session. It waits for
  the first accepted live HR sample before starting the treadmill.
- Its initial-sample timeout starts only after `beginCollection` succeeds, and
  freshness uses the HealthKit sample interval timestamp rather than callback
  delivery time.
- Reject stale or out-of-order timestamped HR samples. Stream freshness must be
  explicit in UI state and telemetry.
- Preserve physical km/h HR profiles and adaptive decision behavior unless the
  task explicitly targets those rules.
- HR control remains gated by current controller unit safety, connection state,
  and source readiness defined by the root safety contract.

### Speed And Protocols

- Protocol discovery priority is WalkingPad `FE00`, FTMS `1826`, then FitShow
  `FFF0`.
- FTMS target and instantaneous speed use `0.01 km/h`; use supported speed range
  `2AD4` when available.
- Coalesce pending speed writes and keep STOP high priority.
- User-facing current speed uses fresh device telemetry. Command target,
  controller target, model speed, native speed, and physical estimate must stay
  separately named.
- For confirmed imperial projection, convert physical km/h to native mph/raw
  tenths at the command boundary and skip writes when raw tenths are unchanged.
- Do not introduce a hard-coded HR speed cap. Use validated controller bounds,
  existing user/app bounds, and controller acceptance.

### Stop And Session Lifecycle

- Do not modify the production stop sequence in unrelated work.
- Do not use the `0x04/0x01` toggle as a stop fallback.
- Stop confirmation requires fresh device evidence, not write completion or a
  model-side zero.
- Preserve the 30-second post-session observation window and keep logical
  workout completion separate from delayed log closure.
- Keep training-log analysis and inventory rebuild off the main thread.

## UI Contracts

- Current bottom tabs are `HR-control`, `Statistics`, `Plank`, and `Debug`
  (localized in the app). Root tab selection persists through `@AppStorage`.
- The control tab is a single HR-control screen. Do not reintroduce the removed
  manual-control page or segmented mode switch without an explicit product task.
- Keep the top treadmill/watch status and `CommonInfoCard` outside swipeable
  content.
- `Statistics` uses segmented week/month selection with a page-style `TabView`;
  workout history remains outside the swipeable summary.
- For equivalent page switching, use segmented `Picker`, page `TabView` without
  dots, and `.easeInOut(duration: 0.25)` unless the existing screen establishes
  another local pattern.
- Reuse shared UI components instead of duplicating cards or action styles.
  Debug cards receive presentation props assembled by `DebugView` rather than
  reading `BluetoothManager` directly.
- UI-only tasks must not change BLE commands, HR decisions, safety gates,
  persistence, or session lifecycle.
- Avoid parsing files, blocking BLE work, or other heavy operations on the main
  thread. Validate startup-sensitive changes against the prior black-screen
  failure class.

## Diagnostics And Logging

- Every HR session writes structured JSONL under Application Support
  `TrainingLogs`; preserve full-fidelity raw events when extending normalized
  CSV fields.
- Prefer normalized analyzer/export fields. Keep `raw_json` compatibility for
  historical logs.
- Maintain explicit telemetry for HR source/freshness, speed target and actual
  source, native/physical projection, command writes, queue state, controller
  params/checksum, stop attempts, and fresh post-command FE01 snapshots.
- Debug preview actions must remain side-effect free unless the UI explicitly
  identifies and confirms a controlled hardware diagnostic.
- Raw export may include incomplete sessions. Session summary remains limited
  to sessions containing a saved workout.

## Testing

Run the narrowest relevant test first. Standard commands from this directory:

```bash
swift test

xcodebuild \
  -project WalkingPadRemote.xcodeproj \
  -scheme WalkingPadRemote \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

- Add or update XCTest coverage for changed pure behavior.
- For bug fixes, prefer a failing focused test or deterministic reproducer
  before the fix, then rerun the focused and relevant broader suites.
- For SwiftUI layout changes, build the affected target and visually verify the
  relevant screen on appropriate device sizes when device/simulator use is
  authorized.
- An unsigned build is verification only. It does not authorize installation,
  launch, HealthKit access, BLE connection, or treadmill commands.

## Toolchain Notes

- Keep project-level `SDKROOT = iphoneos`; removing it can collapse available
  run destinations to `My Mac`.
- Simulator builds require an installed runtime compatible with the active
  Xcode SDK. Diagnose destination/runtime mismatch before changing project
  settings.
- Hosted CI may fall back to project validation when its Xcode lacks the iOS or
  watchOS SDK required by current HealthKit APIs.
- Prefer the local `xcode-tools` MCP server for read/build/test workflows when
  available; its entry point is repository-root `tools/mcp_xcode_server.py`.

## Completion Report

For non-trivial changes, report:

- changed files and behavior;
- exact verification commands and results;
- official documentation checked when relevant;
- assumptions and residual safety risks;
- whether docs changed;
- scoped `git status --short --branch`.
