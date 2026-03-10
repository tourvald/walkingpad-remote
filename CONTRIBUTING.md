# Contributing to WalkingPad Remote

Thanks for considering a contribution.

This repository is intentionally small and focused. Good contributions usually improve one of these areas:

- treadmill protocol support and diagnostics
- HR-control logic and test coverage
- iOS/watchOS UX and reliability
- telemetry export and analysis workflow
- documentation and contributor experience

## Before you start

- Open an issue before large changes so scope and hardware assumptions are clear.
- Keep changes small and isolated. Avoid bundling UI polish, protocol changes, and tooling work into one PR.
- Avoid new dependencies unless there is a clear need and a discussion first.
- Prefer readable, explicit code over clever abstractions.

## Local setup

### iOS / watchOS

1. Open `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj`.
2. Select your own signing team for the iPhone and watch targets.
3. Use a real iPhone for BLE work. The iOS Simulator does not support Bluetooth.
4. Pair an Apple Watch if you need to validate HR-driven sessions.

### Python tools

The public Python utilities currently expect `bleak`.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install bleak
```

## Development guidelines

- Keep UI and presentation logic in the SwiftUI view files.
- Keep behavior changes isolated in `BluetoothManager.swift` or extracted focused services.
- Prefer pure logic modules when possible so behavior can be covered by unit tests.
- Update `README.md`, `ios/README.md`, and other contributor-facing docs when public workflows change.
- Update `AGENTS.md` notes when project structure or important engineering decisions change, so future Codex sessions can resume cleanly.

## Validation

Run the checks that match your change:

### Python tooling changes

```bash
python3 -m compileall scan_ble.py run_live_stats.py run_menu.py run_workout.py tools/mcp_xcode_server.py
```

### Core logic changes

```bash
cd ios/WalkingPadRemote/WalkingPadRemote
swift test
```

### App or project changes

```bash
xcodebuild -project ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Pull request expectations

Each PR should make it easy for a reviewer to answer four questions:

1. What changed?
2. Why was it needed?
3. How was it tested?
4. What hardware, protocol, or environment assumptions does it rely on?

Include screenshots for visible UI changes and logs for BLE or protocol changes when possible.
