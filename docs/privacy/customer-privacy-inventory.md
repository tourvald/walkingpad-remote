# Customer privacy evidence (#238)

Source baseline: `f99cd2f97c59050c9d0d298f85c6137cf2276ad8` (accepted #239).
Reviewed 2026-10-18. This is an engineering inventory, not a published policy,
App Store Connect submission, legal compliance verdict or release approval.

## Owner facts and publication authorization

- Operator: Кожушкевич Дмитрий Александрович.
- Support: `sw.newgeneration@icloud.com`, https://t.me/HJDmitry. The username
  contact was checked publicly; the supplied phone number is not needed/stored.
- On 2026-10-18 the owner explicitly authorized GitHub Pages publication and
  continuing #238. Earlier local-draft-only restrictions are superseded for
  the reviewed final pages; historical drafts remain local and unpublished.
- The owner approved exclusive operator access to support messages/attachments,
  use for responding/investigating issues, no additional support recipients,
  and erasure of working copies within 30 days after closure, earlier on request.
  This does not promise deletion of providers' system backups or sender copies.
- Delivery/storage providers (iCloud Mail / the sender's mail provider / Telegram)
  remain separate from operator access. GitHub Pages logs visitors' IP addresses
  for security; the static pages add no scripts, forms, analytics or ads.
- Publication destinations: `https://tourvald.github.io/walkingpad-remote/privacy.html`
  and `https://tourvald.github.io/walkingpad-remote/support.html`. Exact public
  deployment bytes must be checked before completion; intended URLs alone are
  not proof of publication. No postal address, legal status or response deadline
  is inferred. An unapproved jurisdiction or additional operator record is not invented.

## Source-backed data flow

Paths below are relative to `ios/WalkingPadRemote/WalkingPadRemote/`.

| Owner / source | Data and purpose | Storage / destination |
| --- | --- | --- |
| `WalkingPadRemote/BluetoothManager.swift`: profiles, HR settings, zone plans, deferred linkage | Local profile labels/UUIDs, targets/zones, workout settings and history shadows; workout/recovery linkage identifiers | Profile-scoped and shared `UserDefaults`; no app account or login |
| `WalkingPadRemote/IPhoneHealthKitLiveHeartRateProvider.swift`: authorization and data source | Requests heart-rate read and workout write access. Native builder disables collection of other quantity types. Reads live heart rate for workout control; finishes or discards the workout through HealthKit | HealthKit plus local telemetry; this path does not request a general health-history export |
| `WalkingPadRemote/BluetoothManager.swift`: `resolveDeferredNativeHealthKitLinkageIfPossible` | Queries workout records around an interrupted finish to link an existing HealthKit workout; records workout UUID locally | HealthKit query, local deferred queue and telemetry linkage; local profile deletion does not delete HealthKit records |
| `WalkingPadRemoteWatch Watch App/WatchHeartRateManager.swift`: authorization, builder and `addStats` | Requests read: heart rate, active energy, walking/running distance, steps; write: workout, energy, distance, steps. Workout builder collects workout data; supplied distance/step deltas may be added | Apple Watch HealthKit; workout is finished/saved at the end |
| Same watch owner plus iPhone `BluetoothManager` WatchConnectivity methods | Watch sends pulse, callback time, sequence, status and saved workout UUID/end time. Phone sends target and commands; the watch also accepts workout-event/statistics messages, without an active phone sender established in the inspected manager | Paired phone/watch via `WCSession` messages, application context or queued user info. This transfer is distinct from a developer-operated server |
| `WalkingPadRemote/BluetoothManager.swift`: CoreBluetooth delegates and commands | Nearby treadmill identity/protocol, status/speed and workout observations; control and diagnostics | BLE between phone and treadmill; shared device preferences and local telemetry |
| `Sources/TelemetryPersistence/TelemetryStore.swift`, models and coordinator | Workout sessions, pulse/speed samples, timestamps, events, decision/configuration snapshots, quality/failure information, source/session identifiers and analyses | Local SwiftData store and sidecars; no expiry-based purge is established by this inventory |
| `Sources/TelemetryPersistence/LegacyTelemetryMigration*` | Old workout-history preferences and `TrainingLogs` JSONL; records can contain installation/profile identifiers, profile labels, health/workout values and raw payloads | Original local sources plus imported candidates, reconciliation and source-progress evidence. Migration does not imply source deletion |
| `WalkingPadRemote/NativeHeartRatePreflightEngine.swift`: `NativeWorkoutRecoveryStore` | In-progress recovery marker and interrupted-workout archives, profile/workout identity and finish context | Application Support JSON; retained recovery evidence is included in #239 erasure scope |
| `Sources/TelemetryPersistence/TelemetryWorkoutExportStore.swift` | User-selected workout evidence, pulse/treadmill observations, timestamps, configurations, linked workout/source/session identifiers, quality data and app/OS versions | Temporary JSONL/CSV/manifest files, then user-selected share recipient. Explicit profile label/ID and device model/ID fields are excluded; the export is not anonymous and can include a HealthKit workout UUID |
| `Sources/TelemetryPersistence/TelemetryWorkoutAnalysisExportStore.swift` | Per-workout analysis and health/workout metrics | Temporary export; shared only by user action |
| `Sources/TelemetryRuntime/DiagnosticSupportArtifact.swift` and `BluetoothManager.diagnosticSupportSnapshot` | Diagnostic ZIP: available selected workout evidence plus technical snapshot. Support-only fallback still contains versions, timing, preflight/failure state, protocol/unit evidence and connection epochs | Temporary app-managed files; user chooses whether and where to share. No automatic email/upload is implemented |
| `WalkingPadRemote/ContentView.swift`: share wrappers; `BluetoothManager.finalizeDiagnosticBundle` | System share sheet sends selected artifacts to chosen app/service | Diagnostic temporary directory is removed on share completion or cancellation; source workout evidence remains. Crashes/errors may leave temporary artifacts |
| `WalkingPadRemote/WorkoutLiveActivityController.swift`, `WorkoutActivityAttributes.swift`, `WorkoutLiveActivity/WorkoutLiveActivityWidget.swift` | Session UUID, workout phase and countdown deadline; visible phase/countdown on Lock Screen/Dynamic Island | Local ActivityKit presentation, `pushType: nil`; no remote activity push service implemented |
| Watch manager `configureNotifications` | Optional local start/stop/failure notification and sound | Local notifications; no remote push registration established |

The production Swift sources, entitlements and project were searched for
`URLSession`, HTTP URLs, `NWConnection`, CloudKit and collection SDK integration.
No app-operated network upload, backend, advertising, tracking or analytics SDK
was found in these targets. This is source inspection, not a packet capture or
proof about Apple services, the selected share destination, or a future website.
No iCloud container entitlement is configured. Do not describe all data as
remaining on one device: paired-watch transfer, HealthKit/system services,
backups and explicit sharing are separate paths.

## Retention, backups and deletion

- `Sources/TelemetryPersistence/TelemetryStoreFilePolicy.swift` excludes the
  Telemetry V2 directory/store sidecars from backup and requests file protection
  until first authentication. Actual iPhone protection is UNVERIFIED. This does
  not establish a blanket backup exclusion for UserDefaults, old TrainingLogs,
  recovery archives or every other app file. OS backups and Apple Health/iCloud
  behavior depend on system settings; the app has no restore/recall authority
  over external copies.
- Local profile data is retained until its applicable cleanup/deletion path;
  do not promise an invented number of days or removal after every export.
- #239 deletes only the confirmed profile's agreed local data, including
  owned legacy/recovery sources and app-managed temporary exports. Other
  profiles and shared treadmill/device/installation/navigation/plank settings
  remain. The sole-profile case creates one new empty profile UUID.
- A minimal erased-profile/opaque-source identifier journal remains to block
  stale migration/recovery writes; it contains no label or workout payload.
  It has no scheduled expiry. It is not a recoverable history archive.
- Unknown, corrupt, mixed or unowned artifacts prevent complete-success
  reporting and require resolution/retry; no guessed cross-profile purge.
  Active/stopping/recovering workouts and in-flight owners block deletion.
- Apple Health records remain. Their removal and HealthKit permission changes
  are separate system/user actions. Revoking permission does not erase local
  history. Previously shared files, recipients' copies and old backups cannot
  be recalled by local deletion.

See [the erasure contract](profile-deletion-contract.md) for tests and explicit
installed-device gaps. This inventory does not upgrade those gaps to PASS.

## Permission wording applied in #238

The existing Debug/Release `INFOPLIST_KEY_*UsageDescription` values now use
Russian purpose strings, consistent with the current Russian app UI. Previously
generic watch write wording omitted distance/steps/energy. No authorization type,
entitlement or capability is widened. Built iPhone/watch Info.plist values are
checked separately from source configuration:

| Target / permission | Customer-facing text |
| --- | --- |
| iPhone Bluetooth | «Bluetooth нужен для подключения к дорожке, чтения её состояния и управления тренировкой.» |
| iPhone Health read | «Пульс из Apple Здоровья используется для контроля нагрузки и подстройки скорости во время тренировки.» |
| iPhone Health write | «Приложение создаёт и сохраняет тренировку в Apple Здоровье, чтобы получать пульс во время занятия и связать результат с историей.» |
| Watch Health read | «Пульс, активная энергия, дистанция и шаги используются во время тренировки. Пульс передаётся на связанный iPhone для контроля нагрузки.» |
| Watch Health write | «Приложение сохраняет тренировку, активную энергию, дистанцию и шаги в Apple Здоровье.» |

The parameters Form now opens `AboutPrivacyView`, without an HR/equipment gate.
Its local summary/contact/permission information is readable without consent;
public policy/support links require network access. It explains system permission
recovery, unavailable HR control after denial/lack of fresh pulse, and unchanged
local history after revocation. Existing runtime safety guards are untouched.

## App Store Connect answers prepared for release (not submitted)

For the approved customer-support practice, conservatively disclose received
support material rather than assuming the optional-feedback exemption. On-device
processing alone is distinct from developer collection; no automatic upload is
added. The current export/share interface does not establish every optional
feedback-exemption condition, so “Data Not Collected” is not the prepared answer.

| App Privacy field / type | Prepared answer for support material |
| --- | --- |
| Does the developer collect data? | Yes: only when the user chooses to send support messages/files |
| Health & Fitness: Health / Fitness | Pulse, workout and activity information present in submitted diagnostics |
| Contact Info: Name / Email Address | Sender identity/profile name when available and support email sender address |
| Identifiers: User ID | Telegram account/handle accompanying the support conversation |
| User Content: Customer Support | Message contents and selected support attachments |
| Diagnostics: Other Diagnostic Data | App/OS versions, failure/state/timing and connection evidence in submitted diagnostics |
| Purpose for these types | App Functionality (customer support and issue investigation) |
| Linked to the user's identity? | Yes: support account/email identity can be associated with the file, even when export fields are redacted |
| Used for tracking? | No: no advertising, cross-app tracking or data-broker sharing implemented/approved |

Do not declare device hardware IDs or crash dumps merely from the presence of
opaque workout/source/session IDs; no automatic crash-report SDK was found.
Retain the broader local-data inventory above even where a type is not collected.
Re-audit the actual received format if support later adds other upload/analytics
channels; Apple/system-service collection is distinct from developer access.
These prepared answers cover iPhone, watch and Live Activity flows, not only the
main UI. The operator has approved support processing; account-side App Store
Connect entry/submission remains an explicit release step, not performed here.

## Official requirements affecting this work

Checked 2026-10-18:

- [App Review Guidelines 1.5 and 5.1.1](https://developer.apple.com/app-store/review/guidelines/): accessible developer support and privacy information, accurate data-use/retention/deletion explanation and in-app policy access are release requirements. A local draft alone does not satisfy them.
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/): on-device processing differs from collection; optional feedback disclosure has cumulative conditions. Developer-accessible retained diagnostics need a separate decision.

## Publication, verification and release boundary

`website/` contains only canonical static customer HTML/CSS and `.nojekyll`.
Publish that subtree to a dedicated `gh-pages` branch and configure Pages legacy
branch publishing at `/`; never publish the whole engineering `docs` directory.
GitHub's platform-managed Pages deployment run is required even for branch
publishing. Existing `CI` stays `disabled_manually`; no CI workflow is enabled or
added. No custom domain or dependency is required.

Checks: `python3 scripts/check_customer_pages.py`, then the same command with
`--site-url https://tourvald.github.io/walkingpad-remote/` for HTTP status and
exact canonical-byte comparisons. Use an expected-head guard for PR merge.
Update Pages by publishing reviewed `website/` contents. Roll back a page by
reverting its source and redeploying the reviewed subtree; disabling Pages is a
separate owner decision. App rollback uses a normal code revert; no migration.

Release-only UNVERIFIED checks: signed archive/Organizer, installed iPhone
navigation and denied-permission behavior without equipment, and actual App
Store Connect entry/submission. An isolated simulator fixture displays the real
About view without BluetoothManager/HealthKit; it does not prove installed-app
runtime or denied-permission behavior. No phone install/launch, real data erasure,
HealthKit deletion or App Store submission is performed. Public deployment and
engineering merge are distinct from those deferred release gates.
