# WalkingPad Remote Agent Guide

## Purpose

This repository contains an iOS/watchOS application that controls a physical
WalkingPad treadmill and can adjust speed from live heart-rate data. Treat BLE
commands, speed control, controller preferences, and stop handling as
safety-critical behavior.

This file applies repository-wide. The nested
`ios/WalkingPadRemote/WalkingPadRemote/AGENTS.md` adds Swift/iOS-specific rules.
Keep active agent instructions focused on durable contracts; use Git history
and topic documentation for historical implementation notes.

## Working Contract

- Respond to the product owner in Russian. Keep code, identifiers, comments,
  docstrings, commit subjects, and API names in English.
- For review, investigation, explanation, or planning requests, inspect and
  report only. Do not edit, commit, push, deploy, or run hardware experiments
  unless the request explicitly authorizes them.
- For implementation requests, make the smallest coherent in-scope local
  change and run relevant non-destructive verification without asking again.
- Require explicit approval before external writes, push, PR creation, merge,
  deploy/install, destructive Git operations, persistent controller writes, or
  treadmill experiments.
- Preserve unrelated user changes in dirty worktrees. Never reset, discard, or
  include them in a commit unless explicitly requested.
- Do not expand scope to adjacent refactors or known bugs. Stop and report when
  a required action would cross an approval or safety boundary.
- Before substantial work, briefly identify the goal, relevant files,
  constraints, completion evidence, risks, and tests. For risky or ambiguous
  behavior changes, propose the plan before editing.
- Check current official documentation before relying on unstable Apple,
  Swift, Xcode, HealthKit, WatchConnectivity, CoreBluetooth, or OpenAI behavior.

## Sources Of Truth

Use current code and runtime evidence as authoritative. Use documentation in
this order:

1. `docs/walkingpad_protocol/README.md` and the normalized topic files under
   `docs/walkingpad_protocol/`.
2. `docs/ks-f0-stop-forensics-round2.md` for the active stop-evidence contract.
3. `docs/ble_tooling_setup.md` for approved local BLE diagnostics.
4. `docs/research/` only as historical research, not as an authorization to
   send commands.
5. `README.md` and `ios/README.md` for contributor setup and validation.

Do not copy dated changelog material back into `AGENTS.md`. Update these files
only when a durable command, boundary, invariant, or ownership rule changes.

## Safety Invariants

### Controller Units

- A valid WalkingPad `queryParams.unit=1` (`imperial`) is a broken stop-safety
  state for the affected controller. HR control and Debug Test Run must remain
  blocked until a fresh read-back reports metric units with a valid checksum.
- Production recovery is explicit and owner-approved only. It may send exactly
  the metric preference packet `F7 A6 08 00 00 00 00 AE FD`, then must query
  params and succeed only on `unit=0` with checksum OK.
- Never switch units silently on connect. There is no production set-imperial
  recovery path.
- The Debug units diagnostics surface may use only the documented fixed query,
  set-metric, and set-imperial packets and must show the persistent-preference
  confirmation before a write. Do not expose arbitrary packet input.
- Keep controller-native values, physical speed estimates, and UI units
  explicit. Legacy `*_kmh` fields may remain for compatibility but are not the
  source of truth for imperial UI.

### Stop Handling

- Preserve the current production stop sequence unless a separate approved
  stop task explicitly changes it.
- Do not add the WalkingPad `START/STOP` toggle as a stop fallback. Existing
  evidence shows it can leave the belt moving at minimum speed.
- A write success is not proof of a stop. Confirmation requires fresh FE01
  evidence with raw speed zero and a stopped/idle/standby-like state.
- Keep post-session stop observation and structured telemetry intact when
  modifying session lifecycle code.
- Stop experiments are diagnostic-only and require the approved fixed variant,
  no-load setup, an operator present, fresh low moving FE01 baseline, and a
  ready physical power switch.

### Forbidden Or Separately Approved Actions

