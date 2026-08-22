# Issue #56 redesign brief

Status: refined Concept B approved and frozen for Issue #56 implementation.

## Scope and contract

- Screen/flow: primary `Training` tab, idle Training Hub, and the compact preparing/preflight presentation immediately after the existing Start request.
- Primary user: a person preparing to begin the current HR Control workout, often reading the phone at arm's length near the treadmill.
- Single problem: the current idle screen behaves like an HR-Control telemetry/configuration dashboard, so workout readiness, the selected goal, and Start are not glanceable.
- Exact base: `22bd8bdbccf1be82e3b66c3b17e4fb0b22099caa` (`origin/main`, fetched 2026-08-22).
- Frozen writable paths: `ContentView.swift`, the existing `HeartRateLegacyBehaviorContractTests.swift`, and `docs/design/{redesign-brief,selected-direction,qa-ledger}.md`.
- Read-only evidence paths: `ContentView.swift`, `CommonInfoCard.swift`, `ContentSharedUIComponents.swift`, and existing runtime readiness facts in `BluetoothManager.swift` / `HRDomainService.swift`.
- Acceptance evidence for this pass: current-code audit, simulator screenshot from the exact base on iPhone 17 / iOS 27.0, exactly two recorded concepts, and redesign scope check.
- Mock inputs for later preview/test work: idle ready; treadmill unavailable; HR unavailable/stale; known and unknown HR source identity; simple preparing; preview-only `Work 2/4` and `Zone 5` future-mode values.

## Required states and form factors

- Normal: HR Control selected, treadmill ready, fresh accepted HR available, concise goal visible, Start enabled.
- Loading/preparing: compact indeterminate progress and truthful prerequisite/status copy derived from existing runtime facts; no new countdown or authorization state.
- Empty: no separate production no-mode state is needed because HR Control exists today; unavailable factual values use `—` or an explicit unavailable status rather than fabricated zeroes.
- Error/degraded: treadmill unavailable and HR unavailable/stale remain separate, actionable statuses; exact HR source is omitted when unknown.
- Disabled: Start availability stays at parity with the accepted current affordance inputs; Telemetry/history readiness never becomes a gate.
- Accessibility: useful VoiceOver grouping/order, status conveyed by text and symbol rather than color alone, Dynamic Type without three-column compression, sufficient contrast, and Reduce Motion-safe progress.
- Form factors: compact-width iPhone portrait is primary; compact-height/landscape and regular-width iPad should keep the same hierarchy without adding content. watchOS UI is out of scope.

## Existing patterns to preserve

- Native SwiftUI, SF Symbols, semantic system colors/materials, grouped backgrounds, `NavigationStack`, `Button`, `ProgressView`, and existing sheets/navigation for device selection and HR parameters.
- Reuse the existing `Card` / `PrimaryActionButton` only where they support the selected hierarchy; do not create a token or design-system layer for this Goal.
- Presentation observes existing accepted runtime facts and calls the existing Start action; it does not own lifecycle or authorization.

## Prioritized audit findings

1. The root tab and first card are named `HR-control`, making the entry point a single-feature console rather than the universal `Training` destination required by #56.
2. Before Start, `CommonInfoCard` presents nine live/accumulated metrics, including distance, steps, averages, beats-per-meter, and speed delta. Most are empty or zero and do not help choose or start a workout.
3. On the exact-base iPhone 17 simulator, the metric dashboard plus configuration cards push the primary Start action below the initial viewport; the most important action is not glanceable.
4. Readiness is modeled as `Treadmill` plus `Watch`; `Watch offline` and the Watch-specific issue affordance conflate HR availability/freshness with one transport/device identity.
5. Readiness and failure guidance are scattered across the top tiles, Watch alert, disabled Start subtitle, and trailing status strip, so the user must reconcile several surfaces before acting.
6. The idle hierarchy exposes implementation detail (`Adaptive` step, cooldown limits) alongside goal choice, while the selected mode, target, and duration are not summarized as one clear workout intent.
7. Nested cards, repeated gradients/strokes, three-column metrics, and small captions create competing emphasis and fragile Dynamic Type behavior; decorative weight is highest where decision value is lowest.
8. The idle-to-running transition has no concise preparing/preflight presentation. Any new preparing state should only reflect existing prerequisites and must not become a parallel workout state machine.

## Frozen problem statement

