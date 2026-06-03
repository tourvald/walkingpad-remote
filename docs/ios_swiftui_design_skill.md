# iOS / SwiftUI Design Skill (agent rules)

Rules the agent follows when improving UI in this repo. Goal: better-looking,
more accessible, more consistent screens — **without changing behavior**.

## Hard rules
1. **Never change business logic without explicit permission.** Presentation only:
   layout, spacing, color, typography, SF Symbols, animation, view composition.
   Do not change `@Published` semantics, BLE commands, HR/cooldown decisions,
   treadmill control, or telemetry. (See "Design surface" below.)
2. **Behavior-preserving.** After any change, `swift test` and the unsigned
   `xcodebuild` must stay green. Existing flows, taps, and state bindings keep
   working exactly as before.
3. **Every design change ships with before/after screenshots** (light + dark when
   relevant), or a written reason why screenshots were not possible.
4. **Reuse, don't fork.** Prefer the shared components in
   `ContentSharedUIComponents.swift` / `DebugSharedUIComponents.swift` and the
   established patterns over new one-off styles.

## Apple HIG essentials
- Clear visual hierarchy; one primary action per screen; group related controls.
- Respect platform conventions (navigation, system fonts, SF Symbols).
- Content-first: reduce chrome, let data breathe.

## SwiftUI conventions
- Compose small views; keep view bodies readable. Factor repeated UI into reusable
  views/modifiers, not copy-paste.
- Use semantic system colors (`Color.primary`, `.secondary`, `Color(.systemBackground)`,
  `.tint`) over hard-coded RGB so light/dark and accessibility adapt for free.
- Use system fonts with text styles (`.title`, `.body`, `.caption`) for Dynamic Type.
- Drive layout with stacks + `Spacer` + `padding`; avoid magic absolute frames.

## Accessibility (required, not optional)
- Every meaningful control has an accessibility label; decorative images are hidden.
- Don't convey state by color alone — pair with text/symbol (e.g. the watch-issue icon).
- Maintain contrast (WCAG AA) in both appearances.
- Support VoiceOver order; group related elements with `.accessibilityElement(children:)`.

## Dynamic Type
- Use text styles; avoid fixed font sizes for body content.
- Layouts must survive `accessibility-extra-extra-extra-large` without clipping —
  prefer wrapping/scrolling over truncation for key info (HR, speed, time).
- Test with `xcrun simctl ui booted content_size <size>`.

## Dark mode
- Use semantic colors / asset-catalog color sets with light+dark variants.
- Verify both appearances; ensure gradients/glows keep contrast in dark.

## Safe areas & layout
- Respect safe areas; don't hard-pin to screen edges. Backgrounds may extend under
  safe areas (`.ignoresSafeArea`) but content stays inside.
- Mind the Dynamic Island / home indicator and the tab bar.

## Spacing & rhythm
- Use a consistent spacing scale (multiples of 4/8). Align to a grid.
- Consistent card padding, corner radius, and inter-element gaps across screens.

## Touch targets
- Minimum **44×44 pt** hit area for every tappable control. Add padding to small
  glyph buttons; don't rely on the icon's intrinsic size.

## Loading / error / empty states
- Every data view defines all four: **loading**, **populated**, **empty**, **error**.
- Examples here: treadmill *disconnected*, *no HR signal*, *waiting for first sample*,
  empty workout history, empty/failed training logs. Make these states intentional
  and on-brand, not blank.

## This project specifically
- **UI strings are Russian** — keep them Russian; mind length growth vs. Dynamic Type.
- **Design surface (safe to restyle):** `ContentView.swift`,
  `ContentSharedUIComponents.swift`, `CommonInfoCard.swift`, `StatusPillsRow.swift`,
  `StatsRightAlignedBlock.swift`, `PlankTimerView.swift`, `DevicePickerView.swift`,
  `DebugSharedUIComponents.swift`, `DebugTrainingLogsCard.swift`,
  `DebugHrFailuresCard.swift`, the watch `ContentView.swift`, and `Assets.xcassets`.
- **Off-limits for design:** `BluetoothManager.swift`, `HRControlDecisionEngine`,
  `HRDomainService`, `CooldownRuntimeEngine`, `CommandQueueService`,
  `TreadmillSpeedBoundsService`, `BLETransportCodec`, `TrainingTelemetryWriter`,
  `TreadmillTestRunPlanService`, `RuntimeGapMonitor`, `IPhoneHealthKitHeartRateManager`,
  `HRSettingsDefaults`, `WorkoutSessionController`, watch HR managers.
- **Established patterns to keep** (from AGENTS notes): segmented `Picker` + paged
  `TabView` for equivalent screen switching; gradient action tiles for zone/time
  buttons; grouped status cards; `.easeInOut(duration: 0.25)` for switch animation.
- Tabs: `HR‑контроль` · `Статистика` · `Планка` · `Отладка`.
