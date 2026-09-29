# Focus native verification

Local implementation completed on 2026-09-12 under owner-delegated PM discretion. Base: `f7972a97c64f9310e3a82b32b8152b8d96e2e53a`; branch: `codex/ui-evolution`. No commit, publication or physical-device deployment is part of this delivery.

## Delivered experience

- Training uses a shared surface, zone scale, time slot and action geometry from preparation into the active workout. The native recording in `native/start-transition.mp4` shows this transition using local fixture callbacks.
- Current HR and zone relation dominate. A heart pulses only for available, non-held HR in the active scene with Reduce Motion off. It is an availability animation, not measured beat timing.
- Duration choices become a remaining-time progress bar. Cooldown retains the same composition and explicitly labels time as a limit. Details contains the existing confirmed `+5 minutes` action; Stop remains available there and in the fixed workout dock.
- Statistics/history, Plank, parameters/profiles, device selection, shared diagnostics and the companion Watch presentation use the same quieter hierarchy and scalable native text. Data provenance remains accessible through disclosure.
- Missing HR/speed/result values remain unavailable. Stop confirmation, same-session result matching, factual distance/average-speed rules, and incomplete-zone semantics are unchanged.

## Follow-up: stationary zones and time

The owner identified movement between the delivered ready and active screens. Pixel measurement of the original 390 × 844 native captures found a 111.33-point zone-bar shift and a 100.33-point shift from the selected duration control to the progress bar.

The correction uses the outer canvas frame as the common coordinate reference, equal 20-point card insets, a shared zone start, and a 44-point time-control slot. The time heading uses the same native text style in both states. Space below the time area absorbs the active card's remaining height. Size-based bounce behavior prevents a fitting Hub from moving on a swipe.

| Measured visible feature, default portrait | Ready | Active | Difference |
| --- | ---: | ---: | ---: |
| Selected zone bar center | 525.1667 pt | 525.1667 pt | 0 pt |
| Selected duration / progress center | 586.1667 pt | 586.1667 pt | 0 pt |

The values were calculated with Python/Pillow from unchanged native PNGs. XCTest separately verifies the common zone bottom edge, time-heading start, widths and horizontal alignment, a Hub swipe, and accessible Start/Stop. Interactive and static AX containers include different hidden marker/progress padding; their full AX rectangles are not comparable visual bounds. The initial raw test failures are retained in `native-evidence.json` with this explanation, rather than called a clean pass.

Stationary anchors apply to portrait canvases with width ≥375 pt, height ≥740 pt and Dynamic Type through `large`. The predicate uses the same outer canvas in both states. Compact dimensions, landscape and enlarged text keep natural flow and a fixed action dock. A real first-candidate clipping defect at `xxxLarge` was corrected by this fallback and a minimum-height header. The final native enlarged-text check confirms the complete readiness text and reachable duration/Start controls. All 12 Dynamic Type categories were rechecked after the correction.

Final follow-up verification: 27 focused Swift contracts, unsigned generic iOS + Watch build, four native iPhone tests (including 12 text categories and three active/cooldown states), and compact iPhone SE transition/normal/AX5 checks. No new timer, publisher, persistence or command behavior was introduced. The earlier 700-test full suite below belongs to the initial delivery; the follow-up reran the focused contracts and builds.

## Verification results

| Area | Evidence and result |
| --- | --- |
| Swift package | `swift test --package-path ios/WalkingPadRemote/WalkingPadRemote`: 700 tests, zero failures, one intentionally skipped SQLite benchmark. Totals parsed by Python from each `All tests` summary. |
| Final source contracts | `swift test --filter 'HeartRateLegacyBehaviorContractTests\|TrainingUIObservationBoundaryTests'`: 27 passed after layout corrections. |
| Build | Xcode 27.0 (`27A5194q`), unsigned generic iOS Simulator and generic iOS builds including embedded Watch: succeeded. Existing unrelated compiler warnings were not expanded into this scope. |
| Compact iPhone | iPhone SE portrait, normal/AX5; active, unavailable HR and cooldown. Native geometry asserts HR/status inside the actual scroll viewport, factual speed/time and Stop visible, remaining time reachable, Stop position stable during scroll, and no intersection with the video reserve. Passed. |
| Compact landscape | Native SE landscape AX5 geometry passed. iPhone active content uses a bounded scroll viewport and a horizontal fixed control dock. |
| Large iPhone | iPhone 17 Pro Max: all 12 Dynamic Type categories in dark; 12 auxiliary-screen fixtures in both appearances. Passed. |
| Regular width | iPad mini: portrait and landscape active/no-HR/cooldown. Passed after the harness waited for launch/orientation geometry to settle; the initial launch-animation sample was discarded, not hidden by changing application layout. |
| Real interactions | Settings/back, Start, Details, `+5` confirmation, updated remaining time and Stop/ending passed on SE and 17e. Plank tap/start, countdown completion, long-press measurement confirmation, baseline measurement, and cancellation passed. All training callbacks in these tests are local fixtures. |
| Visual states | Fifteen additional native captures cover preparation blockers/preparing, below/above zone, missing speed, disconnected fixture, reached cooldown target, ending, complete/fallback/partial/unavailable results. Independent read-only review found no clipping or factual substitution. |
| Auxiliary layout | Statistics loaded/partial/empty/loading/failed, Settings, device list/connected/empty/scanning, Plank and Debug inspected. Final corrections removed Statistics footer truncation and AX5 Plank ring/header collisions. |
| Accessibility structure | Native AX geometry/labels and audit of contrast, hit regions, sufficient descriptions and clipped text; source review of order, combined metric units, headings and Plank action alternatives. Core workout text sizes are not capped. |
| Motion and transparency | Source contracts and independent review confirm Reduce Motion guards on geometry/pulse/button feedback. Authored information surfaces are opaque semantic colors; they do not require a custom Reduce Transparency implementation. |
| Scope and regressions | Exact-base UI scope checker and `git diff --check` pass. Independent review found no P0–P2 source regression. Runtime/BLE/persistence/HealthKit owners and Settings setters are unchanged. |

