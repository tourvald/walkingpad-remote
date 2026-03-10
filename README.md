# WalkingPad Remote

[![CI](https://github.com/tourvald/walkingpad-remote/actions/workflows/ci.yml/badge.svg)](https://github.com/tourvald/walkingpad-remote/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

WalkingPad Remote is a local-first iOS/watchOS project for controlling compatible WalkingPad-class treadmills, running heart-rate-driven sessions from Apple Watch data, and exporting structured workout telemetry for debugging and experimentation.

This is an independent community project and is not affiliated with WalkingPad, KingSmith, or any treadmill vendor.

## Why this repo exists

Consumer treadmill apps are usually closed, hard to inspect, and poor at experimentation. This repository tries to be a practical reference implementation for:

- BLE treadmill control from iPhone
- Apple Watch heart-rate integration
- multi-protocol experimentation across WalkingPad, FTMS, and FitShow devices
- local-first telemetry export for post-workout analysis

## What is in the repo

- `ios/WalkingPadRemote`: the main iOS/watchOS app and Xcode project
- `ios/WalkingPadRemote/WalkingPadRemote/Package.swift`: a pure Swift core-logic package used for focused unit tests
- `scan_ble.py`, `run_live_stats.py`, `run_menu.py`, `run_workout.py`: small Python BLE tools for discovery, diagnostics, and raw protocol experimentation
- `tools/mcp_xcode_server.py`: local MCP helper for Xcode-oriented Codex workflows

## Feature highlights

- Heart-rate control mode with user-tunable thresholds and adaptive speed decisions
- Multi-protocol treadmill support for WalkingPad (`FE00`), FTMS (`1826`), and FitShow (`FFF0`) devices
- Apple Watch companion app for heart-rate streaming
- Structured JSONL session telemetry plus CSV export for analysis
- Focused pure-logic Swift modules with unit tests for HR decisions, speed bounds, and command queue behavior
- A secondary plank timer tab for simple off-treadmill workouts

## Project status

- Active personal OSS project with real-device testing
- Local-first by design: no cloud backend, no account system, no external service dependency
- Scope is intentionally narrow: treadmill control, watch integration, telemetry, and related tooling
- Public repository hygiene is in place: MIT license, CI, CODEOWNERS, issue forms, and PR template

## Quick start

### iOS app

1. Open `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj` in Xcode.
2. Select your own signing team for the iOS and watchOS targets.
3. Run on a real iPhone. Use a paired Apple Watch if you want HR-driven control.
4. Read [ios/README.md](ios/README.md) for iOS-specific setup and validation notes.

### Core logic tests

```bash
cd ios/WalkingPadRemote/WalkingPadRemote
swift test
```

### Python BLE tools

The Python helpers are intended for local diagnostics and protocol investigation.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install bleak
python scan_ble.py scan --timeout 8 --name KS-F0
```

On macOS, Python needs Bluetooth permission in `System Settings -> Privacy & Security -> Bluetooth`.

## Quality and CI

GitHub Actions currently runs:

- Python syntax compilation for the public BLE/MCP utilities
- `swift test` for the pure core-logic package
- unsigned `xcodebuild` for the iOS/watchOS project

## Safety and privacy

- This project can control physical hardware. Start conservatively, stay nearby, and test on a safe speed.
- Share logs carefully. Do not post pairing secrets, device identifiers, or personal health data unnecessarily.
- Workout telemetry is stored locally and exported explicitly from the app; the project does not depend on a hosted backend.

## Contributing and support

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
- Use [SUPPORT.md](SUPPORT.md) for help and troubleshooting flow.
- Use [SECURITY.md](SECURITY.md) for safety-sensitive or vulnerability-related reports.
- See [ROADMAP.md](ROADMAP.md) for the current direction and non-goals.

## Public repo notes

- The local `ph4-walkingpad` clone is intentionally not included in this repository because it is an upstream reference repo with its own git history.
- The public canonical GitHub repository for this project is `tourvald/walkingpad-remote`.
