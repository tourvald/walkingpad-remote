# Design Agent Workflow (iOS / SwiftUI)

How an AI agent iterates on **UI/visual design** in this repo without touching
business logic. Pairs with [`ios_swiftui_design_skill.md`](ios_swiftui_design_skill.md)
(the design rules).

## Environment (verified 2026-06-03)
- macOS 26.4.1 · **Xcode 26.5** (build 17F42) · Swift 6.3.2 · `xcrun` + SwiftPM OK.
- Project: `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj`
  - Schemes: `WalkingPadRemote` (iOS app), `WalkingPadRemoteWatch Watch App`.
- iOS 26 simulators available (iPhone 17 / 17 Pro / Air / 17e …).
- Bluetooth and live HealthKit are **not** available in the simulator, so the app
  renders its *disconnected / no-signal* UI there. That is fine for visual design.

## Build & verify (run after every change)
```bash
APP=ios/WalkingPadRemote/WalkingPadRemote
# 1) Pure core-logic tests (fast; proves business logic still compiles/passes)
( cd "$APP" && swift test )
# 2) Unsigned device build (whole app + watch)
xcodebuild -project "$APP/WalkingPadRemote.xcodeproj" -scheme WalkingPadRemote \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
A design change is only acceptable if **both** stay green.

## Screenshot loop (simulator)
```bash
SIM="iPhone 17 Pro"          # any available iOS 26 simulator
PROJ=ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj
DD=/tmp/wpr-sim-dd
BUNDLE=sw.WalkingPadRemote

xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project "$PROJ" -scheme WalkingPadRemote \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted "$DD/Build/Products/Debug-iphonesimulator/WalkingPadRemote.app"
xcrun simctl launch booted "$BUNDLE"
xcrun simctl io booted screenshot /tmp/wpr-screen.png
```
Capture **before** and **after** for every visual change. Light + dark:
`xcrun simctl ui booted appearance dark` (or `light`), then screenshot again.
Dynamic Type: `xcrun simctl ui booted content_size accessibility-extra-extra-extra-large`.

## Xcode MCP (optional, richer loop)
Xcode 26 ships an MCP bridge. A project-scoped server is configured in
[`.mcp.json`](../.mcp.json):
```json
{ "mcpServers": { "xcode": { "command": "xcrun", "args": ["mcpbridge"] } } }
```
- Requires **Xcode running with this project open** (`xcrun mcpbridge` connects to it).
- In Claude Code: approve the `xcode` server when prompted (project-scoped servers
  need consent). Then build/run tools are available via MCP.
- `claude` / `codex` CLIs were **not** on PATH at setup time, so the server was wired
  via `.mcp.json` rather than `claude mcp add` / `codex mcp add`. If a CLI is later
  installed, the equivalent is:
  `claude mcp add --transport stdio xcode -- xcrun mcpbridge`
- Plain `xcrun simctl … screenshot` (above) works with no MCP at all and is the
  fallback if the MCP is unavailable.

## The iteration loop
1. **Pick a screen** and capture a baseline screenshot (light + dark).
2. **Read the view file** (see the design-surface list in the design skill).
3. **Propose** 2–3 concrete visual improvements (HIG-grounded). Get approval for
   anything beyond a trivial restyle.
4. **Change only presentation** — never `@Published` semantics, commands, decisions,
   or telemetry (see "Do not touch" below).
5. **Rebuild + re-test** (both must be green) and capture an **after** screenshot.
6. **Review** before/after side by side; iterate.

## Do not touch (business logic)
Design changes are confined to SwiftUI presentation. **Off-limits without explicit
permission:** `BluetoothManager.swift`, every `*Engine` / `*Service` /
`*DomainService` / `RuntimeGapMonitor` / `TrainingTelemetryWriter` /
`IPhoneHealthKitHeartRateManager` / `WorkoutSessionController`, and the watch HR
managers. Rule of thumb: if it sends BLE commands, makes HR/cooldown decisions,
controls the belt, or writes telemetry — **do not change it for design**.

## Commit policy
- One concern per commit; presentation only.
- Each design commit includes **before/after screenshots** (attach or link), or a
  short note explaining why a screenshot was impossible.
- **No commit, push, or merge without owner confirmation.**
