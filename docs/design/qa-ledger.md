# Redesign QA ledger

Status: passed for the frozen Issue #56 presentation scope.

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

DEBUG fixture safety is covered by `HeartRateLegacyBehaviorContractTests`: preview-only modes report `canStart == false`, the fixture source contains no production control or telemetry entry points, and fixture launches skip root manager startup/scene lifecycle actions.

Normal visual QA is limited to two correction passes. If a P0–P2 finding remains, or a correction would cross the approved presentation-only write set, return to PM.
