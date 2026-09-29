# UI evolution review

Status: Focus native implementation completed locally under the owner's full PM delegation on 2026-09-12. Verification and limits: [native QA](native-qa.md), including the owner-requested stationary zone/time follow-up and its zero-shift native measurements.

## Objective and delivery

Create a coherent premium native iOS experience, not just a new Training card. The full goal includes Training preparation, active workout, cooldown, ending/result, Statistics/history, Plank, parameters/profiles, device selection, and consistent diagnostic presentation. Review the companion Watch screen for consistency without changing its workout/HR behavior.

Implement in three reviewable passes after selection: (1) shared visual styles and the full Training lifecycle, including PiP space; (2) Statistics/history, Plank, parameters and device selection; (3) integrated accessibility, appearance and interaction QA, including the companion screen. An individual pass does not complete the overall objective. Screenshots/builds do not establish market leadership or field usability.

## Authority and current state

- Exact live `main`: `f7972a97c64f9310e3a82b32b8152b8d96e2e53a`, verified against GitHub on 2026-09-12.
- Isolated branch: `codex/ui-evolution`. The user's detached `4e08982` checkout and its unrelated untracked files are preserved.
- The approved writable source/test/documentation set is listed below; actual changes remain confined to that set.
- The owner delegated full PM discretion and authorized implementation. The parent agent selected Focus and recorded the decision in `selected-direction.md`; no further concept approval is needed.
- Historical `selected-direction.md` continues to own exact-session result identity and truthful unavailable/factual values. Current source owns later placement and publication corrections.

## Eight audit findings

1. Shared `Card` uses radius 16, Training 24, and Plank 20/22. Background glows and material borders vary across screens; the design-token file has no approved tokens. Consolidate a small set of semantic presentation styles.
2. Training preparation spends hierarchy on a large single-option mode surface, while settings, selected zone and time are not clearly distinguished. Keep the six duration choices and zone selection, but reduce decorative framing.
3. Active Training repeats its title/phase and uses several competing surfaces. Keep one main value, a useful zone relation and visible factual secondary values.
4. The owner explicitly needs an upper PiP area. Current active content occupies the upper screen; the accessibility inset places critical controls at the top. Recompose this screen below the reserved area and keep Stop in a fixed lower band.
5. At maximum Dynamic Type, the current native screenshot clips phase and readiness labels. Preserve large text and scrolling; do not rely on `minimumScaleFactor` or truncation for essential status.
6. Statistics/history exposes technical provenance, lifecycle/analysis codes and HealthKit identifiers alongside workout metrics. Preserve data access, but place technical detail behind disclosure and retain partial/unavailable explanations in plain language.
7. Several settings/readiness/period controls lack an explicit 44-point hit area. Plank's gesture-driven circle lacks an equivalent accessibility action. Fix these at existing presentation callbacks.
8. Plank has a fixed 270-point circle, fixed 58-point timer and a long introduction above the task. Make timer geometry adaptive and progression subordinate. Extend deterministic visual coverage beyond the existing Training fixtures.

Source owners: `ContentView.swift` (Training, results, settings, stats/history), `ContentSharedUIComponents.swift`, `PlankTimerView.swift`, `DevicePickerView.swift`. Source assertions were checked against the exact base, not historical screenshots alone.

## PiP contract

- Preserve an empty upper region in portrait and a leading video region in compact landscape for active, cooldown, unavailable-HR and disconnected states. Final native geometry and its bounded placement guarantee are documented in `native-qa.md`.
- Keep essential HR, factual speed, elapsed time and Stop below the region. Put Stop in a stable lower action band, visible without scrolling. Keep the existing confirmation for `+5 minutes`.
- Do not put a required navigation action, warning-dismissal button or workout value behind the sample PiP window. The production reserve contains no placeholder player, instruction card or mock video.
- Reserve geometry is adaptive. The native implementation was checked on SE, 17e, Pro Max and iPad in portrait/landscape. Video fitted within the reserve stays clear of critical content; arbitrary enlargement is outside that guarantee.
- On short screens or large text, preserve the reserve and visible Stop; allow secondary zone/detail content to scroll. Inspect HR visibility separately: a visible Stop alone does not pass the full requirement.
- Do not detect, move, resize or integrate third-party PiP. iOS lets the user move and resize its floating window; this layout supports an intended upper placement and cannot guarantee non-overlap at every user-chosen corner.
- A mock overlay proves intended geometry only. Final native app verification must reproduce the bounds in a simulator/preview. A real YouTube/physical-device session is separate evidence and requires the applicable authorization.

