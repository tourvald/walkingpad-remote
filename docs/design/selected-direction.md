# Selected redesign direction

Status: frozen for Issue #59 implementation.

- Related issue: GitHub Issue #59, parent Epic #55.
- Accepted predecessor: Issue #58 / PR #62 at implementation head `9178f8b941ba0ab7ed26f0709f8343d4be96c1a5`, merged as `4d0be757729bc24e2169c7c1cacc81ded9969cd2`.
- PM decision: [revised Quiet Finish / distance-first summary](https://github.com/tourvald/walkingpad-remote/issues/59#issuecomment-5381678119).
- Exact implementation base: `4d0be757729bc24e2169c7c1cacc81ded9969cd2`.
- Selected direction: revised Concept A — Quiet Finish, Stable Result.

## Frozen ending

1. When the accepted runtime leaves active/cooldown, replace the active shell with a short presentation-local ending state.
2. Show only `Завершаем тренировку…` and, when available, concise factual treadmill Stop status mapped from `stopTruthStatusText`.
3. Do not show summary preparation, persistence, HealthKit, Telemetry, artificial countdown, delay, or fake progress.
4. Transition immediately when the exact same-session projection becomes available. The ending must not be retained merely for animation.
5. Minimal local state may retain identity and result snapshots; it must not own workout, Stop, cooldown, save, or Telemetry lifecycle.

## Frozen result hierarchy

1. Factual same-session device distance is the hero when its start/end snapshot passes every validation below.
2. Factual `WorkoutHistoryProjection.durationSeconds` is the hero fallback when distance is unavailable.
3. Show all five physiological zones from `WorkoutHistoryProjection.zoneSeconds` with exact `mm:ss` / `h:mm:ss` text. Optional proportional bars may reinforce the result; zone name and duration remain visible and color is never the only carrier.
4. Compact secondary facts are duration, average HR, and factual average speed, each only when available. Do not duplicate duration below a duration fallback hero.
5. Omit unavailable secondary metrics. Do not show historical zone BPM bounds, distance placeholders, zero-filled zones, steps, beats-per-metre, recovery, save status, or diagnostics.
6. If exact projection identity cannot be resolved, show a concise unavailable result with no older-workout fallback.

## Exact same-session projection identity

- Capture the set of currently published native V2 projection IDs only when workout history is loaded at accepted HR-session entry.
- After `telemetryV2ProjectionGeneration` changes and history refresh completes, select exactly one new `.nativeV2` projection absent from the captured set.
- More than one candidate, no candidate, an unloaded baseline, or a failed read is unresolved. Never select merely the newest workout.
- The identity snapshot is presentation-local and cleared only by `Готово` or after navigating to Statistics.

## Factual distance snapshot

- Observe only direct `BluetoothManager.deviceReportedDistance10m`; never use `distKm` or integrate `speedKmh`.
- Capture the start counter at accepted session entry only when `connectedPeripheralId` and the WalkingPad-only `controllerUnitsTruth.connectionEpoch` factual context are both present.
- Retain those existing peripheral/connection-epoch values through the session, then capture the final counter when active/cooldown ends.
- Accept distance only when start/end counters are non-negative, context identity is unchanged, and end is not less than start.
- Convert the delta from 10-metre units: `Double(end - start) * 10.0 / 1_000.0` kilometres.
- If protocol, counter, identity, ordering, or availability is uncertain, distance is nil and duration becomes the hero.
- This value is immediate-summary presentation state only. It is never persisted or fed into control, Telemetry, history, or runtime decisions.

## Actions and navigation

- `Готово`: clear only ending/result presentation snapshots and return to the accepted Training Hub.
- `Открыть статистику`: switch to the existing Statistics/history tab and clear the local result presentation.
- No Details screen.

## Accessibility and responsive contract

- The hero uses scalable rounded/monospaced typography and may shrink/wrap without clipping.
- Zone rows keep `Z1`–`Z5` text plus exact duration/unavailable output; bars are decorative for VoiceOver.
- Unavailable facts have meaningful VoiceOver labels and never read as zero.
- The accepted Training zone scale exposes one aggregate accessibility value covering selected zone, bounds, live HR/relation, or cooldown target where applicable.
- `ViewThatFits`/vertical fallbacks preserve compact width, regular width, compact height, and Accessibility XL.
- Ending/result focus moves heading-first. Reduce Motion uses immediate replacement; no permanent decorative workout animation.
- Native actions keep at least 44-point targets and remain in the bottom safe-area region.

## Exact writable paths

- `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote/ContentView.swift`
- `ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemoteCoreTests/HeartRateLegacyBehaviorContractTests.swift`
- presentation-only files proven unused after the complete Goal 1–3 flow, only when deletion/removal stays within Xcode source membership
- `docs/design/redesign-brief.md`
- `docs/design/selected-direction.md`
- `docs/design/qa-ledger.md`

All orchestration, BLE, control, cooldown, telemetry, persistence, project, signing, deployment, and hardware paths are read-only.

## Deterministic fixtures and verification

- Add transport-isolated DEBUG fixtures for ending confirming/confirmed/unavailable, complete distance-first summary, duration-fallback summary, partial zones/metrics, and unresolved summary identity.
- Verify the complete accepted Hub/active/cooldown/ending/summary flow in light/dark, compact/regular width, Accessibility XL, VoiceOver semantics, and Reduce Motion.
- Run focused contracts, full SwiftPM suite, applicable safety/control/stop/cooldown regressions, scope checker, `git diff --check`, simulator visual QA, and unsigned iOS/watchOS builds.

## Frozen non-goals

- No distance schema/projection/persistence/migration work and no historical distance.
- No providers, factories, registries, DI, coordinators, design-system layer, summary store, future-mode runtime, RPE, Live Activity, or second workout state machine.
- No change to HR-control/source selection, target/deadband/predictor decisions, speed commands/order/retries/bounds, BLE, controller-unit safety, Stop confirmation/evidence, cooldown runtime, HealthKit/Watch lifecycle, Telemetry V2, persistence, Xcode settings, deployment, or hardware activity.
