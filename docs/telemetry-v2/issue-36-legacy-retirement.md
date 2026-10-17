# Legacy runtime retirement

Issue #36; base `8c19f03fa190615f4e69d008ca931b74aa7664d6`.

## Authority and final architecture

The [owner waiver](https://github.com/tourvald/walkingpad-remote/issues/36#issuecomment-6241320778)
explicitly accepts the named unverified physical/parity items. It does not turn
missing evidence into PASS or waive failed automated checks. Delivery stops at
Draft PR; no installation, device launch, Ready or merge is authorized.

V2 is the only production writer and the only normal history/statistics/export
reader. Retirement removes the JSONL writer/serial queue/large dictionary
snapshots, wide CSV and sample-count summary helpers, capped UserDefaults shadow
history, source pruning/export cleanup and legacy inventory. Debug diagnostic
exports continue through V2, with existing writer-health/readiness reporting.
The export selection enum now belongs to V2 diagnostics, without legacy writer
or missing-log helpers. No second writer, hidden read fallback or timer is added.

HR/controller decisions, packets, queue ordering, retries, confirmation,
freshness, units, Watch lifecycle and Start admission remain unchanged. Existing
typed V2 HR/treadmill/command/phase/cooldown/lifecycle events remain. Random
synthetic step accumulation is removed; real device facts remain authoritative.
No schema, migration format, dependency, signing or deployment setting changes.

## Source preservation and compatibility window

Existing V2 records, JSONL files and `workout_history_v1` keys are not deleted,
pruned, truncated or rewritten. The existing background compatibility importer
continues to discover legacy JSONL and global/profile UserDefaults history,
read sources without modifying them, and reconcile additively/idempotently into
V2. Source-read-only import is separate from normal product reads and new-session
writes. Profile setting migration no longer creates another legacy history copy.

The supported compatibility window covers upgrades from the pre-retirement
legacy formats into telemetry schema 1.0.0 / storage schema 1.1.0. Removing this
importer requires a separate decision explicitly ending support for those
upgrade sources; this PR does not remove it or define automatic file cleanup.

Recovery/deferred HealthKit records retain their Codable legacy identity fields
for old records. New completion no longer creates or writes a legacy workout
row. Exact V2 session association must succeed before its pending linkage can
be cleared. Missing-session or failed association remains pending, never a
fabricated success. Saved HealthKit proof, recovery clearing and controller
lifecycle retain their existing owners. Old legacy-only pending linkage without
a V2 identity remains unresolved rather than rewriting source data or guessing.

## Rollback

`8c19f03` is the last accepted main revision with the shadow writer. The new
version can still import its source formats. New V2 workouts are not mirrored
into legacy sources, so an old legacy-only application cannot see them.

There is no destructive migration: retained V2/schema and legacy sources remain
available for an explicitly reviewed recovery. Rollback must use a V2-compatible
build preserving retained evidence. Reverting to the old shadow-writer revision
also resurrects obsolete writes and is not an automatic permitted fallback;
it requires its own release decision. Never delete/recreate a failing store or
silently fall back to legacy history.

## Verification and remaining uncertainty

The new structural retirement tests failed before implementation on legacy
writer/shadow paths. Required final evidence includes unchanged control replay
checksums at 30/60/120 minutes without recording versus with the accepted V2
recorder, instrumentation on/off, zero unexplained loss, full package tests,
1000-hour hosted storage/query/recovery/protection gate, and unsigned iOS build.
The soak's private HR reference is not the production controller. Source-order,
codec and domain regressions separately cover production safety boundaries.

Accepted recorder configuration remains capacity 2048, critical reserve 256,
native reserve from bulk 512, batch 128 records or 5 seconds, existing retry
policy. Long soak uses the accepted 60-second explicit harness flush cadence.
Host performance numbers must be attributed to host/toolchain/workload, never
promoted to iPhone battery or physical safety proof. No performance gain is
claimed from deleted LOC.

Remaining UNVERIFIED under the owner's itemized waiver: independent legacy/V2
parity; installed-v1.6 analysis; rapid Start/Stop/restart; real-device protection
across unlock/lock/suspend/reopen; backup/restore exclusion; device transaction
and accumulated-store query performance; Instruments memory/lifecycle pressure.
Known historical pre-fix defects stay attributed to their recorded versions.
No treadmill/phone operation is part of this verification.