## Approved production write set

All paths below are relative to `ios/WalkingPadRemote/WalkingPadRemote/` unless noted:

- `WalkingPadRemote/ContentView.swift`
- `WalkingPadRemote/ContentSharedUIComponents.swift`
- `WalkingPadRemote/PlankTimerView.swift`
- `WalkingPadRemote/DevicePickerView.swift`
- `WalkingPadRemote/StatsRightAlignedBlock.swift`
- `WalkingPadRemote/DebugSharedUIComponents.swift`
- `WalkingPadRemote/DebugTrainingLogsCard.swift`
- `WalkingPadRemote/DebugHrFailuresCard.swift`
- `WalkingPadRemoteWatch Watch App/ContentView.swift` for visual consistency only
- `WalkingPadRemoteCoreTests/TrainingUIObservationBoundaryTests.swift` only if a production source-contract assertion must follow the accepted presentation change
- `WalkingPadRemoteCoreTests/HeartRateLegacyBehaviorContractTests.swift` only for existing ActiveWorkoutShell presentation assertions affected by the approved layout; preserve behavioral invariants
- Repository `docs/design/**`

Prefer existing components and semantic system colors over new files, packages or layers. Add isolated DEBUG fixtures only at existing preview boundaries. Do not add mock persistence, manager state or transport bypasses. Standard builds can discover same-folder SwiftUI changes without project configuration changes; no such change is proposed.

Read-only: `BluetoothManager`, services/engines, codecs, commands, HR/cooldown/freshness gates, units, speed bounds, telemetry, persistence, signing/entitlements, project configuration, deployment helpers. Preserve tab IDs, profile bindings, result identity, nil-versus-zero semantics, factual-versus-estimated speed and existing alert/export confirmations. Preserve `TrainingUIObservationBoundary` and its existing publication cadence; do not subscribe to raw accepted-HR timestamps.

## Concepts and demonstration limits

Exactly two current concepts are recorded in the parent brief. Focus keeps HR dominant; Tempo puts elapsed time first. Both use the same existing product states and the new PiP reserve. The HTML is a review mock, not the SwiftUI implementation.

`concepts.html` supports local zone/time selection, state navigation, statistics periods, mock Start/Stop, and the existing extend confirmation. The host's optional controls switch appearance, large text, PiP visibility and phone size. The PiP illustration and all values are synthetic; nothing connects to a device, stores a workout, opens YouTube or plays media. A mock Stop shows an ending state and never claims physical stop. Select Result explicitly to inspect the illustrative result.

The native baseline captures use existing DEBUG-only fixture launch arguments and synthetic sample values. No personal health data or device identifier is included in the screenshots.

## Acceptance and verification

The owner explicitly requires the final design to meet Apple standards. Treat the current Apple Human Interface Guidelines as an acceptance checklist, with native evidence for each item. A visually similar mock does not establish conformance.

| Apple-aligned criterion | Required final evidence |
| --- | --- |
| Native navigation, controls and typography | SwiftUI implementation using native tab/navigation/form patterns, SF Symbols and scalable system text styles; visual inspection on the supported size classes |
| Legible content hierarchy | One clear primary task/value, concise errors, unchanged factual meaning, no competing decorative layers |
| Dynamic Type and localization | All supported text sizes, Russian text and long labels, with essential values/status/actions readable rather than truncated |
| VoiceOver | On-platform focus/order, label/value/unit grouping, adjustable/action equivalents for gesture-only controls and state changes |
| Touch targets | At least 44×44 logical points; a larger clear Stop target; inspect tap regions and spacing at compact sizes |
| Contrast and appearances | Both light/dark plus Increase Contrast and Reduce Transparency; measured 4.5:1 normal text and 3:1 relevant large text/nontext controls |
| Motion | Reduce Motion respected; owner-requested heart pulse only for current HR in the active scene; no artificial finish delays |
| Video coexistence | Bounded PiP placement tests with HR, speed, elapsed and Stop accessible; no reliance on detecting another app's window |

