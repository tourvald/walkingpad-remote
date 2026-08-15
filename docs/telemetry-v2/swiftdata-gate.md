# Telemetry V2 SwiftData automated architecture gate

Status: issue #26 hosted evidence report.

## Verdict

`GO — AUTOMATED GATE ACCEPTABLE; DEVICE-ONLY ITEMS REQUIRE PM CARRY-OVER
ACCEPTANCE`

The actual V1 SwiftData Foundation completed the deterministic hosted fast and
full profiles without semantic, corruption, recovery, migration, isolation, or
file-policy failure. The full profile persisted 4,522,003 records representing
exactly 1,000 workout-hours. Hosted transaction and storage hypotheses were
missed substantially, but measured throughput, bounded late-scale behavior,
sub-200-ms representative queries, bounded memory, and successful reopen show
no material architecture defect. The misses are product-planning evidence, not
permission to weaken retention or scientific semantics.

This gate evaluates the concrete, unwired Telemetry V2 Foundation merged by
issue #39. It does not implement the recorder or authorize issue #27. Product
work may proceed only after PM accepts both this automated evidence and every
device-only carry-over item below.

## Tested revision and environment

| Item | Value |
| --- | --- |
| Canonical base | `4c59ae0257d40c9e86df386ca9c56713e88f3270` |
| Measured harness head | `c67f991d4568c776d9776f6100b03c15279c642b` |
| Schema | actual production `TelemetrySchemaV1` (`1.0.0`) |
| Harness | `swiftdata-gate-v1` |
| Deterministic seed | `0x26_39_40_2026` (`164169261094`) |
| Machine | Apple M5, arm64, 10 logical CPUs, 16 GB RAM |
| Host OS | macOS 27.0, build `26A5406e` |
| Xcode | 27.0 beta, build `27A5194q` |
| Swift | 6.4, package compiled in Swift 5 language mode |
| SDK | macOS 27.0 |
| Full command | `TELEMETRY_GATE_PROFILE=full TELEMETRY_GATE_STORE_DIRECTORY=<fresh-temp>/store TELEMETRY_GATE_OUTPUT=<fresh-temp>/full-summary.json swift test -c release --filter TelemetryGateBenchmarkTests/testConfiguredFullProfile` |

The full store was created in a fresh temporary directory. No app was installed
or launched, no physical device was used, and no BLE/treadmill connection or
command was attempted.