Replace the dense HR-Control-specific idle dashboard with a sparse Training entry point that answers, in order: what workout is selected, what is its current goal, whether the treadmill and fresh HR are ready, and whether Start is available. Preserve every runtime/control decision and keep future-mode readiness limited to a small generic presentation shape proven by deterministic preview/test values.

## Concepts

Both concepts use the same deliberately small foundation: one immutable presentation value carrying mode/title, an optional phase label, one primary target/status, a small secondary metric collection, generic HR availability/freshness plus an optional truthful source label, and an unavailable/warning message only when needed. Current HR Control gets the only production mapping. `Intervals · Скоро` is a disabled production selector placeholder; richer Intervals and Weekly Zones Auto examples remain deterministic preview/test values and cannot start runtime behavior.

### Concept A — Readiness-first compact stack

- Screen hierarchy/layout: large `Training` navigation title; one compact workout-summary card; two full-width readiness rows; one dominant Start action at the bottom of the content. `Goal` / `Settings` is a secondary disclosure from the summary instead of an always-expanded configuration grid.
- Before Start: `HR Control`, selected zone/target, duration, and a concise cooldown note only if it materially affects the choice. No steps, distance, averages, speed delta, or pre-session zeroes.
- Treadmill and HR readiness: separate text-led rows with symbol + status. The treadmill row can retain access to the existing device picker. The HR row leads with `Pulse available • 128 bpm` or `Pulse unavailable/stale`; a reliably known source is secondary (`Apple Watch`, for example), otherwise it says `HealthKit` / `Pulse available` and never guesses a device.
- Primary action: full-width native `Button` / existing `PrimaryActionButton`, visually isolated after readiness. Disabled state is obvious; the first actionable blocker is placed directly above the button rather than packed into its label. Preparing replaces the action area with a compact `ProgressView` and existing prerequisite/status copy.
- Glanceability/future modes: the reading path is one vertical answer sequence: workout → goal → two prerequisites → Start. The summary's generic primary/secondary fields can show `Work 2/4` or `Zone 5` preview values without altering the shell.
- Approximate implementation complexity/code footprint: low; likely one small presentation value plus pure HR-Control mapping co-located at the current presentation boundary unless focused tests justify one new file, two small reusable rows/metrics, and about 180–280 production lines changed/added while removing a comparable obsolete idle path.
- Main trade-offs: strongest YAGNI and Dynamic Type fit, but intentionally restrained visually; changing the full goal configuration is one secondary navigation step rather than an always-visible zone grid.

### Concept B — Refined mode-and-target hero

#### Screen representation

```text
┌─ Training ───────────────────────────────┐
│  [treadmill ✓]   [heart 128 ✓]          │  compact, secondary readiness
│                                          │
│  ┌─ WORKOUT MODE ────────────────────┐   │
│  │ HR Control                     ▾  │   │  native Menu/select button
│  │                                      │
│  │              Zone 3                  │  dominant configured target
│  │             135–142 bpm              │
│  │                                      │
│  │  Z1 ━━━━━│ Z2 ━━│ Z3 ━━│ Z4 ━│ Z5  │  tappable segmented HR scale
│  │           ▲ selected target          │  future current-HR marker fits here
│  │                                      │
│  │  10 min        Cooldown to 115 bpm   │  mode-specific information
│  │  Speed adapts to hold the target.    │
│  │                           Settings › │
│  └──────────────────────────────────────┘
│                                          │
│  First actionable blocker, only if any   │
│  [              Start workout          ]│  always visible without scrolling
└──────────────────────────────────────────┘
```

