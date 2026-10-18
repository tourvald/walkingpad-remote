# Customer privacy evidence (#238)

Source baseline: `f99cd2f97c59050c9d0d298f85c6137cf2276ad8` (accepted #239).
Reviewed 2026-10-18. This is an engineering inventory, not a published policy,
App Store Connect submission, legal compliance verdict or release approval.

## Owner facts and unresolved decisions

- Operator supplied by the owner: Кожушкевич Дмитрий Александрович.
- Customer support supplied by the owner: `sw.newgeneration@icloud.com`.
- The owner has no website yet. No privacy/support URL or hosting destination is
  approved. Moscow is not a publication destination.
- Publication is not authorized. A repository document does not substitute for
  a customer-facing public page or installed-app entry.
- Before publication, confirm support-mail handling: purposes, recipients,
  access, retention/deletion policy, and any applicable operator particulars.
  No support response deadline, postal address, legal status or jurisdiction is
  inferred from the name, mailbox or city.

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

## Permission wording assessment (not applied)

Project `INFOPLIST_KEY_*UsageDescription` values currently use English, generic
strings in Debug/Release. Watch update wording mentions measuring heart rate
but omits saving distance/steps/energy. A future in-scope UX implementation
should supply Russian purpose strings without widening requested types:

| Target / permission | Proposed customer-facing text |
| --- | --- |
| iPhone Bluetooth | «Bluetooth нужен для подключения к дорожке, чтения её состояния и управления тренировкой.» |
| iPhone Health read | «Пульс из Apple Здоровья используется для контроля нагрузки и подстройки скорости во время тренировки.» |
| iPhone Health write | «Приложение создаёт и сохраняет тренировку в Apple Здоровье, чтобы получать пульс во время занятия и связать результат с историей.» |
| Watch Health read | «Пульс, активная энергия, дистанция и шаги используются во время тренировки. Пульс передаётся на связанный iPhone для контроля нагрузки.» |
| Watch Health write | «Приложение сохраняет тренировку, активную энергию, дистанцию и шаги в Apple Здоровье.» |

Future offline About/Privacy/Support navigation must work without equipment or
HealthKit consent. Explain permission recovery through system settings, that
denial/revocation can make heart-rate control unavailable, and that a missing
sample is not proof of consent or a safe workout state. Do not alter the
existing safety guards or promise continued HR control after denial.

## App Store Connect decision worksheet (not submitted)

Apple distinguishes local processing from developer/partner collection. The
absence of an upload SDK alone does not settle the complete service practice:

| Path | Provisional classification / required decision |
| --- | --- |
| Local pulse/workout/profile processing | On-device processing alone is not collection under Apple's definition |
| Paired watch, Apple Health, ActivityKit and OS services | Describe actual destinations; Apple says its own collection is not the developer's disclosure responsibility. Recheck shipped targets, SDKs and any developer access before submission |
| User sends diagnostic files or messages to support | Operator may receive health/fitness data, diagnostics, contact information and identifiers. Do not automatically apply the optional-feedback exemption: every criterion must hold, including the submission-interface/name-display condition. Current export/share flow does not establish that condition |
| Other share recipients | User-selected service/person may receive the selected health/workout/technical file; its practices are not established by source inspection |
| Tracking / ads | No such implementation found; no tracking permission added |

Do not submit a blanket “Data Not Collected” answer until the owner confirms
actual support processing and any optional-disclosure analysis. For received
support material, assess Health/Fitness, Diagnostics, Identifiers, Contact Info
and User Content as applicable, app-functionality/customer-support purpose,
and linkage to identity. File redaction does not prove unlinkability when
email/account identity and timestamps are available. Hosting/access logs,
third-party recipients and retention must be reassessed once a site is chosen.

## Official requirements affecting this work

Checked 2026-10-18:

- [App Review Guidelines 1.5 and 5.1.1](https://developer.apple.com/app-store/review/guidelines/): accessible developer support and privacy information, accurate data-use/retention/deletion explanation and in-app policy access are release requirements. A local draft alone does not satisfy them.
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/): on-device processing differs from collection; optional feedback disclosure has cumulative conditions. Developer-accessible retained diagnostics need a separate decision.

## Open acceptance and verification

Public unauthenticated URLs, approved final customer copy, native navigation,
purpose-string changes, actual target bundle checks, App Privacy account-side
submission and installed-device permission/navigation checks remain open.
No publication, mail sending, App Store submission, phone installation or real
data deletion is performed by this document. #238 must remain open.
