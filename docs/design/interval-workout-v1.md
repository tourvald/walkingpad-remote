# Interval workout V1 test contract

Authorized in this chat on 2026-10-18. Base: live main
`d6c63c0fb56ab36cdadeba2c2034ec4c61dbb645`, with the previously approved zone
settings from `6227e36` and the passive prediction-telemetry worktree diff.
Those source worktrees remain untouched. The owner subsequently authorized
independent review and one Draft PR, without merge or physical installation.

- Name: Intervals; 1-4 cycles, default 1. A single native workout owns all phases.
- **Temporary testing decision: warm-up is five minutes**, target 65% HRmax,
  range 60-70%. Revisit this explicit decision before full training use.
- Each work phase lasts four minutes from its start, including HR acquisition
  of the work range. Range 85-95% HRmax, regulation target 90%. No extension to
  make up missing exposure. Count elapsed, covered, in-range and above-range
  work time separately; unavailable evidence is not successful exposure.
  Exposure uses a bounded latest-sample hold on the controller clock, not an
  exact retrospective reconstruction. Keep factual sample timestamps for later
  comparison; the stop-on-overshoot policy can yield a zero-duration overshoot
  counter alongside an actual above-limit sample and early-finish reason.
- Three-minute active recoveries occur only between cycles, target 70% HRmax.
  Reduce speed immediately using the existing cooldown reduction helper, then
  on the existing decision cadence. Recovery never increases speed. Start the
  next work phase only with fresh HR at or below 70%; otherwise finish into
  cooldown. After the last work phase go directly to existing final cooldown.
- Fresh measured HR above 95% HRmax ends the interval portion early into
  cooldown, with an explicit incomplete reason. A prediction alone does not
  claim that this threshold was measured.
- Use existing adaptive steps, prediction, physical speed limits, units gate,
  preflight, stale-HR grace/timeout, Stop and factual-stop confirmation. No
  transport changes or new packet types. Do not accelerate with stale HR.
- Freeze a valid manually entered HRmax and cycle count at Start. Snapshot
  phase targets separately; never save them as ordinary HR settings. Missing
  HRmax blocks interval Start only. Ordinary workouts retain their behavior.
- Phase timing uses a monotonic clock and the existing ticker. Late callbacks
  cannot replay skipped work phases or burst speed commands. Native recovery
  remains fail-closed; relaunch never resumes interval motion automatically.
- Preserve the approved screen shell, readiness blocks, progress bar and Stop
  position. Reuse the 44-point duration selector for cycle count. Disable time
  extension for intervals. Keep existing trend settings visible.
- Emit phase/cycle/HRmax context and exposure counters through existing typed
  event payloads and exports. Keep prediction and measured/factual evidence
  distinct; do not infer command-response causality.

Owners: pure interval state/decisions in `IntervalWorkoutRuntime.swift`;
orchestration in `BluetoothManager.swift`; existing SwiftUI presentation in
`ContentView.swift`; additive event payload/export context in Telemetry V2;
an optional mode marker in the existing native recovery record. No new database
entity, permissions, dependency, timer or BLE subsystem.

Checks: deterministic phase/exposure/speed-rule tests, native recovery and
ordinary-control regressions, event compatibility and export tests, relevant
Swift tests, unsigned iOS build, and isolated simulator preview QA. Heavy
SwiftData/Soak performance workloads are not the functional acceptance suite.
Independent safety and final review remain separate from physical validation.

Analysis compatibility: repeated main/recovery phases require matching interval
cycle evidence. Ordinary duplicate phases remain invalid. Work-zone totals exclude
recoveries; continuous-stage settling/drift metrics are unavailable for intervals.
The existing generic target-zone metrics still use the profile zone definitions;
the explicit 85-95% exposure counters are exported separately.

## Local verification (2026-10-18)