- Top-to-bottom hierarchy: `Training` title; one quiet readiness row; a single visually dominant hero containing the mode selector, current mode configuration, and mode-specific information; optional actionable blocker; full-width Start. Freed space stays empty rather than becoming more cards.
- Workout-mode selector: the hero starts with a labelled native `Menu` / selection button (`HR Control` + chevron). Production also shows `Intervals · Скоро` as a disabled, non-startable placeholder implemented directly in the Menu; it has no mode registry, router, provider, persistence, or runtime type. Deterministic previews may instantiate richer Intervals and Weekly Zones Auto presentation values directly.
- HR Control target selection: a horizontal segmented zone scale is built from native `Button`, `Capsule`, and `Shape` primitives. The selected zone/range has a strong outline/fill and target marker; the dominant target reads as a zone plus configured range (for example `Zone 3` and `135–142 bpm`), never as one target bpm. Each segment has a 44-point hit target and explicit VoiceOver label. Tapping another zone preserves the existing target-setting behavior. During a later active-workout Goal, the same scale can add a separate current-HR marker moving relative to the selected range without changing control authority.
- Compact readiness: directly below the title, two low-emphasis chips show `treadmill ✓` and `heart 128 ✓`. Unavailable/stale states replace the checkmark with an explicit symbol and short label. The HR chip represents availability/freshness, never Watch reachability; exact source appears only as a small secondary label when reliably known, otherwise the truthful generic identity is `HealthKit` / `Pulse available` or is omitted.
- Mode-specific information area: it is the lower portion of the same hero, not another generic card. HR Control shows duration, cooldown target, and at most one concise explanation of adaptive target holding. `Settings` leads to existing workout parameters. There is no standalone `Heart Rate Zones` menu on the Training screen; global zone definitions stay in Settings.
- Primary action/preparing: Start remains full-width and visible without required scrolling, using semantic accent styling rather than a prescribed orange/neon treatment. A disabled state has one short blocker immediately above it. After the existing Start request, the same action area becomes a compact native `ProgressView` plus truthful existing-state copy; no countdown or presentation lifecycle is added.
- Native visual language: system typography, materials/grouped background, semantic colors, SF Symbols, native controls, and a small SwiftUI zone scale. No photography, bitmap chrome, mandated dark theme, glow language, or new token layer.
- Glanceability/future active reuse: mode name and configured target own most visual weight; readiness remains visible but peripheral. The HR scale establishes a visual grammar that can later add factual current HR during Goal #58 while remaining observational and downstream from runtime truth.

#### Preview-only mode examples

- Weekly Zones Auto: mode title `Weekly Zones Auto`; hero primary value `15 min remaining this week`; the mode-specific area shows `Zone 5 • 3 min remaining` and `Zone 4 • 12 min remaining`. Start is non-operative in the fixture; no weekly engine, persistence, or algorithm exists.
- Intervals: mode title `Intervals`; hero primary value `4 × 3 min`; the mode-specific area shows `Work 3:00 • Recovery 2:00` and the planned round count. Start is non-operative in the fixture; no interval runtime or state machine exists.
- Both fixtures populate the same generic mode/title, primary target/status, and small secondary metric slots directly. They do not require production mode enums, option registries, specialized mappers, or navigation routes.

#### Complexity and trade-offs

- Approximate production impact: medium, about 260–390 changed/added production LOC while removing the obsolete idle metric/configuration composition. Expected ownership is primarily existing `ContentView.swift` / shared UI components, plus one small immutable presentation value and pure HR-Control mapping; keep them co-located unless focused tests establish a concrete reason for one new file. The zone scale can start as a focused local component and move only when Goal #58 creates real reuse.
- Expected preview/test impact: deterministic ready/unavailable/source/preparing fixtures plus direct Weekly Zones Auto and Intervals values; no production behavior or future-mode code.
- Main trade-offs: more custom accessibility and layout QA than Concept A, and a one-option production Menu is temporarily modest in utility. In return, the selected mode and target become unmistakable, Start stays visible, and the HR visual can be reused later without making readiness or settings dominate the screen.

## Recommendation

Implement frozen **Concept B**. It keeps the selected expressive goal-first hierarchy, reduces readiness to secondary chips, exposes the committed Intervals direction only as a disabled placeholder, and keeps all richer future-mode proof in deterministic preview/test data.

## PM selection

PM approved refined Concept B for Freeze → Implement → Verify in [Issue #56 comment 5380900151](https://github.com/tourvald/walkingpad-remote/issues/56#issuecomment-5380900151). Concept A is rejected because its status/settings stack makes the workout goal less visually dominant.

## Non-goals and safety boundary

- No production SwiftUI changes in this pass.
- No providers, registries, factories, coordinators, DI, mode routers, future-mode production types, or second workout state machine.
- No changes to HR-control behavior or authorization, HR freshness/source selection, BLE, treadmill commands, speed/control safety, controller units, cooldown/stop semantics, HealthKit truth, Watch workout lifecycle, Telemetry V2, persistence, project settings, signing, install, device launch, or physical hardware activity.
- No speculative Intervals or Weekly Zones Auto runtime; no countdown unless a later selected design proves it valuable without new machinery.
