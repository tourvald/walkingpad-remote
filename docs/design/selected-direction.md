# Selected redesign direction

Status: frozen for implementation.

- Related issue: GitHub Issue #56, parent Epic #55.
- PM decision reference: [PM approval — freeze refined Concept B and implement Goal 1](https://github.com/tourvald/walkingpad-remote/issues/56#issuecomment-5380900151), including the preceding [mode/range refinement](https://github.com/tourvald/walkingpad-remote/issues/56#issuecomment-5380829689).
- Selected concept: refined Concept B — compact readiness plus a dominant mode-and-target hero.
- Why it was selected: the workout mode and configured target own the hierarchy; readiness and settings remain available without recreating the idle telemetry dashboard; the small presentation shape can serve later active-workout UI without speculative runtime architecture.
- Exact writable paths:
  - `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote/ContentView.swift`
  - `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemoteCoreTests/HeartRateLegacyBehaviorContractTests.swift`
  - `docs/design/redesign-brief.md`
  - `docs/design/selected-direction.md`
  - `docs/design/qa-ledger.md`
- Frozen hierarchy: `Training` title; low-emphasis treadmill and source-agnostic fresh-HR readiness; native mode Menu; one dominant hero; selected HR zone and configured range; segmented Z1–Z5 target control; compact duration/cooldown facts; visible full-width Start.
- Frozen mode selector: working `HR Control` plus a disabled, non-startable `Intervals · Скоро` production placeholder. Weekly Zones Auto and richer Intervals states exist only as deterministic preview/test values.
- Frozen target semantics: show the selected zone and its configured range, not a single target bpm. Zone taps reuse the existing target assignment; a future live-HR marker is a separate observational value and is not implemented in #56.
- Mock/simulator inputs: ready with unknown source; ready with known source; treadmill unavailable; HR unavailable/stale; preparing presentation; preview-only Intervals and Weekly Zones Auto values; compact-width portrait, compact-height, regular-width, light/dark, and accessibility sizes.
- Acceptance criteria: Start calls the existing `startHrControl()` and preserves affordance parity; `Intervals · Скоро` cannot start; idle accumulated metrics and Watch-first readiness are removed; global HR-zone editing remains in Settings; Start needs no scrolling; no control/runtime/telemetry/persistence source changes; scope checker, focused tests, Swift suite, unsigned build, and visual QA pass.
- Frozen non-goals: no provider/factory/registry/DI/coordinator; no second lifecycle; no future-mode runtime; no new sensor transport; no BLE, HR decision, safety, speed, cooldown/stop, HealthKit, Watch lifecycle, Telemetry V2, persistence, project, device, or hardware changes.
