# Issue #58 redesign brief

Status: Concept A with the live zone-lane refinement approved and frozen for implementation.

## Scope and contract

- Screen/flow: the active `Training` shell for the current HR Control workout and its cooldown phase.
- Primary user: a person walking or running on a treadmill and reading the phone at workout distance with brief glances.
- Single problem: the accepted active screen is still a dense HR-control/debug dashboard, so factual current HR, relation to the selected physiological zone, factual speed, elapsed time, and Stop do not form one stable glanceable hierarchy.
- Exact base: `56e01483ff144c29fe803f8870c0ae0174482e08` (`origin/main`, fetched 2026-08-22; merge of accepted PR #61).
- Binding handoff: [Issue #58 PM comment 5381106684](https://github.com/tourvald/walkingpad-remote/issues/58#issuecomment-5381106684).
- Writable path for this pass: `docs/design/redesign-brief.md` only.
- Read-only evidence: `ContentView.swift`, `CommonInfoCard.swift`, `ContentSharedUIComponents.swift`, the accepted Goal-1 presentation/zone scale, and existing factual UI inputs in `BluetoothManager.swift`.
- Evidence for this pass: exact-base source audit and existing deterministic workout/cooldown preview fixtures. No production SwiftUI, build, install, device, BLE, or treadmill action is authorized.

## Prioritized audit findings

1. The active screen is three competing layers—large treadmill/Watch tiles, a nine-metric `CommonInfoCard`, then a scrollable HR-control card—rather than one workout shell. Collapse these into one hierarchy and keep readiness peripheral.
2. `CommonInfoCard` gives current HR, speed, and persistent speed delta equal 40-point weight. Current factual HR needs to be the single dominant live value; speed becomes secondary and persistent delta disappears.
3. Active target feedback compares HR with internal `hrTargetBPM` and a small color change, but never shows the selected physiological zone and full bounds established by Goal 1. Replace this with the accepted Z1–Z5 grammar, a factual HR marker, and explicit relation to the selected band.
4. Current relation is effectively color-only and based on a hidden single-bpm comparison. Add symbol plus short text (`Ниже зоны`, `В зоне`, `Выше зоны`) so meaning survives color-vision differences, dark mode, and workout distance.
5. Steps, average HR, average speed, beats-per-meter, distance, and speed delta occupy two permanent grid rows. Remove them from the active focus; retain only elapsed time and factual speed, with distance optional only in the denser concept.
6. Progress percentage, next-decision countdown, predictor text, algorithm decision details, and status prose occupy more space than live physiological state. Remove these engineering/control explanations from the persistent shell; presentation must not expose or reinterpret predictor/deadband behavior.
7. Time is duplicated as elapsed time in the metrics grid and dominant remaining time in the HR card, while `+5 min` and Stop share a narrow side column. Use one clear elapsed-time fact and a stable bottom action area with an intentionally secondary extension control.
8. Cooldown changes tint and some labels but keeps the same debug-heavy card; Stop also moves to a different location. Keep the same sparse shell and control placement, changing only phase, recovery target/status, and allowed secondary action.

## Required states and form factors

- Active HR Control: current HR below, inside, and above the selected zone; selected zone number and full bounds always visible.
- Degraded: HR stale/missing, treadmill disconnected, and factual speed unavailable use `—` plus explicit short status; no zero or estimate is fabricated to fill the layout.
- Cooldown: recovering above the accepted cooldown target and recovery target reached, using the same shell rather than a separate dashboard.
- Ending: show a compact pending state only if an existing accepted runtime fact truthfully exposes it; do not invent a presentation lifecycle.
- Future preview/test values: Intervals `Work 2/4` and Weekly Zones Auto `Zone 5` populate the same phase, primary metric/status, target band, and secondary metrics without runtime invocation.
- Accessibility: VoiceOver groups current value with relation/target, status never relies only on color, Dynamic Type preserves HR/Stop priority, Reduce Motion disables marker animation, and all actions keep 44-point targets.
- Form factors: compact-width iPhone portrait is primary; compact-height and regular-width reuse the same content without adding metrics. Light and dark appearance are required later in Verify.

## Existing language to preserve

- Native SwiftUI, SF Symbols, semantic system colors/materials, monospaced live numerals, and the Goal-1 segmented Z1–Z5 `Capsule` grammar.
- The user-facing workout target is `Зона N` plus its complete configured bounds. Internal midpoint, `hrTargetBPM`, deadband, predictor, and speed decisions remain hidden implementation detail.
- Readiness is `Дорожка` and source-agnostic `Пульс`; a source label appears only when factually known. Apple Watch is not a readiness category.
- Presentation observes accepted runtime facts and existing actions. It never owns control, cooldown, Stop, or lifecycle decisions.

## Concept A — Number-first Focus Stack

### Layout and live hierarchy

1. Compact top row: phase (`HR‑контроль · Тренировка`) plus small treadmill and Heart Rate status chips.
2. Centered live hero: a very large factual current HR value with `bpm` and one explicit relation label.
3. Goal-1 Z1–Z5 rail: selected zone outlined, full bounds written directly below, and a small current-HR marker positioned over the scale.
4. Two equal secondary facts: factual current speed and elapsed workout time. Distance is omitted.
5. Stable bottom action area: secondary `+5 мин` during the main phase and the existing full-width destructive `Стоп` action in the same position in every phase.

### Zone scale and non-color status

- The five Goal-1 capsule segments remain visually familiar but become observational during a workout.
- A labelled needle/triangle marks factual current HR. When HR falls beyond the visual domain, the marker clamps to an edge and adds a directional chevron rather than disappearing.
- Relation is always redundant: `arrow.down` + `Ниже зоны`, `checkmark` + `В зоне`, or `arrow.up` + `Выше зоны`. Selected `Зона N · lower–upper bpm` stays visible; color is only reinforcement.
- Missing/stale HR removes the marker and replaces the hero value with `—` plus `Пульс недоступен`.

### Cooldown transformation

- The same shell changes phase to `Заминка`; current HR remains dominant, speed/time stay in place, and Stop does not move.
- The rail accepts the existing cooldown recovery target as a presentation band (`до N bpm`) and reports `Выше цели` or `Цель достигнута` with symbol plus text. The completed workout-zone band may remain faint context but is no longer presented as the active recovery target.
- `+5 мин` disappears; no cooldown countdown, stability rule, or completion behavior is recreated in presentation.

### Scope, complexity, and trade-offs

- Approximate impact: low-to-medium, roughly 280–380 production LOC changed/added while removing about 400–550 LOC of obsolete active composition; likely a net reduction. Reuse and minimally extend the existing presentation value/target segments in `ContentView.swift`; no new framework or production mode type.
- Future modes: the same phase + primary value + target band + secondary facts can render deterministic Intervals/Weekly Zones fixtures without providers or runtime code.
- Benefits: strongest workout-distance readability, smallest implementation, robust Dynamic Type, and an unmistakable single focus.
- Trade-offs: the HR-to-zone relationship is secondary to the number; omitting distance is deliberately austere, and the marker carries less comparative detail than Concept B.

## Concept B — Scale-first Live Zone Lane

### Layout and live hierarchy

1. Compact top strip: phase on the left; treadmill and generic HR-source status on the right.
2. Edge-to-edge live zone lane as the hero: five native capsule segments, selected zone expanded/outlined, and a large marker bubble containing factual current HR.
3. Immediately below the lane: explicit relation label and selected zone with full bounds.
4. Compact three-item metrics belt: factual speed and elapsed time are primary secondary facts; distance is a smaller optional third fact.
5. Bottom action dock: secondary `+5 мин` and the existing full-width `Стоп` control, never pushed into scroll content.

### Zone scale and non-color status

- Current HR is still the largest live numeral, but it lives inside the marker bubble and visibly travels relative to the selected target band.
- Selected-zone width/outline, marker position, and explicit symbol/text communicate state together. The marker uses down/check/up shapes and labels, not color alone.
- Out-of-range HR clamps with a visible overflow arrow and numeric value. Missing HR leaves a dashed marker slot labelled `Нет пульса`; the selected target remains visible.
- Motion uses a short value transition only when Reduce Motion is off; the concept remains understandable with an immediate position update.

### Cooldown transformation

- The lane stays in place and changes its highlighted band from the physiological workout zone to the existing recovery interval `≤ cooldown target`; current HR bubble continues moving on the same coordinate grammar.
- Phase/title becomes `Заминка`; relation becomes `Выше цели` / `Цель достигнута`; factual speed, elapsed time, and Stop retain their positions. Distance can remain if PM accepts the three-item belt.
- No separate cooldown view hierarchy or presentation state machine is introduced.

### Scope, complexity, and trade-offs

- Approximate impact: medium, roughly 380–520 production LOC changed/added while removing about 400–550 LOC of obsolete active composition. The extra cost is native layout/marker geometry, overflow behavior, Dynamic Type, and VoiceOver QA—not architecture.
- Future modes: the lane can visualize an interval work/recovery band or weekly-zone target from deterministic presentation values; no runtime mode implementation is implied.
- Benefits: strongest continuity with the Goal-1 zone selector and clearest immediate understanding of where current HR sits relative to the target.
- Trade-offs: more custom layout math and accessibility QA, greater risk of marker clipping at large type/compact height, and slightly weaker long-distance numeral dominance than Concept A.

## Recommendation

Recommend **Concept A — Number-first Focus Stack**. It best matches the workout-distance use case: current HR is readable first, relation to the full selected zone is still explicit and visual, Stop stays fixed, and the cutover can remove substantially more dashboard code with less layout machinery. Concept B is more expressive but spends extra complexity on a moving lane when a large number plus compact marker already satisfies the accepted product semantics.

## PM selection

- PM approved Concept A with the observational live-marker refinement from Concept B in [Issue #58 comment 5381177403](https://github.com/tourvald/walkingpad-remote/issues/58#issuecomment-5381177403).
- Concept B is rejected as the primary hierarchy because the scale-first treatment adds layout/QA complexity and weakens current-HR readability at workout distance.
- Freeze, implementation, and verification must preserve the exact scope and hard boundaries recorded below.

## Non-goals and hard boundaries

- No production SwiftUI or preview implementation in this pass.
- No providers, factories, registries, DI, coordinators, mode routers, future-mode runtime types, or additional workout state machine.
- No change to HR-control target/deadband/predictor decisions, HR freshness/source selection, speed cadence/delta, treadmill commands/order/retries/bounds, BLE, controller-unit safety, Stop confirmation/evidence, cooldown runtime, HealthKit, Watch lifecycle, Telemetry V2, persistence, Xcode settings, signing, install, device launch, BLE activity, or treadmill activity.