The implementation uses the existing `@ModelActor` store and its serial model
executor. The gate constructs the store from a detached task and verifies that
store work is not running on the main thread. Apple's public SwiftData contracts
used by the methodology are
[`ModelActor`](https://developer.apple.com/documentation/swiftdata/modelactor),
[`ModelContainer`](https://developer.apple.com/documentation/swiftdata/modelcontainer),
[`VersionedSchema`](https://developer.apple.com/documentation/swiftdata/versionedschema),
and
[`SchemaMigrationPlan`](https://developer.apple.com/documentation/swiftdata/schemamigrationplan).
No private SwiftData API is a correctness dependency.

## Harness and fixture

The SwiftPM-only gate lives in `Tests/TelemetrySwiftDataGateTests`. A separate
`TelemetryGateCrashWorker` executable exists solely to prove forced-process
interruption. Neither target is part of the Xcode application project.

The production persistence API remains unwired. The one benchmark testability
seam is internal to `TelemetryPersistence`: it runs the existing insert
validation and model mapping inside one actual `ModelContext.transaction`.
Therefore a reported 128-record transaction is one transaction, not 128 calls
to the public per-record save API. The seam does not define recorder buffering
or batching policy and has no application/runtime caller.

The causal and comparable-session query helpers are likewise internal,
harness-only probes against the accepted schema. They validate the required
future query shapes without adding a product read API. In particular, workout
mode is stored as a versioned payload, so the comparable-session probe first
uses the indexed profile/recent ordering and then decodes the mode payload.

### Deterministic profiles

| Profile | Sessions | Seconds/session | Hours | HR | Treadmill | Events | Frames | Analyses | Configurations | Sources | Total persisted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fast CI | 4 | 600 | 0.667 | 480 | 160 | 80 | 2,320 | 4 | 1 | 2 | 3,051 |
| Full | 1,000 | 3,600 | 1,000 | 720,000 | 240,000 | 20,000 | 3,540,000 | 1,000 | 1 | 2 | 4,522,003 |

The total includes sessions. Fifty full-profile sessions are deliberately
incomplete. A single immutable configuration snapshot is reused by all 1,000
sessions.

Native HR is generated every five seconds and treadmill evidence every fifteen
seconds. One quarter of HR observations have a source-scoped provider-native
identity. The fixture retries 4,000 exact provider redeliveries and requires
every one to be rejected by that exact stable identity. It also persists
18,000 duplicate-value/duplicate-sequence pairs without stable identity as
separate evidence; no fuzzy deduplication is allowed.

Each session contains the same typed 20-event lifecycle mix: session and phase
transitions, source and connection transitions, control decisions, command
enqueue/send/ACK, timeout/retry/failure, safety, cooldown, stop evidence, manual
stop, and recorder-health evidence. Envelope causal IDs are checked against the
typed payload IDs.

Canonical frames are generated at no more than 1 Hz and reference existing
native observations. Every session has a deliberate 60-second frame gap with no
backfill; the first post-gap frame contains an explicit gap boundary. Factual
treadmill speed remains decoded-device-report evidence and is never replaced by
desired, commanded, or estimated speed.

The generator streams at most one pending transaction (128 records) rather than
holding the full fixture in memory. Counts and a deterministic FNV-1a identity
hash are checked. The fast profile is run twice and must produce the same counts
and hash. Its hash was `1cd21e9585942c0f`; the full hash was
`e8a131ce8251eb90`.

## Insert and transaction results

| Profile | Drain | Persisted/s | Transactions | Full 128-record transactions | p50 | p95 | p99 | Maximum | Unexpected failures |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fast CI | 2.689 s | 1,134.5 | 32 | 22 | 113.110 ms | 124.442 ms | 128.693 ms | 128.693 ms | 0 |
| Full | 7,183.637 s | 629.5 | 36,323 | 35,319 | 196.478 ms | 298.440 ms | 391.737 ms | 2,895.726 ms | 0 |

The full run attempted and rejected exactly 4,000 stable provider-native HR
redeliveries. They are expected idempotence checks, not retry/failure noise.

| Full records already persisted | Samples | p50 | p95 | p99 | Maximum |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0-452,200 | 3,525 | 128.881 ms | 150.952 ms | 158.453 ms | 490.130 ms |
| 452,200-1,130,500 | 5,299 | 135.506 ms | 252.020 ms | 284.588 ms | 472.385 ms |
| 1,130,500-2,261,001 | 8,832 | 211.505 ms | 287.865 ms | 313.418 ms | 659.598 ms |
| 2,261,001-4,522,003 | 17,663 | 222.937 ms | 318.693 ms | 482.001 ms | 2,895.726 ms |

The first two buckets mix record classes, so their absolute difference is not
attributed solely to store size. The last two buckets are overwhelmingly the
same canonical-frame model and double the populated range: p50 increases 5.4%
and p95 10.7%. That is visible scale cost, but not a return to an O(N) duplicate
scan. p99 is noisier and rises 53.8%; the 2.896-second maximum is a rare hosted
checkpoint/outlier. Aggregate throughput remains about 501 times the fixture's
steady-state evidence rate of roughly 1.3 records/s.

The percentile method is nearest-rank over every complete 128-record
transaction. Drain time covers deterministic generation plus persistence. The
transaction count also includes bounded partial transactions and the 1,000
session/configuration owner writes; those are not misreported as 128-record
transactions. Expected duplicate-redelivery rejections are reported separately
from unexpected failures.

Every record insertion still executes the Foundation's bounded identity
predicates with `fetchLimit = 1`. Full-transaction latency is grouped by records
already persisted (0-10%, 10-25%, 25-50%, and 50-100%) so an obvious return to a
full-table duplicate scan is visible rather than inferred from a source-string
test alone.

The original 50 ms p95 is a designated-device hypothesis. The hosted result is
reported honestly but is not an iPhone pass/fail threshold and does not select
the production batch policy for issue #27.

## Query results

Each latency below is warm-up followed by repeated hosted measurements against
the final profile store. Fast uses five repetitions and full uses nine. The
export traversal is a single complete-session measurement. Fast and full provide
two dataset scales; each queried session contains the normal per-session record
volume shown above.

| Query shape | Exact definition | Fast p50 / p95, ms | Full p50 / p95, ms | Returned records |
| --- | --- | ---: | ---: | ---: |
| Recent history | Profile predicate, newest `startedAt`, limit 20 | 0.309 / 0.344 | 13.900 / 14.188 | 20 full |
| HR series | One session, arrival order | 4.607 / 5.060 | 23.282 / 23.563 | 720 full |
| Treadmill series | One session, arrival order | 1.742 / 1.800 | 8.681 / 8.742 | 240 full |
| Canonical frames | One session, canonical second | 17.420 / 18.012 | 96.141 / 98.606 | 3,540 full |
| Session events | One session, elapsed event order | 0.891 / 1.001 | 1.355 / 1.423 | 20 |
| Event kind | One session plus `commandLifecycle` | 0.525 / 0.553 | 1.035 / 1.081 | 8 |
| Decision causal lookup | Exact decision ID | 0.431 / 0.464 | 0.945 / 1.007 | 4 |
| Command causal lookup | Exact command ID | 0.378 / 0.428 | 0.898 / 0.944 | 3 |
| Attempt causal lookup | Exact attempt ID | 0.384 / 0.575 | 0.865 / 0.911 | 2 |
| Analysis | Session plus analyzer version | 0.333 / 0.379 | 0.852 / 0.879 | 1 |
| Comparable sessions | Indexed profile/recent fetch, decoded exact workout mode, limit 10 | 0.293 / 0.332 | 176.310 / 177.330 | 10 full |
| Export traversal | Complete session across all evidence classes | 25.283 single | 132.253 single | 4,522 full |

`sqlite3 EXPLAIN QUERY PLAN` is used only as supplementary inspection. It is not
a correctness dependency and does not access private SwiftData APIs.
Plans use the profile/started-at index for recent history, the
session/canonical-second index for frames, the session/kind/elapsed index for
kind-filtered events, the three individual causal-ID indexes, and the
session/analyzer-version/generated-at index for analyses. HR and treadmill use
their indexed session predicates but make a temporary per-session sort for
`arrivalOrder`; the accepted composite index orders by received elapsed time.
Unfiltered session events and causal results likewise perform a small result-set
sort. The measured p95 values above include those sorts. Comparable-session mode
decoding fetches the 250 sessions for one of four profiles; its 177.330-ms p95
is the slowest ordinary full-store query and remains below the declared hosted
context of 200 ms for a user-triggered history/filter operation.

## Memory

The conservative full-profile process high-water was 550,174,720 bytes
(524.688 MiB). Because `ru_maxrss` is monotonic, generation, persistence, query,
export, and final process endpoint fields all retain the same maximum and cannot
attribute which earlier operation created it. The fast profile high-water was
47,382,528 bytes (45.188 MiB). External progress observations during full
persistence showed current RSS around 27-54 MiB; those observations are not
treated as phase peaks or substituted for the in-harness high-water.

The mechanism is `getrusage(RUSAGE_SELF).ru_maxrss`, which is a process-lifetime
resident high-water mark on this macOS runner. It is sampled at generation,
persistence, representative fetch, export, and post-reopen endpoints. It is not
instantaneous private footprint, cannot attribute shared pages precisely, and
later phase values cannot decrease. The fixture is streamed and the full data
set is never materialized as an in-memory array. The synthetic migration fixture
is intentionally small and did not justify a separate full-scale memory claim.

## Storage growth and decomposition

After write and after reopen were identical:

| File | Bytes | MiB |
| --- | ---: | ---: |
| Primary store | 7,150,436,352 | 6,819.188 |
| WAL | 3,815,152 | 3.638 |
| SHM | 65,536 | 0.063 |
| Total | 7,154,317,040 | 6,822.888 |

Total growth is 7,154,317 bytes/hour (6.823 MiB/hour): 7.15 times the
1 MB/hour hypothesis and 3.58 times the 2 MB/hour hypothesis. At one workout
hour per day, this is about 2.43 GiB/year. The miss is operationally significant
and issue #27 must expose capacity/pressure evidence, but it is bounded, close
to linear, and not by itself a material failure under this gate contract.

Direct measurements include the primary SQLite store, every discovered WAL/SHM
sidecar, their sum, and host file attributes at staged lifecycle points. Growth
per hour is total bytes divided by exactly 1,000 represented workout-hours.

The contribution table is a controlled staged delta: sessions/schema/sources,
then HR, treadmill, events, frames, and analyses. Each delta includes that
stage's rows, indexes, page allocation, and the contemporaneous WAL state. It is
therefore a pressure estimate, not an exact per-table attribution. Remaining
schema/index overhead is inferred from the initial stage and SQLite page/index
inspection. WAL/SHM write amplification is reported separately from retained
primary-store bytes.

Staged total deltas were approximately 545.478 MiB for HR, 185.596 MiB for
treadmill, 9.899 MiB for events, and 6,080.259 MiB for canonical frames. The
analysis stage changed total by -0.318 MiB because its small write coincided
with a WAL checkpoint, demonstrating why staged deltas are only estimates.

Read-only SQLite `dbstat` page attribution after reopen gives a stronger direct
breakdown of the retained primary store:

| SQLite objects | MiB | Primary-store share |
| --- | ---: | ---: |
| Canonical frame table and indexes | 5,941.664 | 87.13% |
| HR table and indexes | 518.102 | 7.60% |
| Treadmill table and indexes | 175.199 | 2.57% |
| SwiftData/Core Data history and metadata | 162.293 | 2.38% |
| Event table and indexes | 13.090 | 0.19% |
| Analysis table and indexes | 0.953 | 0.01% |
| Sessions/configuration/sources and indexes | 0.551 | 0.01% |
| Other objects plus unallocated pages | 7.336 | 0.11% |

Frame payloads plus four frame identity/session indexes dominate the retained
footprint. This is not WAL retention: WAL+SHM after reopen are only 3.701 MiB.

The 1 MB/hour and 2 MB/hour values are hypotheses, not permission to remove or
coalesce scientific evidence. Any miss above is retained and assessed without
changing cadence, gaps, indexes, events, or retention semantics.

## Forced interruption and incomplete-session recovery

`PASS` — a separate worker creates an on-disk V1 store, persists a known session,
source, and 256 HR records, writes the committed-prefix count and deterministic
identity hash, then creates an uncommitted in-memory tail and waits. The parent
sends `SIGKILL`; this is not a graceful close.

Reopen retains exactly the 256 committed records and the same identity hash, and
does not contain the uncommitted tail. The session remains `running`, has no end
timestamp, and has incomplete recorder health; no fabricated completion or
silent empty-store replacement occurs. A harness-only recovery transaction marks
that existing session `incomplete` with reason `forced-process-interruption`.
A second reopen retains the same evidence/count/hash and the honest incomplete
state. This proves the schema/transaction mechanism; issue #27 still owns the
production recovery orchestration.

## Synthetic migration

`PASS` — the test first writes actual `TelemetrySchemaV1` evidence, then opens
the same file with a test-only `2.0.0` schema that adds one synthetic marker and
a public SwiftData lightweight migration plan. Counts and the ordered HR
identity hash remain identical, the marker is present, and a second reopen
produces the same result. No production V2 schema, legacy import, or empty-store
fallback is introduced.

## File policy and device boundary

`PASS` for the host-level helper: after write, reopen, forced interruption, and
migration, the primary store and all discovered WAL/SHM sidecars report
`NSFileProtectionCompleteUntilFirstUserAuthentication` and
`isExcludedFromBackup = true` where macOS exposes those resource attributes.
The helper re-discovers and reapplies policy to recreated sidecars.

One initial repository-wide test run transiently observed backup exclusion as
`false` on WAL/SHM immediately after a subsequent write. The exact focused test
then passed 20/20, and six consecutive complete suites passed without a code
change; the full profile, migration, recovery, and reopen snapshots also passed.
This did not establish a repeatable Foundation defect, but it remains a host
sidecar-lifecycle race risk for PM/device follow-up rather than being omitted.

This does not prove physical iOS behavior. The following items are explicitly
carried to issue #37 and each remains `UNVERIFIED_ON_DEVICE`:

1. Protection of the real iPhone store and every SQLite sidecar after first
   unlock, subsequent screen lock, process suspension/termination, and reopen.
2. Real iOS backup exclusion for the store and recreated sidecars across device
   backup and restore lifecycle.
3. The provisional 128-record transaction p50/p95/p99 and throughput on the
   designated physical target iPhone.
4. Full-profile representative query latency on the designated target iPhone.
5. On-device Instruments memory/footprint and app-lifecycle pressure behavior.

No physical device installation, launch, screen-lock action, BLE connection, or
treadmill command was performed by this gate.

## Isolation and scope

`PASS` — the Foundation store remains a `@ModelActor` backed by its serial model
executor, autosave is disabled, the gate confirms persistence execution is not
on the main thread, and static boundary tests confirm that neither gate target
nor `TelemetryStoreFactory.make` appears in application runtime sources. The
Xcode application project does not include the gate targets. No production
control, sensor, HR, BLE, UI, history/export, legacy telemetry, or safety path
acquired a database dependency.

## Classification matrix

Each category has exactly one primary classification.

| Category | Classification | Evidence |
| --- | --- | --- |
| Fixture semantic correctness | `PASS` | Deterministic counts/hash, native/frame/gap/provenance checks |
| Schema/identity correctness | `PASS` | Exact native redelivery rejected; identity-absent duplicates retained |
| Insert scaling | `PASS` | Same-model late p50/p95 rise 5.4%/10.7% across doubled range; no full-table scan signature |
| Transaction latency/throughput | `PASS` | Hosted p50/p95/p99 196/298/392 ms and 629.5 records/s; 50-ms hypothesis missed |
| History queries | `PASS` | Full p95 14.188 ms |
| Single-session time-series queries | `PASS` | Full HR/treadmill/frame p95 23.563/8.742/98.606 ms |
| Causal queries | `PASS` | Indexed harness-only decision/command/attempt p95 at or below 1.007 ms |
| Export traversal | `PASS` | Complete 4,522-record session in 132.253 ms |
| Comparable-session queries | `PASS` | Indexed recent-profile plus decoded mode p95 177.330 ms |
| Memory | `PASS` | Streamed fixture, no runaway/OOM; conservative host high-water 524.688 MiB |
| Store growth | `PASS` | Bounded 6.823 MiB/hour; significant non-blocking target miss documented |
| WAL/SHM behavior | `PASS` | 3.701 MiB combined after write/reopen; attributes retained |
| Interruption/reopen | `PASS` | External `SIGKILL`, committed count/hash preserved, tail absent |
| Incomplete-session recovery | `PASS` | Harness-only transaction plus second reopen; no fabricated completion |
| Migration viability | `PASS` | Actual V1 to test-only synthetic V2 plus repeated reopen |
| Host file-policy application | `PASS` | Primary/WAL/SHM attributes at relevant hosted lifecycles |
| Real-device file protection | `UNVERIFIED_ON_DEVICE` | Requires physical iPhone lock/lifecycle evidence in #37 |
| Real-device backup exclusion | `UNVERIFIED_ON_DEVICE` | Requires physical iOS backup/restore evidence in #37 |
| Designated-device performance | `UNVERIFIED_ON_DEVICE` | Hosted Mac numbers are not extrapolated to iPhone |
| Real-device query performance | `UNVERIFIED_ON_DEVICE` | Requires full-store query evidence on the target iPhone |
| On-device memory/pressure | `UNVERIFIED_ON_DEVICE` | Requires Instruments and physical app-lifecycle evidence |
| Main-actor/control-path isolation | `PASS` | Model actor/thread/runtime-coupling boundary checks |

## Limitations and recommendation

- Hosted latency and memory are runner-specific and do not predict an iPhone.
- Absolute microbenchmark thresholds are intentionally not CI correctness gates;
  semantic counts, identities, recovery, migration, policy, and boundaries are.
- Storage staged deltas include page allocation, indexes, and current WAL state;
  they are useful estimates, not exact table accounting.
- Comparable mode filtering decodes the accepted payload in the harness because
  V1 has no indexed scalar workout-mode projection. This is measured honestly
  and is not redesigned here.
- The gate batch seam proves transaction behavior but does not choose #27's
  buffer, retry, priority, loss-accounting, or batching policy.
- Physical file protection, backup, performance, and Instruments evidence remain
  explicitly deferred to #37.
- One hosted suite transiently observed WAL/SHM backup-exclusion loss after a
  write; 20 focused and six full-suite repetitions passed unchanged. Treat this
  as an unresolved lifecycle-race risk, especially in the real-device checks.

The hosted evidence supports continuing with SwiftData and designing issue #27
against measured drain/storage pressure. No corruption, committed-data loss,
identity/provenance/causal corruption, migration loss, MainActor/control-path
coupling, or operationally unusable scale behavior was found. A persistence
technology switch is not justified by this evidence.

Issue #27 is technically supportable, but it is not authorized by this report.
PM must first accept the gate, the substantial storage/latency hypothesis misses,
and all five `UNVERIFIED_ON_DEVICE` carry-over items. Recorder design should
remain bounded and observable, treat 128 as a provisional measured point rather
than policy, and plan product capacity UX/metrics without reducing native or
canonical evidence.
