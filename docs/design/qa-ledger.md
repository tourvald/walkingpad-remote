# Redesign QA ledger

Status: passed for the frozen Issue #58 presentation scope.

## Issue #58 — active HR Control and cooldown

| Pass | State / form factor | Severity | Finding | Evidence | Owner path | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline | Below / in / above zone, iPhone 17, light | P0 | Factual HR is dominant; the separate marker moves across the reused Z1–Z5 scale; the full selected-zone bounds and symbol-backed relation remain visible. | `/private/tmp/issue58-active-below.png`, `/private/tmp/issue58-active-in-zone-controls.png`, `/private/tmp/issue58-active-above.png` | `ContentView.swift` | Pass |
| Baseline | Known and unknown HR source, iPhone 17, light | P0 | HR readiness stays compact and source-agnostic; an available factual source label is optional and never Watch-first. | `/private/tmp/issue58-active-known-source.png`, `/private/tmp/issue58-active-in-zone-controls.png` | `ContentView.swift` | Pass |
| Baseline | Missing HR / speed / treadmill, iPhone 17, light | P0 | Degraded facts render as unavailable or an em dash without inventing control truth; the target zone remains visible. | `/private/tmp/issue58-active-no-hr.png`, `/private/tmp/issue58-active-no-speed.png`, `/private/tmp/issue58-active-disconnected.png` | `ContentView.swift` | Pass |
| Baseline | Cooldown above / at threshold, iPhone 17, light | P0 | Cooldown reuses the same shell, keeps current HR dominant, and replaces the zone target with the existing recovery threshold and a separate threshold line. | `/private/tmp/issue58-cooldown-above.png`, `/private/tmp/issue58-cooldown-reached.png` | `ContentView.swift` | Pass |
| Baseline | Intervals / Weekly Zones fixture, iPhone 17, light | P1 | Future-mode fixtures reuse the same presentation shape only; no runtime mode or state machine was added. | `/private/tmp/issue58-active-intervals.png`, `/private/tmp/issue58-active-weekly-zones.png` | `ContentView.swift` | Pass |
| Correction 1 | Active controls, iPhone 17, light | P2 | Safe no-op fixtures initially dimmed Stop and `+5 мин`, hiding their production visual hierarchy. | `/private/tmp/issue58-active-in-zone-controls.png` | `ContentView.swift` | Fixed: preview actions remain guard-blocked but render with production styling. |
| Correction 1 | Active, iPhone 17, dark | P1 | Primary HR, marker, selected zone, relation status, secondary metrics, and controls remain legible in dark appearance. | `/private/tmp/issue58-active-in-zone-dark.png` | `ContentView.swift` | Pass |
| Correction 1 | Active / cooldown, iPhone 17, Accessibility XL | P1 | Large type preserves the dominant HR, scale, target, and fixed Stop; secondary content remains reachable in the existing scroll view. | `/private/tmp/issue58-active-in-zone-axxl.png`, `/private/tmp/issue58-cooldown-above-axxl.png` | `ContentView.swift` | Pass |
| Correction 1 | Active, iPad, regular width | P1 | The same sparse hierarchy remains coherent at regular width and uses native iPad tab placement. | `/private/tmp/issue58-active-in-zone-ipad.png` | `ContentView.swift` | Pass |
| Correction 2 | Secondary action hit target | P2 | Independent review found the fixed `+5 мин` slot was only 38 pt high. | `/private/tmp/issue58-active-in-zone-pass2.png` plus source inspection | `ContentView.swift` | Fixed: native large control sizing in a stable 48-pt slot. |
| PM review | Active factual speed source | P1 | Production presentation could fall back from device-reported speed to modelled `manager.speedKmh`. | `/private/tmp/issue58-speed-active-no-speed.png` plus focused source contract | `ContentView.swift` | Fixed: app-reported speed, then raw-reported speed; otherwise unavailable. |
| Final review | Accessibility, motion, and action stability | P1 | VoiceOver follows source order, state is not color-only, marker animation respects Reduce Motion, Stop stays in one bottom inset, and `+5 мин` keeps a fixed secondary slot. | Source inspection plus fixture screenshots | `ContentView.swift` | Pass |
| Final review | Compact-height attempt | P3 | The headless Simulator host exposes no supported orientation command. Scrolling, pinned Stop, regular-width iPad, and Accessibility XL were verified instead. | Same `simctl` environment limitation recorded during Goal #56 | QA environment | Accepted limitation; no P0–P2 finding. |

