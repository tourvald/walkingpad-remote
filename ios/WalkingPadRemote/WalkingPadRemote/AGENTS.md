# iOS and Swift contract

This file extends the repository contract for `ios/WalkingPadRemote/WalkingPadRemote/`. Do not repeat or weaken the root Git, PM, agent, or hardware gates.

## Architecture

- Keep SwiftUI views presentation-focused. Assemble view state and actions at established presentation boundaries; avoid placing controller decisions, persistence, transport, or protocol behavior in views.
- Keep `BluetoothManager` as an orchestration adapter. Put deterministic rules in the existing focused domain/service modules and cover them with Swift package tests; do not turn the manager into a dumping ground for pure logic.
- BLE packet construction and parsing belong in established codec/protocol seams. Views and domain rules must not construct raw controller packets.
- Preserve dependency direction and existing architecture. Do not add a layer or dependency without a concrete task need.

## Safety-critical behavior

- Stop confirmation requires fresh factual device evidence; app-side intent, a queued command, missing speed, or stale telemetry is not confirmation.
- Preserve HR start, stale-signal, speed-bound, cooldown, and manual-stop gates. Missing or unknown HR/device state must fail safe.
- Preserve physical km/h domain semantics and explicit controller-native unit conversion. Unknown or unconfirmed imperial semantics must not enable HR control or silent conversion.
- Preserve telemetry event meaning, normalized fields, profile ownership, retention boundaries, and workout-history persistence unless an approved safety/data contract says otherwise.
- Debug, preview, and mock paths must remain separated from production transport and must not weaken runtime gates.

Changes to any invariant above require the root `walkingpad-safety-change` workflow. Physical validation requires the separate hardware-experiment workflow.

## UI redesign boundary

- Use [`walkingpad-ios-redesign`](../../../.agents/skills/walkingpad-ios-redesign/SKILL.md) for redesign tasks.
- Default writes are limited to the PM-approved SwiftUI screen/components, visual tokens/assets, previews or mock fixtures, UI-focused tests, and `docs/design/**`.
- Treat `BluetoothManager.swift`, protocol/codec code, stop/start/speed paths, HR decisions/gates, units/preferences, telemetry semantics, persistence, Xcode project settings, and BLE tools as read-only unless separately approved.
- Use simulator or mock data only for ordinary design work. A simulator/build result does not authorize install, device launch, BLE, or treadmill activity.

## Verification

- Core logic: `swift test`
- Project metadata when hosted SDKs lag: `xcodebuild -list -project WalkingPadRemote.xcodeproj`
- Unsigned generic app build when applicable: `xcodebuild -project WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- UI work: run the redesign scope checker from the repository root, then perform the approved simulator/mock visual QA. Summarize build failures instead of feeding complete successful logs back into agent context.

Never install or launch the app on a physical device as part of these checks.