The UI observation whitelist adds only the existing cooldown remaining/progress and main progress publishers needed by the new time bar. Runtime cadence is unchanged; there is no new timer, broad manager subscription or raw accepted-HR timestamp publisher.

## Contrast audit interpretation

The native audit identified a real low-contrast tinted secondary button; secondary actions now use the accent directly on the semantic canvas. Ending/completion status text uses primary foreground on its status tint.

Composite Z1–Z5 AX frames include their pale decorative capsules, so the pixel auditor reports the capsule/background contrast as if it were text. These exact composite frames were excluded with attached reasons; actual black text on white was measured at 21:1. Required selection and live markers are separately dark and explicit.

The final reviewed audit retained two failures for the same system navigation title over scrolled content. Independent pixel inspection found black glyphs on the actual navigation background at 14.49–18.93:1; both crops were identical. These are documented system-material false positives, not an unqualified clean audit. Offscreen content hidden under fixed controls was evaluated after scrolling into the unobscured viewport. Apple describes reviewing such audit findings in [WWDC23 accessibility audits](https://developer.apple.com/videos/play/wwdc2023/10035/?time=574).

The transient negative-frame warning was corrected by clamping the usable GeometryReader width during zero-size navigation layout. The subsequent native correction run has no recorded runtime warnings.

## PiP geometry and limits

Portrait reserves an empty upper band with height `min(208, height × 0.25, contentWidth × 9/16)`. The shared outer canvas supplies height for the anchored composition; the local usable height supplies it for natural flow. Compact landscape reserves a leading 16:9 region using 32% of content width. The reserve is not a player and has no production accessibility element. A video fitted inside this region does not cover the tested HR/status/speed/time/Stop bounds. On short phones or at accessibility sizes, zone/time details can scroll while essential metrics and Stop remain fixed.

The design supports this bounded placement. It does not move or resize another app's PiP window, and an enlarged or repositioned window can cover content. Real YouTube PiP, treadmill/HR hardware, physical Watch behavior, spoken VoiceOver navigation and athlete field usability were not verified. This is a native implementation and simulator QA result, not Apple certification or a market-leadership claim.

Preflight cancellation, held-HR expiry, profile restrictions and history-export confirmation retain their existing behavioral/source tests; synthetic screen navigation does not establish a real hardware preflight or export session. Watch changes were source-reviewed and built, not exercised on a physical Watch.

## Inspectable evidence

- `native/`: selected unmodified native screenshots and the actual transition recording.
- `native-evidence.json`: source hashes, test summaries, geometry attachments and retained evidence mapping.
- `FocusGeometryTests.swift`: temporary XCTest harness used for native checks; it is documentation, not an added application target. Its Xcode project and result bundles remained outside the repository.
- Original local results: `/tmp/focus-final-all-tests.log`, `/tmp/focus-native-qa-small-final.xcresult`, `/tmp/focus-native-qa-large.xcresult`, `/tmp/focus-native-qa-final-corrections.xcresult`, `/tmp/focus-native-qa-ipad-settled.xcresult`, `/tmp/focus-native-qa-audit-reviewed.xcresult`.

Build command: `xcodebuild -project ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' -derivedDataPath /tmp/focus-device-final CODE_SIGNING_ALLOWED=NO build`.

Native checks used `xcodebuild test` / `test-without-building` with the temporary `FocusGeometry` scheme, a named simulator destination, `-parallel-testing-enabled NO`, and `-collect-test-diagnostics never`. No production project, scheme, dependency or signing file was changed.