DEBUG fixture safety is covered by `HeartRateLegacyBehaviorContractTests`: fixtures contain no production control or telemetry entry points, launch guards skip manager lifecycle startup, and active buttons return before callbacks.

## Issue #56 — Training Hub baseline (historical)

| Pass | State / form factor | Severity | Finding | Evidence | Owner path | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline | Ready, unknown HR source / iPhone 17 / light | P0 | Frozen hierarchy, generic HR readiness, mode menu, zone range, metrics, and pinned Start are present. | `/private/tmp/issue56-ready-unknown-source.png` | `ContentView.swift` | Pass |
| Baseline | Ready, known HR source / iPhone 17 / light | P0 | A factual source label is optional presentation data; no Apple-Watch-specific readiness is required. | `/private/tmp/issue56-ready-known-source.png` | `ContentView.swift` | Pass |
| Baseline | Treadmill unavailable / iPhone 17 / light | P0 | Treadmill readiness reports unavailable and Start stays disabled. | `/private/tmp/issue56-treadmill-unavailable.png` | `ContentView.swift` | Pass |
| Baseline | HR unavailable / iPhone 17 / light | P0 | Heart Rate readiness reports unavailable and Start stays disabled without naming a provider. | `/private/tmp/issue56-hr-unavailable.png` | `ContentView.swift` | Pass |
| Baseline | Preparing / iPhone 17 / light | P1 | Preparing treatment is testable through a DEBUG-only fixture and cannot issue a production start. | `/private/tmp/issue56-preparing.png` | `ContentView.swift` | Pass |
| Baseline | Intervals and Weekly Zones preview modes / iPhone 17 / light | P0 | Both future modes reuse the same small presentation shape; Start is disabled and no runtime mode exists. | `/private/tmp/issue56-intervals.png`, `/private/tmp/issue56-weekly-zones.png` | `ContentView.swift` | Pass |
| Baseline | Actual production unavailable state / iPhone 17 / light | P0 | Production mapping reflects current manager facts and does not fabricate readiness or a source. | `/private/tmp/issue56-production-unavailable.png` | `ContentView.swift` | Pass |
| Correction 1 | Selected Z3 / iPhone 17 / light | P2 | Yellow selected-segment label had insufficient contrast. | `/private/tmp/issue56-ready-unknown-source.png` | `ContentView.swift` | Fixed: selected label now uses `Color.primary`. |
| Correction 1 | Ready / iPhone 17 / dark | P1 | Hierarchy, semantic colors, and materials remain legible in dark appearance. | `/private/tmp/issue56-ready-dark.png` | `ContentView.swift` | Pass |
| Correction 2 | Ready / iPhone 17 / Accessibility XL | P2 | The mode name wrapped and the CTA consumed excessive height. | `/private/tmp/issue56-ready-accessibility-xl-pass2.png` | `ContentView.swift` | Fixed: resilient one-line labels with scaling; Start remains pinned and target remains visible. |
| Correction 2 | Ready / iPad / regular width | P1 | The compact hierarchy remains coherent at regular width and uses native iPad tab placement. | `/private/tmp/issue56-ready-ipad.png` | `ContentView.swift` | Pass |
| Independent review | DEBUG fixture launch | P1 | Fixture presentation originally still allowed root manager lifecycle startup. | Source review and contract test | `ContentView.swift` | Fixed: DEBUG fixture launches now skip manager startup and scene lifecycle actions; fresh re-review found no P0–P2. |
| Final review | Code accessibility and localization resilience | P1 | Interactive controls use native `Button`, `Menu`, segmented buttons, and labels; concise unavailable copy and line limits tolerate Russian and large type. VoiceOver reading order follows source order. | Source inspection plus Accessibility XL fixture | `ContentView.swift` | Pass |
| Final review | Compact-height attempt | P3 | The headless Simulator host exposes no orientation command, and its active screen mode rejected a landscape geometry. Portrait small-screen scrolling and pinned Start were verified instead. | `simctl io screenConfig geometry 2622x1206@3` rejected as unsupported | QA environment | Accepted limitation; no P0-P2 finding. |

Goal #56 DEBUG fixture safety remains covered by `HeartRateLegacyBehaviorContractTests`: preview-only modes report `canStart == false`, the fixture source contains no production control or telemetry entry points, and fixture launches skip root manager startup/scene lifecycle actions.

Normal visual QA is limited to two correction passes. If a P0–P2 finding remains, or a correction would cross the approved presentation-only write set, return to PM.
