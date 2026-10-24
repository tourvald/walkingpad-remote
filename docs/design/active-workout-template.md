# Active workout template

`ActiveWorkoutShell` in `ContentView.swift` owns the layout for every active
workout. Mode adapters supply `TrainingHubPresentation`; they do not supply custom
views, fonts, dimensions or control logic. Reuse this owner for new modes rather
than building another active screen.

## Content contract

1. Readiness identifies the treadmill and heart-rate source.
2. The optional phase/status names the current stage.
3. The target has a secondary heading and a prominent value/range with its unit.
4. Two selectable metrics show a heading and a value with its unit. Supply stable
   `speed` and `elapsed` IDs; the existing heart-rate option remains available.
   Unavailable factual values use `—`, never a fabricated zero.
5. Render the zone scale only when segments exist.
6. An optional countdown shows its stage-specific heading, remaining time and
   native progress indicator. It consumes existing snapshots and owns no clock.
7. Stop and the optional extension action live in the bottom safe-area inset.
   Preserve the existing enabled state, confirmation and callbacks.

## Layout and accessibility

- Keep this section order for all modes. A label never competes horizontally
  with the primary value or the two metrics.
- Use semantic system fonts and intrinsic text height. Metrics use a horizontal
  arrangement only when their complete ideal widths fit; otherwise they stack.
- Support Dynamic Type without capping the user's text size. Actions stack when
  their labels do not fit horizontally. Content
  scrolls while Stop stays visible above the tab bar, including in landscape.
- Give controls at least 44-point hit regions. Keep explicit accessibility labels,
  values and metric-selection actions; preserve Reduce Motion behavior.
- Zone markers overlay the intrinsically sized legend without capturing taps.
  Readiness text may wrap instead of disappearing into ellipses.

These rules follow Apple's [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout)
and [Larger Text evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria).

## Regression checks

Use the existing `--active-workout-preview=<state>` simulator fixtures; they skip
normal transport startup. Include HR control, interval warm-up/work/recovery/
cooldown, unavailable HR/speed, and `active-long-content` (long labels, source and
hour-long durations). Never use real device data for these fixtures.

`ActiveWorkoutSimulatorUITests.swift` runs in a standalone simulator UI-test
bundle against the installed preview app. Check the smallest supported viewport
and a standard iPhone, light/dark appearance, Large and Accessibility XXXL text.
Verify target/metric separation, complete accessible values, metric selection and
Stop reachability after scrolling. Screenshot review complements the assertions;
neither is a claim of full-app accessibility certification.
