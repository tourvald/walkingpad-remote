# Local profile erasure (#239)

Approved behavior: delete only the confirmed profile identity. Preserve other
profiles, shared treadmill/device preferences, installation identity, and Apple
Health records. Deleting the sole profile creates one new empty UUID/profile with
default settings. No installation reset, device operations or engineering-time
real-data deletion is authorized.

## Inventory and ordering (before implementation)

- Native Telemetry V2 sessions own samples, events, frames and analyses through
  cascade relationships. Configuration snapshots can be shared; delete only
  target-owned snapshots no longer referenced. Signal-source identities are
  shared device metadata; preserve referenced sources, remove newly orphaned ones.
- Legacy migration sources retain aggregate payloads; imported records, candidates,
  resolved workouts and reconciliation/linkage evidence contain profile data.
  Purge the confirmed profile and its source progress, preserving unrelated rows.
- Original TrainingLogs JSONL and profile-scoped/global UserDefaults shadows can
  reimport data. Ownership must be explicit or bound to the stable original
  legacy fallback. Corrupt/ambiguous/mixed ownership must stop completion, never
  cause guessed cross-profile deletion.
- Profile HR settings/zone plan/history shadows and the profile list live in
  UserDefaults. Commit profile removal last. Preserve an unfinished profile for
  visible retry after failure or relaunch. Retain a minimal erased-UUID denylist
  beside the database to reject stale insert/import work after restart. It has no
  label, workout or HealthKit data; it is not a recoverable history archive.
- App temporary workout/analysis/diagnostic exports may outlive share cancellation
  or crashes. Only positively owned artifacts can be removed. Mixed exports or
  unavailable ownership must produce an incomplete outcome. External shared
  copies and Apple Health are outside local deletion.
- Recovery/preflight/finishing/stopping and test-run owners block deletion. No
  deletion code sends treadmill commands or deletes HealthKit samples.

## Hypothesis-first user-scenario matrix

| User action / precondition | Expected invariant | Verification |
| --- | --- | --- |
| Cancel/dismiss alert, navigate away | No mutation before confirm | UI snapshot/confirmation binding; manual navigation UNVERIFIED |
| Double confirm/repeat retry | One identity erased, at most one sole-profile replacement | Service idempotence; disk reopen tests; UI busy guard |
| Switch/rename/create around confirmation | Captured UUID only, no active-profile substitution | Identity-based action; UI scenario UNVERIFIED |
| Delete inactive/active/sole/empty profile | Other profile byte-for-byte state retained; usable fresh replacement for sole | Disposable A/B and empty fixtures; UI selection UNVERIFIED |
| Start/stop/recover during deletion | Authoritative active/preflight/recovery/tail guards; no controller effects | Guard policy tests and source wiring; device race UNVERIFIED |
| File/store failure or termination between steps | No complete-success message, visible retry, denylist durable before erasure | Failure injection and on-disk reopen at pending marker boundary |
| Legacy migration or delayed linkage/analysis after deletion | No resurrection; retained B and Apple Health unchanged | Stale request/import replay, insertion rejection, missing-session analysis/linkage tests |
| Corrupt/missing/mixed legacy or temp export | Missing is idempotent; unknown is incomplete, unrelated data preserved | File fixtures and failure tests |
| Reuse label, inspect history and new exports | New UUID never inherits old history; external copies not recalled | New read/export after erase, disk reopen; device diagnostics UNVERIFIED |

The automated trace and remaining gaps follow below. In-memory
fixtures never prove iPhone file protection, interruption behavior or navigation.

## Release checks (UNVERIFIED)

On a disposable installed-app profile, without a treadmill: confirm cancel,
identity capture, sole-profile replacement, partial failure/retry, relaunch,
history/statistics/diagnostics/new exports, Apple Health preservation and denied
permissions. Physical installation and signed archive validation are deferred by
the binding batch contract. Never run these checks on real user history.

## Implementation / verification trace

- `ProfileErasurePolicyTests.testConfirmedIdentityPreservesNewActiveProfileAndSoleDeletionIsIdempotent`: explicit UUID, inactive/sole/repeat selection.
- `testEveryRuntimeOwnerIndependentlyBlocksErasure`: all eight independent guards. The manager additionally checks coordinator ownership of pending/active/stop-tail sessions; the coordinator rechecks before accessing storage.
- `ProfileErasureTests.testDiskErasurePreservesBAndRejectsStaleSessionAfterReopenAndRetry`: disk reopen, B identity/content and idempotent retry.
- `testLegacyReplayCannotResurrectErasedProfileAndPreservesOtherHistory`: normal discovery with fallback A, camelCase owner B, original file deletion, B source progress and data preserved through reopen/replay. JSONL fallback metadata is never treated as source ownership.
- `testMixedAndCorruptSourcesFailWithoutPurgingAnyProfile`: mixed, malformed and unassigned fixtures.
- `testPendingJournalSurvivesReopenAndAllowsRetryAfterDatabaseBoundaryFailure`: injected ordinary storage error after marker commit, reopen, start rejection and retry. This is not a physical file-protection or process-kill experiment.
- `testOwnedTemporaryExportErasedOtherExportPreservedAndAmbiguityFails`: owned/unowned artifacts and B preservation.
- `testRunningSessionBlocksErasureWithoutCommittingMarker`: persistence guard.
- `testLateAnalysisAndLinkageCannotRestoreErasedWorkout`: no history recreation by deferred consumers; HealthKit storage is never called by the erasure service.
- `testLegacyFallbackDeletesOnlyOriginalProfileAndCorruptJournalFailsClosed`: stable fallback and fail-closed corruption.
- `testConcurrentAnalysisExportBlocksErasureUntilItsOwnershipEnds`: asynchronous export ownership blocks deletion, then retry removes its app-owned artifact.
- `testCascadeErasesSamplesAndUnsharedSourcesWhilePreservingSharedSource`: cascade and source isolation.
- `testNewExportAfterDeletionContainsOnlyRetainedProfile`: erased profile export rejected; retained profile exported.

