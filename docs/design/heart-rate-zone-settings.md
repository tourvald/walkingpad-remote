# Heart-rate zone settings

Accepted task: implement the zone-settings mock approved in the current chat;
interval workouts remain out of scope. Initial base: `f99cd2f97c59050c9d0d298f85c6137cf2276ad8`.
Refreshed onto live `main` `d6c63c0fb56ab36cdadeba2c2034ec4c61dbb645`
after privacy PR #243 merged; native privacy entry and package exclusion retained.

## Behavior contract

- Keep existing profile-scoped `hr_settings_v1` data and inclusive manual bounds.
- Add an optional nested settings value to the existing DTO: manual bounds,
  selected source, last successful Apple snapshot/provenance/date, optional manual HRmax.
- iOS 26 supports manual entry. iOS 27 may read preferred heart-rate zones via
  HealthKit after an explicit source selection and read-only authorization request.
- Apple reads never start a workout, use BLE, write HealthKit, infer HRmax, or change
  HR target/speed/Stop/freshness/cooldown behavior.
- Apply only validated five-zone configurations compatible with the existing integer
  HR-control display. Keep raw thresholds with the snapshot. Reject unsupported data
  without replacing the previous source/bounds/cache or manufacturing provenance.
- Preserve manual bounds when importing; returning to manual restores them.
- Profile changes, erasure, source changes, or active workout/preflight/Stop ownership
  invalidate pending imports. Imports cannot apply to another/new profile.
- New profiles may copy existing manual control settings, but not Apple ownership,
  cache, or another person's HRmax. Existing settings remain manual on migration.
- Disable zone/HRmax/source editing while workout or storage ownership is active.
- Refresh selected Apple settings without an authorization prompt when settings open
  or the app returns active; errors retain cached values and show their age.
- The HRmax field allows clearing and validated manual entry with the Watch settings
  hint. It is optional and is not a new training-start requirement.

## Write set and verification

SwiftUI: `HeartRateZoneSettingsView.swift`, the settings entry in `ContentView.swift`.
Domain: `HeartRateZoneSettings.swift`. Platform: `AppleHeartRateZoneProvider.swift`.
Profile adapter: the existing settings DTO/load/save and bounded update methods in
`BluetoothManager.swift`. Add these files to the existing Swift package source/exclude
lists, with focused `HeartRateZoneSettingsTests.swift` regression coverage.
CI SDK prerequisite and `ios/README.md` document the iOS 27 build SDK; minimum
runtime deployment targets remain unchanged.

Checks: decoding old settings, valid/invalid/manual/Apple bounds and fractional
threshold mapping, round trips, manual restoration, HRmax validation/clearing,
new-profile isolation, stale import rejection; core suite, unsigned app builds,
diff/scope/code-growth inspection. No physical install, launch, BLE or deploy.
The approved native mock establishes the UI direction; new hardware/HealthKit reads
against personal data require separate user interaction and are not automated here.

## Boundaries

No interval implementation, custom HRmax estimation, HR-control tuning, HealthKit
writes, historical workout rewriting, schema changes outside the existing settings
DTO, deployment/signing changes, or destructive migration. Independent safety and
final external review remain handoff gates; local tests cannot replace them.


## Boundary conversion

Apple supplies shared continuous thresholds. The application treats each threshold
as the next zone's lower bound and converts it to its existing inclusive integer
upper bound using `ceil(threshold) - 1`. Thus 140 maps to 139, while 140.4 maps to
140. Original doubles remain in the snapshot. Reject nonfinite, noncontiguous,
non-five-zone, app/custom-source, or unrepresentable configurations. Exact parity
with the Watch display at a threshold remains a device acceptance check.

## Local verification

- `swift test --filter HeartRateZoneSettingsTests`: 7 passed.
- `swift test`: 819 tests passed across all package suites on the initial base;
  466 in the core module. After the base refresh, the 466 core tests and unsigned
  generic iOS build passed again. Privacy-manifest and customer-page checks passed.
- Unsigned generic iOS and iOS Simulator builds passed with the iOS 27 SDK.
- `git diff --check` and governance validation passed.
- `python3 -m unittest scripts/test_code_growth_report.py scripts/test_codex_governance.py`: 7 passed.
- UI-only scope checker rejects `BluetoothManager.swift` and `Package.swift` by
  design; this task explicitly authorizes settings persistence/platform integration.
  The checker was left unchanged. All production edits match the write set above.
- Working-diff code-growth inspection includes untracked files; the standard
  base/head report is empty because no commit was requested or created.
- No personal HealthKit reads, install, launch, or BLE interaction was performed.
  Real HealthKit/device acceptance and external safety/final review are outstanding.
