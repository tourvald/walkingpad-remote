# Issue #59 redesign brief

Status: PM selected revised Concept A with a distance-first result hierarchy; implementation is authorized and frozen in `selected-direction.md`.

## Scope and contract

- Flow: the accepted `Training Hub -> active HR workout -> cooldown` presentation followed by a truthful ending state and a concise workout result.
- Exact base: `4d0be757729bc24e2169c7c1cacc81ded9969cd2` (`origin/main`, fetched 2026-08-22; merge of accepted PR #62).
- Accepted predecessor: Issue #58, PR #62, implementation head `9178f8b941ba0ab7ed26f0709f8343d4be96c1a5`.
- Binding direction: [final Issue #59 PM approval](https://github.com/tourvald/walkingpad-remote/issues/59#issuecomment-5381678119), which supersedes the earlier summary-order guidance.
- Writable paths for implementation: the presentation/test/design-doc set frozen in `selected-direction.md`.
- Read-only evidence: accepted Training presentation in `ContentView.swift`; stop, workout-recording, and projection publication paths in `BluetoothManager.swift`; `WorkoutHistoryProjection`; Telemetry V2 workout read store and post-workout analysis.
- Primary form factor: compact-width iPhone portrait. Compact height, landscape where supported, regular width, light/dark appearance, Dynamic Type, VoiceOver, and Reduce Motion remain required states of the same flow.
- Simulator/mock source for later QA: deterministic DEBUG-only Training fixtures plus new transport-isolated ending/completed/partial fixtures derived from the factual inputs listed below. No device, BLE, Watch, or treadmill activity is authorized.
- PM gate: select one direction before any production SwiftUI, test, preview, or cleanup work.

## Current factual flow

1. Active and cooldown presentation exists only while `BluetoothManager.isHrControlRunning == true`.
2. Manual Stop synchronously logs the request, ends the legacy structured log, sets `isHrControlRunning = false`, conditionally records legacy workout history, requests treadmill Stop, stops the Watch workout, and requests Telemetry V2 session finalization.
3. Normal cooldown completion similarly records the workout when eligible, sets `isHrControlRunning = false`, requests treadmill Stop, stops the Watch workout, and requests Telemetry V2 finalization.
4. Because `ControlSwipeView` switches directly on `isHrControlRunning`, the accepted active shell disappears immediately and the Training Hub returns. There is no ending or summary route today.
5. Stop confirmation continues independently through published `stopTruthStatusText`. Telemetry V2 finishes and runs post-workout analysis asynchronously; its projection-change callback then refreshes published workout history.

## Prioritized audit findings

1. **Stop currently causes an abrupt visual reset.** `isHrControlRunning` becomes false before stop confirmation and Telemetry V2 projection publication, so the active/cooldown shell immediately becomes the idle Hub. Add a presentation-only ending bridge; do not reinterpret `false` as saved or physically stopped.
2. **Existing stop truth can honestly drive ending copy.** Published `stopTruthStatusText` already distinguishes confirming, device-confirmed, moving/contradictory/stale, timeout, and confirmation-unavailable states. Preserve the existing safety alert and map only these facts into user-facing ending text.
3. **A completed Telemetry V2 projection is the strongest summary source.** `telemetryV2ProjectionGeneration`, `telemetryV2WorkoutHistoryState`, and profile-filtered `telemetryV2WorkoutHistory` publish after recorder finalization and post-workout analysis. Identify the just-finished projection by a pre-session set of projection IDs plus one new native V2 ID; never assume that the first or newest row is the workout when identity is ambiguous.
4. **The accepted projection supports a small result, not every candidate metric.** It provides optional duration, average HR, factual average speed, and five optional physiological-zone durations. Distance is absent. Target-zone time is truthful only when the same-session selected zone index is retained ephemerally and that exact zone element exists.
5. **Current history UI is data-rich but not a suitable immediate result.** It mixes date, duration, provenance, lifecycle/quality warnings, HealthKit UUID, beats-per-metre, target, average speed, and average HR in one row. Keep this in Statistics for later inspection; the immediate summary should not duplicate its diagnostic/provenance density.
6. **Missing data already has first-class representation.** Projection metrics are optional and `quality.unavailableMetrics`, lifecycle, recorder completeness, and analysis grade expose partiality. Summary must omit a metric or render an explicit unavailable value; it must never convert nil to zero or promote legacy estimated speed as factual.
7. **The complete flow still needs accessibility consolidation.** The active scale hides its live marker from VoiceOver and exposes five segment elements without one useful aggregate value; ending/summary need deterministic focus order and announcements. Large numerals, fixed 44/64-point scale geometry, compact height, and large Dynamic Type need explicit fallbacks without moving Stop or requiring decorative motion.
8. **Goal 2 left removable presentation-only remnants.** `ManualView` is no longer reached from the root Training flow, while `CommonInfoCard` and `ActionTileButton`/`ExtendTimeButton`/`PrimaryActionButton` are now unused by production Training. A selected implementation may remove only confirmed-unreferenced presentation code after source/tests/build verification; no adjacent runtime cleanup belongs here.

## Accepted facts available to ending and summary

| Visible meaning | Exact existing source | Truth boundary / unavailable behavior |
| --- | --- | --- |
| Workout UI has left active/cooldown | transition of published `isHrControlRunning` from `true` to `false` | Means control UI ended; does not mean saved, Telemetry V2 complete, HealthKit saved, or treadmill stopped. |
| Stop is being confirmed / confirmed / unconfirmed | published `stopTruthStatusText` | May drive treadmill-specific wording only. Empty or unknown status becomes neutral `Завершаем тренировку…`; never infer confirmation. |
| Telemetry finalization is pending or terminal | published `telemetryV2StatusText`; projection refresh is signalled by `telemetryV2ProjectionGeneration` and `telemetryV2WorkoutHistoryState` | Use as a presentation/availability gate, not a user-facing “saved” claim. A failed or missing projection yields partial/unavailable summary. |
| Exact immediate result record | one new `.nativeV2` `WorkoutHistoryProjection.id` absent from the ID set captured while the current session was active | If the baseline was not loaded, no unique new native projection appears, or more than one is ambiguous, do not select a different workout; show unavailable summary and leave history accessible. |
| Duration | `WorkoutHistoryProjection.durationSeconds` | Optional; show formatted factual value or `—`/omit as specified per concept. Never use zero for nil. |
| Time in each physiological zone | all five elements of `WorkoutHistoryProjection.zoneSeconds` | Show Z1–Z5 with exact duration when the array has five elements. Preserve an unavailable individual value as unavailable, never zero; do not infer historical BPM bounds. |
| Average HR | `WorkoutHistoryProjection.averageHeartRate` | Optional analysis result; show only when non-nil. |
| Average factual speed | `WorkoutHistoryProjection.averageSpeed` where `evidenceKind == .factual` | Optional; omit or mark unavailable when nil. Never present `.legacyEstimated` as factual. |
| Result is partial | nil metric fields plus `WorkoutHistoryProjection.quality.unavailableMetrics`, non-complete recorder/analysis quality, or failed history read | Use one concise partial-data message; keep every available factual metric. Do not expose diagnostic codes on the result screen. |

## Important facts not currently available truthfully for this result

- Distance is not part of `WorkoutHistoryProjection`; live `distKm` remains unacceptable. The final PM direction authorizes only an immediate presentation-local delta of direct `deviceReportedDistance10m` readings when peripheral and connection-epoch identity remain exact; otherwise distance is unavailable.
- A typed, presentation-facing “legacy workout saved” outcome is not exposed. `hrWorkoutRecorded` is private and recording can be skipped for failure or minimum duration, so ending cannot say that workout history was saved.
- HealthKit finish success is not exposed: `WorkoutSessionController.endAndFinish()` discards the completion results, and HealthKit linkage can arrive later. Never show “HealthKit saved”.
- Telemetry V2 status is operational lifecycle evidence, not a product save receipt. Never show “Telemetry saved”.
- Projection alone does not expose the historical selected zone index/bounds, distance, steps, cooldown result/recovery metrics, or end reason. Do not infer them from current profile settings.
- Native V2 read projection currently sets beats-per-metre unavailable. Steps are not an accepted post-workout projection. Neither belongs in this summary.

## Metric redistribution

- Duration: primary immediate summary result and existing history/statistics.
- Physiological-zone time: immediate summary shows exact Z1–Z5 durations from the same-session projection; existing Statistics remains the historical view.
- Average HR: immediate summary secondary value and existing history.
- Average factual speed: low-priority immediate summary value and existing history; estimated legacy speed stays in history with its existing evidence marker.
- Distance: immediate selected summary only when the direct same-session device counter delta passes the frozen identity/ordering checks; no history or persistence consumer.
- Steps and beats-per-metre: not in result; retain only current legitimate history/statistics/debug consumers, and remove dead presentation consumers if confirmed safe.
- Predictor, decisions, speed delta, countdown, and BLE/queue/provenance diagnostics: debug only or nowhere in consumer Training UI.
- No separate Details screen: existing Statistics/history serves the deeper inspection path, and the audit found no missing current user task requiring another destination.

## Concept A — Quiet Finish, Stable Result

### Ending presentation: top to bottom

1. Keep the accepted Training background and navigation title; replace the active shell with one centered material card.
2. Show primary copy `Завершаем тренировку…`; no phase label, progress indicator, countdown, or artificial hold is added.
3. Optionally show one treadmill-status row driven only by `stopTruthStatusText`: `Проверяем остановку дорожки`, `Дорожка остановлена`, or an explicit unconfirmed/safety state. Existing unconfirmed-stop alert remains authoritative.
4. No HealthKit, persistence, Telemetry, or summary-preparation copy is shown. The presentation transitions immediately when the exact result becomes available.

### Completed summary: top to bottom

1. Compact success-neutral header `Итог тренировки` with date/time only when `startedAt` exists. Do not say “saved”.
2. Primary result: factual same-session device distance when the frozen snapshot contract passes; otherwise large formatted `durationSeconds` with label `Продолжительность`.
3. Compact available secondary facts: duration when distance is the hero, average HR, and factual average speed.
4. A concise Z1–Z5 section shows the exact duration of every physiological zone from `zoneSeconds`, with textual duration always visible and color only as reinforcement.
5. Primary full-width `Готово` returns to the accepted Training Hub. Secondary text action `Открыть статистику` selects the existing Statistics tab/history.

### Visible metrics and exact fallbacks

- Distance: `Double(endCounter - startCounter) * 10 / 1_000` km from direct `deviceReportedDistance10m`, only with valid ordered readings and unchanged `connectedPeripheralId` plus `controllerUnitsTruth.connectionEpoch`; otherwise duration becomes the hero without a distance placeholder.
- Duration: `durationSeconds`; becomes the hero when distance is unavailable and appears as a secondary fact only when distance is the hero.
- Zones: all five `zoneSeconds` elements formatted with seconds. An unavailable element is announced/rendered unavailable, never as zero; if the distribution is absent, the section states that zone data is unavailable.
- Average HR: `averageHeartRate`; omit when nil.
- Average speed: factual `averageSpeed`; omit when nil or non-factual.
- Historical zone bounds, steps, beats-per-metre, recovery, HealthKit, and Telemetry statuses do not appear.

### Partial or unavailable summary

- If a unique exact projection exists but any result field is nil, keep every available fact and add one short note `Часть данных недоступна`; unavailable secondary facts are omitted and unavailable zone values remain explicit.
- If no exact projection can be selected, show `Итог пока недоступен`, no numeric placeholders, and only `Готово` plus `Открыть статистику`. Never display an older or merely newest workout.
- Stop uncertainty remains owned by the existing stop-truth surface; the result never claims that physical stop, persistence, HealthKit, or Telemetry succeeded.

### Transition, accessibility, impact, and trade-offs

- Transition: ending card crossfades to result when one exact new projection is available; otherwise it becomes the partial/unavailable state. Reduce Motion replaces the card without animation. No artificial save timer or second lifecycle state machine.
- Dynamic Type: duration may wrap label beneath the number; result rows switch from horizontal value alignment to vertical `ViewThatFits`; actions remain at least 44 points. At accessibility sizes the screen scrolls, with the header/result first and actions in a bottom safe-area inset.
- VoiceOver: post one `screenChanged` focus move to the ending heading, then to `Итог тренировки`; each metric is one label/value element and `—` is announced as `недоступно`. The existing zone scale gets one aggregate value in the complete Training QA pass.
- Light/dark: semantic system background, material, primary/secondary labels, and symbol-plus-text status; no meaning depends on tint.
- Production impact after implementation: `+844 / -622` lines across the existing presentation files (net `+222`), including deterministic DEBUG fixtures and removal of confirmed-dead presentation code. No new production file, store, provider, coordinator, or persistence type.
- Main trade-off: extremely stable and accessible, but unavailable metrics remain visible as rows and the result feels more utilitarian than celebratory.

## Rejected historical Concept B — In-place Finish, Adaptive Highlight

### Ending presentation: top to bottom

1. Preserve the accepted active shell frame and phase position, but replace live HR, zone scale, metrics, and controls with a single in-place ending surface; no stale live values remain on screen.
2. Phase changes to `ЗАВЕРШАЕМ`, followed by `Завершаем тренировку…` and the same factual treadmill row driven by `stopTruthStatusText`.
3. The lower shell shows `Готовим результат`; only the safe return action is available while projection identity is unresolved.

### Completed summary: top to bottom

1. The ending surface transforms into `Итог тренировки` within the same Training destination.
2. Primary result is `N мин в Зоне M` from exact target-zone exposure. This is a sentence-like result, not a tile.
3. A compact two-value belt shows duration and average HR. Factual average speed appears as one tertiary text row only when available.
4. Full-width `Готово` returns to Training Hub; `Статистика` opens the existing tab/history.

### Visible metrics and exact fallbacks

- Target-zone exposure: `zoneSeconds[selectedZoneIndex]` plus same-session selected zone index; when unavailable, it is omitted and duration becomes the primary result.
- Duration: `durationSeconds`; when nil, omit it from the belt. If target-zone exposure is also unavailable, the primary area becomes `Результат доступен частично` with no fabricated number.
- Average HR: `averageHeartRate`; omit when nil.
- Average speed: show only factual `averageSpeed` as `Средняя скорость N км/ч`; omit when nil or estimated.
- Distance and all other removed active/dashboard metrics do not appear.

### Partial or unavailable summary

- Available facts compact upward; one footer sentence `Не все данные тренировки доступны` explains omitted values without listing technical reasons.
- If no exact projection is identifiable, the surface reads `Итог пока недоступен` and shows only return/history actions.
- Stop confirmation uncertainty remains a separate safety row; result availability never implies physical stop confirmation.

### Transition, accessibility, impact, and trade-offs

- Transition: a restrained phase/title crossfade and size change within the existing shell; no persistent animation. Reduce Motion swaps content immediately and preserves focus.
- Dynamic Type: the result sentence changes from one line to centered multiline; the two-value belt becomes a vertical list. Compact height may scroll content, while the return action remains in a safe-area inset.
- VoiceOver: the adaptive primary result is announced first, followed only by present metrics; omission is summarized once. Focus moves from ending heading to result heading, not through removed live elements.
- Light/dark: semantic surfaces and text; zone color may accent the result only alongside the explicit `Зона M` label.
- Approximate production impact after selection: 230–330 LOC added/changed in the existing shell/presentation boundary and DEBUG fixtures/tests, plus the same possible 250–450 LOC dead-presentation removal after verification. No new production file or architecture layer.
- Main trade-offs: strongest visual continuity and the smallest completed result when zone exposure exists, but the hierarchy changes when data is partial, target-zone identity needs careful same-session retention, and adaptive layout/focus behavior costs more QA.

## Design state matrix

| State | Required presentation in both concepts |
| --- | --- |
| Ending, stop confirming | Neutral ending heading plus `Проверяем остановку дорожки`; no success or save claim. |
| Ending, stop confirmed | May show `Дорожка остановлена` from the existing confirmed stop fact; summary remains independently gated. |
| Ending, stop unconfirmed/unavailable | Explicit safety wording and existing alert; result must not conceal or downgrade the warning. |
| Completed summary | Unique new native V2 projection with complete lifecycle; show only selected factual metrics. |
| Partial summary | Keep/omit nil fields exactly as each concept defines and announce partiality once; never zero-fill. |
| Unavailable summary | No workout guess and no numeric placeholders; offer Training and existing Statistics/history paths. |
| Light / dark | Semantic backgrounds/materials and tested contrast; symbol/text duplicate every tint meaning. |
| Dynamic Type / compact height | Flexible number/label layout, vertical fallbacks, scrollable result, bottom action safe-area inset. |
| VoiceOver | Deterministic heading-first focus, complete metric labels/values, meaningful unavailable announcements, aggregate HR/zone-scale value. |
| Reduce Motion | Immediate state replacement; no numeric travel, decorative pulse, or mandatory transition animation. |
| Navigation | `Готово` returns to current Training Hub; `Статистика` uses the existing root tab/history. No Details screen. |

## Recommendation

PM selected **revised Concept A — Quiet Finish, Stable Result** with factual distance as the preferred hero, duration fallback, and exact Z1–Z5 exposure. The separate compact ending remains the simplest truthful bridge and preserves the minimal-text direction accepted in Goals 1–2.

## PM selection gate

- Revised Concept A is frozen by the [final PM approval](https://github.com/tourvald/walkingpad-remote/issues/59#issuecomment-5381678119).
- Production SwiftUI, fixtures, focused tests, narrow presentation cleanup, build, and visual QA are authorized within `selected-direction.md`.
- Runtime/control/safety, cooldown, stop evidence, HealthKit/Watch, Telemetry V2, persistence, and workout truth remain unchanged.