- `swift test --jobs 2 --filter 'IntervalWorkoutRuntimeTests|HeartRateLegacyBehaviorContractTests|HRDomainServiceTests|CooldownRuntimeEngineTests|NativeHeartRatePreflightEngineTests|EventSessionAndAnalysisTests|WorkoutAnalysisExportTests|WorkoutAnalyzerV1Tests|TelemetryV2RuntimeCoordinatorTests.testBufferedIntervalPhaseContextSurvivesActivation|TelemetryV2RuntimeCoordinatorTests.testProductionShapedLegacyAndSemanticHrDecisionsPersistInOccurrenceOrder'`: 181 selected tests passed. After strengthening the initial-phase assertion, reran `swift test --jobs 2 --filter TelemetryV2RuntimeCoordinatorTests.testBufferedIntervalPhaseContextSurvivesActivation`: one test passed.
- Unsigned generic iOS build passed, including a final incremental build:
  `xcodebuild -project ios/WalkingPadRemote/WalkingPadRemote/WalkingPadRemote.xcodeproj -scheme WalkingPadRemote -destination 'generic/platform=iOS' -derivedDataPath /tmp/walkingpad-interval-v1-build -jobs 2 CODE_SIGNING_ALLOWED=NO build`.
- Unsigned simulator build passed. Visual QA is **not verified**: installation into the isolated simulator stalled, then timed out after its restart. Both task-owned installation processes were stopped; the simulator was returned to its original shutdown state. No physical device was installed or launched.
- `python3 scripts/check_codex_governance.py` and `git diff --check` passed. The UI-only scope checker exits 1 for `BluetoothManager.swift` and `Package.swift`; those runtime/build changes are separately authorized by this feature contract. It is not a UI-only diff.
- Used `scripts/code_growth_report.py`'s report engine against HEAD and an isolated temporary index of the uncommitted tree, without changing the real index or creating commits. Combined diff (including the zone/prediction prerequisites): production +1169/-188; tests +612/-15; no narrow-bugfix hard-stop candidates. Added interval state owns frozen preflight intent, ephemeral selection, phase timing and counters. It reuses the existing timer and clears session clock/intent at termination. No new dependency, persistent subsystem or transport owner.
- Fresh independent safety/scope and final reviews remain pending; this local result does not establish release or physical readiness. Original checkout and both prerequisite worktrees remain untouched; the original implementation was verified before committing for Draft review.

Clock choice: [Apple's ContinuousClock documentation](https://developer.apple.com/documentation/swift/continuousclock) confirms that elapsed time continues while the system sleeps. Only local process-lifetime instants are compared; persisted recovery never resumes this clock or interval motion.

## Review follow-up

The independent internal critique of the first implementation identified three
contract defects: a fresh above-limit observation could be overwritten before
the ticker, recovery admission rounded 70% upward, and recovery presented the
warm-up range. The correction retains an accepted excursion in session-local
runtime state until the existing ticker consumes it, uses an exact integer recovery
ceiling, and presents recovery as an upper-limit goal. The native observation
callback performs no motion or persistence; the initial commit observation is
also checked. Regression coverage includes intervening callbacks, freshness,
new-session reset, fractional ceilings, and presentation/control boundaries.

Owner decision after review: do not add special long-pause handling to test V1;
retain the existing late-callback behavior. The owner will manually stop the
belt using treadmill controls if the application becomes unresponsive. This
resolves the product-scope question, not a verified automatic-stop guarantee
while application execution is suspended. No runtime behavior changes accompany
this decision; the other acceptance gates remain open.

After the three review corrections: 187 selected Swift tests passed and the
unsigned generic iOS build passed. The fractional recovery-ceiling regression
was first reproduced as a failing test before its correction. These results
replace the initial 181-test verification for the corrected runtime.

A second review caught binary floating-point underflow at exact 70% integer
boundaries (HRmax 90, 170 and 180). Recovery now uses integer `HRmax * 70 / 100`;
regressions check inclusivity and rejection of the next BPM at all three cases.

Final integer-boundary correction: 188 selected Swift tests and the unsigned
generic iOS build passed. Visual/external-review/CI gates
remain open; the corrected Draft is not approved for release or installation.