Source and UI wiring retain one UUID captured at confirmation. Cancellation,
real navigation/background/termination, OS recovery races, UserDefaults crash
persistence and iPhone protection remain UNVERIFIED manual/device checks; the
bounded pure-policy/disposable disk tests do not substitute for those checks.

No database schema change or new dependency/timer is introduced. Erasure adds one
minimal JSON journal beside the store (deleted UUIDs and opaque legacy source
IDs), one per-operation export ownership counter on the existing store actor,
and an internal owner sidecar in newly generated export directories. The owner
sidecar is never included in the portable export/share file list or ZIP. Old
exports without trustworthy ownership and mixed-profile exports are preserved
and produce incomplete deletion; retry succeeds only after the uncertainty is
resolved. Previously shared external/system copies cannot be recalled.

The journal is atomically written before file/DB erasure and covered by the
existing store directory backup/protection policy. A failure leaves the profile
entry available for confirmed retry. The profile list/settings/linkage cleanup is
last, on the existing main-actor orchestration path. Referenced shared signal
sources/device settings, installation ID, global navigation/plank preferences,
and Apple Health remain. Sole-profile replacement gets default settings and a
fresh UUID. There is no all-installation reset.

Apple's [ModelContext.transaction](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:))
commits inserts/changes/deletes when the closure completes; this uses the existing
`explicitTransaction` owner. File/SwiftData/UserDefaults writes are not one atomic
transaction, hence the earlier durable denylist and truthful retry state.

## Review corrections and extra regressions

The first independent critiques found camelCase legacy owner misclassification,
JSONL fallback/source-owner confusion, a startup settings-rebinding path and
missing support-only diagnostic artifacts. The A/B discovery regression failed
on the initial implementation (B file and source progress disappeared) before
correction. Erasure now shares the canonical explicit-profile parser; conflicting
or malformed explicit ownership never falls back. Source progress is erased only
when actual records/candidates or a positively owned original file prove ownership
(or the source is an exactly owned workout-history source).

`testLegacySettingsReopenCannotRebindErasedFallbackAndPreservesB` uses a disposable
UserDefaults domain plus an on-disk interrupted-erasure journal and corrupt
profile-list fixture. `testFirstLegacySettingsMigrationCopiesOnlyItsConfirmedOwnerAndKeepsExistingValues`
protects ordinary migration. Legacy settings copy waits for successful journal
loading and stable original fallback ownership; it cannot rebind erased A into a
new UUID. Settings cleanup is centralized in the same persistence seam.

`testSupportOnlyArtifactsRespectProfileErasureAfterReopen` uses the actual
`DiagnosticBundlePackager.createSupportOnly` producer and preserves B's diagnostic
JSON/ZIP while deleting A. Old support artifacts without owner metadata prevent
complete success. Historical `HR_Failures_*.txt` artifacts are similarly treated
as unresolved ownership, never silently ignored. The manager retains operation
ownership throughout detached diagnostic packaging, so deletion cannot overlap
creation of a late support-only artifact. UI/background overlap still requires
the deferred installed-app check.

An initial full suite exposed a CSV-export directory-count assumption after the
new hidden internal sidecar. Its assertion now counts public files while all
CSV privacy/content/determinism checks remain; the sidecar is not a share URL or
ZIP entry. Focused correction tests cover that existing regression as well.

The second critique caught ordinary first-upgrade settings loss: an early
`loadHrSettings` normalization could persist defaults before deferred migration.
Startup now performs its single initial settings load inside
`ProfileErasureSettings.loadAfterLegacyMigration` after journal resolution; profile
mutations stay unavailable before that resolution. `testStartupNormalizingLoaderCannotOverwriteLegacySettingsBeforeMigration`
exercises the production ordering seam with a disk store and disposable preference
normalization callback, asserting legacy target/cooldown/zone payload preservation.
The app manager itself is reviewed/built without starting its BLE adapter; this
fixture does not claim a running-app startup smoke.

The existing `TrainingResultBehaviorTests.testInterruptedRecoveryRequiresExplicitNilHealthKitResultBeforeArchiving`
source-extraction fixture now also executes the actual recovery handlers while
profile preferences are unresolved, then ready: no early HealthKit probe/archive,
exactly retained pending result, and successful processing after readiness. Its
first run needed the new readiness field in the fixture; the failed run was
stopped and the fixture updated. This exercises production recovery code without
starting the app/BLE, rather than merely checking a source string.

## Interrupted recovery archive owner

`NativeWorkoutRecoveryStore` also owns persistent
`Application Support/<bundle>/interrupted_native_workout_<UUID>.json` files,
retained after interrupted finishing attempts. The next critique found this
additional owner. After the telemetry purge and before final preference/profile
removal, its existing owner erases only structurally valid archives explicitly
bound to the confirmed UUID. Archives of B remain byte-identical; unknown,
corrupt or symlinked archives cause an incomplete outcome. An outstanding active
recovery marker also blocks this cleanup. No HealthKit record is deleted.
`ProfileErasurePolicyTests.testActualRecoveryArchivesEraseOnlyConfirmedProfileAfterReopenAndRetry`
uses the real save/archive/erase methods, disk reopen, A/B isolation and corrupt
archive failure/retry. File errors leave the profile for retry under the earlier
erasure journal, without a complete-success message.
