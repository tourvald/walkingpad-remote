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
Domain: `HeartRateZoneSettings.swift`, `HRSettingsDTO.swift`. Platform: `AppleHeartRateZoneProvider.swift`.
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

## Review corrections

New-profile copying uses the stored manual bounds in both nested and legacy DTO
fields; imported effective Apple values, cache and HRmax are never copied.
The existing DTO is now pure/testable without BluetoothManager or hardware.
Closing the form or backgrounding invalidates read ownership; cancelled tasks
cannot apply successes or errors. Temporary inactivity is allowed for system
HealthKit authorization UI. Invalid HRmax is shown while editing, before departure.

The 220 BPM import ceiling intentionally preserves the existing training selector
in `ContentView.hrZoneRanges`, which truncates every range and zone-5 target at
220. Imported zone 5 must remain representable there. Values supported by manual
persistence up to 230 do not establish support in that training selector. Broader
training targets require a separate runtime/UI contract; this task rejects the
unsupported configuration visibly and preserves the previous successful settings.

PR #245 is the single verification/review evidence packet. Device HealthKit/Watch
boundary parity and required exact-head CI remain separate acceptance gates.
