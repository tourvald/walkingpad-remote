# Selected redesign direction

Status: frozen for Issue #58 implementation.

- Related issue: GitHub Issue #58, parent Epic #55, accepted predecessor Issue #56 / PR #61.
- PM decision: [Concept A with live zone-lane refinements](https://github.com/tourvald/walkingpad-remote/issues/58#issuecomment-5381177403).
- Exact base: `56e01483ff144c29fe803f8870c0ae0174482e08`.
- Selected direction: Number-first Focus Stack with the Goal-1 Z1–Z5 scale and a separate observational current-HR marker.

## Frozen hierarchy

1. Compact phase plus peripheral treadmill and source-agnostic Heart Rate status.
2. Dominant factual current HR, or an explicit unavailable state when current HR is missing/stale.
3. Goal-1 Z1–Z5 scale directly below: selected physiological zone and full configured bounds remain visible; the factual current-HR marker moves independently across the scale.
4. Explicit symbol plus short relation text: `Ниже зоны`, `В зоне`, or `Выше зоны`.
5. Only factual treadmill speed and elapsed workout time remain persistent secondary metrics; distance is omitted.
6. Secondary `+5 мин` during the main phase and the existing `Стоп` action in one stable bottom location.

## Cooldown transformation

- Use the same shell and control placement.
- Current HR remains dominant.
- The active target presentation switches from the physiological workout zone to the existing recovery threshold (`≤ N bpm`) and reports `Выше цели` or `Цель достигнута` without changing cooldown behavior.
- Factual speed and elapsed/recovery context remain secondary; `+5 мин` is absent and Stop does not move.

## Exact writable paths

- `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote/ContentView.swift`
- `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemoteCoreTests/HeartRateLegacyBehaviorContractTests.swift`
- `docs/design/redesign-brief.md`
- `docs/design/selected-direction.md`
- `docs/design/qa-ledger.md`

All orchestration, BLE, control, cooldown, telemetry, persistence, project, and deployment paths are read-only.

## Presentation and fixtures

- Reuse and minimally generalize the small Goal-1 presentation value and its target segments; do not create a second presentation framework.
- One universal active shell handles main workout and cooldown through conditional presentation values, not separate view hierarchies or lifecycle state.
- DEBUG-only transport-isolated fixtures: below/in/above zone, missing HR, factual speed unavailable, treadmill disconnected, cooldown above/reached target, and preview-only Intervals/Weekly Zones values.
- Target/marker math is observational presentation math only and cannot feed HR-control, speed, cooldown, Stop, or telemetry authority.

## Acceptance and removal

- Normal active UI no longer renders `CommonInfoCard` or the old predictor/decision/progress dashboard.
- Remove normal-user predictor text, next-decision countdown, algorithm explanation, persistent speed delta, steps, average HR, average speed, beats-per-meter, Watch-first readiness, and BLE/debug detail.
- Preserve the existing Start, extend, and Stop actions and every runtime/safety semantic.
- Verify with focused source contracts, full Swift tests, redesign scope checker, simulator/mock visual QA, and unsigned simulator/generic builds.

## Frozen non-goals

- No providers, factories, registries, DI, coordinators, mode routers, visualization framework, future-mode runtime, or second workout state machine.
- No change to HR-control target/deadband/predictor decisions, HR freshness/source selection, speed cadence/deltas, treadmill commands/order/retries/bounds, BLE protocol, controller-unit safety, Stop confirmation/evidence, cooldown runtime, HealthKit, Watch lifecycle, Telemetry V2, persistence, project settings, deployment, or hardware activity.
