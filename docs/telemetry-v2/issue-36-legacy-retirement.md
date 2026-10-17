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

## Final-source package/build and long soaks

Implementation source `67e964d310bd22cad56efc0f8e2495dcf30637db` passed
`swift test` across ten modules: 804 tests, one existing opt-in full-profile
skip, zero failures, exit 0. The 1000-hour fixture is a separate run, so this
skip is not counted as scale completion. Unsigned generic iOS build, project
metadata, governance and diff checks passed. Existing actor/capture warnings
remain; no new warning-free-build claim. Hosted CI stays owner-disabled.

Both fresh independent source reviews returned code GO, with overall readiness
explicitly pending completion of the full-scale fixture.

The new structural test reproduced the legacy paths before retirement. An
initial full invocation failed obsolete source-string assertions and was
interrupted; an intermediate core run also exposed stale assertions. Those
checks were updated to retained typed V2/control semantics, and the subsequent
complete invocation above passed. Neither failed run is counted as a pass.

Long-soak commands use the release `telemetry-soak` executable, `--minutes N`,
`--flush-every-seconds 60`, with/without `--instrumentation-off`. For each
duration `--control-only` independently replays without constructing a recorder
or store. All six recording runs match this checksum. The off column disables
instrumentation, not the recorder; only the control-only baseline has no writer.

| Minutes | Instrumentation | Critical/native/frames | Queue peak | Wall seconds | Transaction p95 ms | Sampled RSS range MiB | Store MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 30 | on | 4/5488/1800 | 244 | 42.092 | 990.267 | 17.7–41.8 | 8.07 |
| 30 | off | 4/5488/1800 | 156 | 27.387 | 746.016 | 18.0–43.8 | 8.07 |
| 60 | on | 4/11008/3600 | 244 | 106.053 | 1536.088 | 17.8–66.5 | 12.63 |
| 60 | off | 4/11008/3600 | 244 | 113.898 | 1394.438 | 18.0–61.6 | 12.63 |
| 120 | on | 4/22048/7200 | 199 | 310.076 | 2223.994 | 18.0–107.3 | 25.07 |
| 120 | off | 4/22048/7200 | 244 | 270.281 | 1884.068 | 18.0–106.2 | 23.57 |

Every run reports complete, produced=persisted, zero critical/native loss, zero
coalesced/dropped frames, final queue zero. Checksums: 30 `2937697cf7ae596d`,
60 `dd9f00210dfaa7f2`, 120 `961fa7a19d1ffc32`. Configuration is unchanged:
2048/256/512 buffer/reserves; batch128/5000ms; one retry after250ms.

These hosted runs overlapped the full-scale fixture and some package/build
checks. Timings are contention-affected observations, not an isolated speed
comparison against #31 and not a new device threshold. RSS grows with workload;
this is not proof of a real-device plateau or lifecycle-pressure behavior.
Private synthetic artifacts/logs remain outside Git.