- Do not use arbitrary `scan_ble.py raw` or `scan_ble.py seq` commands.
- Do not send `F7 A2 03 07 AC FD`.
- Do not perform service-menu writes, firmware/OTA actions, unknown packet
  replay, or automatic controller mutation.
- Do not run treadmill hardware experiments, controller preference writes, or
  device deploys without explicit approval for that exact stage.
- Treat `docs/walkingpad_protocol/forbidden_actions.md` as binding.

## Architecture And Ownership

- Main app code: `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote/`.
- Watch app code: `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemoteWatch Watch App/`.
- Pure Swift logic and tests: `ios/WalkingPadRemote/WalkingPadRemote/Package.swift`
  and `WalkingPadRemoteCoreTests/`.
- `BluetoothManager.swift` orchestrates BLE, session state, and published UI
  state. Move reusable calculations and state transitions into focused pure
  services instead of growing the manager.
- `BLETransportCodec.swift` owns packet construction and parsing.
- `HRDomainService.swift` and `CooldownRuntimeEngine.swift` own pure HR and
  cooldown rules.
- `CommandQueueService.swift` owns queue coalescing and priority behavior.
- `TreadmillSpeedBoundsService.swift` owns normalized speed bounds.
- `TrainingTelemetryWriter.swift` owns JSONL/CSV materialization, retention,
  and export helpers.
- SwiftUI views present state and forward user intent. Do not put BLE protocol
  rules or HR decision logic in views.
- Keep domain logic framework-independent where practical and add it to the
  Swift package target so it can be tested without a device.

## Runtime And Telemetry Truth

- Prefer fresh device-reported speed for user-facing current speed. Keep
  command targets and model-derived values diagnostic-only and label them
  explicitly.
- Preserve physical km/h semantics for HR profiles. Convert to native units
  only at the protocol projection boundary.
- Avoid duplicate BLE speed writes when projected raw tenths do not change.
- Raw JSONL is the event-level source of truth. Normalized CSV fields should be
  preferred by analyzers, with `raw_json` fallback only for older exports.
- Do not parse retained training logs on the main thread.
- Session summaries include completed workouts only; raw exports may include
  failed or incomplete sessions.
- Do not infer physical units or stop success from ambiguous/stale telemetry.

## Approved Tooling

- Set up BLE tools with `./scripts/setup_ble_env.sh`.
- Run safe BLE commands through `./scripts/run_ble_tool.sh` and the documented
  fixed modes in `docs/ble_tooling_setup.md`.
- Analyze exported CSV or raw JSONL with
  `python3 tools/analyze_training_log.py <path>`.
- Pull iOS training logs read-only with
  `scripts/pull_ios_training_logs.sh --device <device-id>`.
- The local Xcode MCP server is `tools/mcp_xcode_server.py`; inspect configured
  servers with `codex mcp list`.

## Verification

Choose checks proportional to the change. The standard safe suite is:

```bash
cd ios/WalkingPadRemote/WalkingPadRemote
swift test

xcodebuild \
  -project WalkingPadRemote.xcodeproj \
  -scheme WalkingPadRemote \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

cd ../../..
python3 -m unittest tools.analyze_training_log_tests tools.ble_tooling_tests tools.scan_ble_observer_tests
git diff --check
```

- Run focused tests first, then the broader safe suite when shared behavior or
  public contracts change.
- Analyzer exit codes can represent a data verdict; inspect the report before
  treating every nonzero exit as a tool failure.
- Building does not authorize installation, launch, BLE connection, or
  treadmill operation.
- Report exact commands and outcomes. If a check cannot run, state why.

## Git And Delivery

- Use `codex/` for new branch names unless the user specifies another name.
- Keep commits focused and use concise English imperative subjects.
- Before committing or pushing, verify the scoped diff, tests, and
  `git status --short --branch`.
- Push, PR, merge, deploy, install, and hardware smoke are separate approval
  gates unless the user explicitly combines them.
- Never force-push or include unrelated dirty files without explicit approval.