Use [Apple's contrast evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography), [VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover), and [Reduced Motion criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria) for the corresponding checks. Do not describe an unverified checklist as passed or imply Apple has certified the design.

Required Training states: ready, disconnected, unavailable HR, preflight preparing/cancelled, below/in/above zone, cooldown above/reached target, HR presentation hold and expiry, unknown speed, ending confirming/unconfirmed, complete/partial/unavailable result. The interactive comparison illustrates a subset; the native implementation must cover the full set.

Other required states: empty/populated/loading/failed statistics, unavailable metrics, existing history export confirmation, profile switching constraints, device list scan/empty/connected, Plank idle/running/completed/measurement/cancel. Keep diagnostic capabilities reachable.

Required QA: small/tall iPhone, compact height/landscape, regular width, both appearances, all Dynamic Type categories, VoiceOver order/actions, meaningful 44-point targets, Reduce Motion, sufficient contrast, Russian strings and the PiP geometry above. Browser large-text mode is not a substitute for native Dynamic Type or VoiceOver.

After implementation: full `swift test`; unsigned generic iOS build; exact-base UI scope check; focused existing safety/publication regressions; before/after screenshots with actual interactions; independent read-only review. No commit, push, PR, merge or physical deployment was requested in this turn.

## Historical concept evidence

- Unsigned simulator build succeeded with Xcode 27.0 (`27A5194q`) using `generic/platform=iOS Simulator`. Existing unrelated compiler warnings remain; this is baseline build evidence, not redesign acceptance.
- Nine current native screenshots are retained in `baseline/`: ready/active/cooldown/summary in light and dark; plus active-no-HR at maximum Dynamic Type in dark. They are before-images, not proposed UI.
- Final mock geometry review passed 64 PiP cases: two concepts × two appearances × two phone sizes (393×852 / 375×667) × normal/large text × four workout states. Stop, the primary value and relation status were visible, the PiP reserve was clear, and no horizontal overflow was detected. Sixteen other-screen smoke cases and local selection/start/extend-confirmation/stop-ending interactions also passed. Evidence: `concept-qa.json` and the three `concept-*-pip-*.png` images.
- The first bounded-height pass exposed clipped primary text on the small phone with large text. Keeping speed/time side by side in the compact lower band reclaimed height without reducing their type size; the final geometry pass above has no findings. Secondary zone detail remains scrollable.
- Script-based contrast checks passed for 30 selected text/background pairs across Focus/Tempo and light/dark, with a minimum ratio of 4.78:1 (`concept-contrast.json`). This covers the mock's tested text palette, not every native control or accessibility setting.
- Independent read-only review found no material blocker to concept selection and confirmed the app-wide scope, PiP distinction, pending native QA and unchanged application source.
- Focus is implemented in native SwiftUI. Current native evidence and verification limits are recorded separately in `native-qa.md`; package, signing, project configuration and runtime owners remain unchanged.

## Primary design references

- [Apple HIG: Workouts](https://developer.apple.com/design/human-interface-guidelines/workouts): distinguish an active session, emphasize useful metrics and controls, explain sensor limitations.
- [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials): reserve Liquid Glass for appropriate navigation/control layers, not every content surface. No custom Liquid Glass is proposed.
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [UI design tips](https://developer.apple.com/design/tips/): readable hierarchy, accessible alternatives and adequate hit areas.
- [Apple: Picture in Picture on iPhone](https://support.apple.com/guide/iphone/multitask-with-picture-in-picture-iphcc3587b5d/ios): the user moves and resizes the floating video window.

These are source-grounded design constraints. The specific Focus/Tempo layouts, palette and upper PiP reserve are proposed design decisions, not Apple certification or claims about a market ranking.
