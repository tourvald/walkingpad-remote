# Issue #31 performance instrumentation and soak report

Status: hosted integration evidence for Issue #31. This report does not qualify
physical-device behavior and does not replace gate #37.

## Accepted configuration

The provisional Issue #27 recorder defaults remain accepted without tuning:

- total buffer: `2048`;
- critical reserve: `256`;
- native reserve from bulk frames: `512`;
- batch trigger: `128 records OR 5 seconds`;
- pre-commit retry: one retry after `250 ms` only for an explicitly known
  pre-commit failure.

A same-workload `256`-record batch candidate halved transaction count but more
than doubled p95 transaction latency, reduced throughput, and increased peak
resident memory. Its smaller observed store footprint did not outweigh those
costs. Both configurations preserved every produced record and the identical
control-output checksum. The evidence therefore does not justify changing the
accepted starting defaults.

## Instruments catalog and privacy boundary

The `com.tourvald.walkingpad.telemetry-v2` subsystem exposes these static
categories and names:

| Category | Static signpost name | Observation point |
| --- | --- | --- |
| `ControlObservation` | `ControlCycleComputation` | existing HR control computation, after its existing runtime gates |
| `RecorderIngress` | `TelemetryIngressEnqueue` | synchronous bounded ingress call |
| `Persistence` | `PersistenceBatchTransaction` | one consumer batch persistence operation |
| `SessionLifecycle` | `SessionFinishOrRecovery` | recorder finish or unfinished-session recovery |
| `PostWorkoutAnalysis` | `PostWorkoutAnalysisPlaceholder` | hook reserved for #33; no analyzer runs in #31 |
| `IntegratedSoak` | `IntegratedSimulatedSoak` | one simulated hosted soak |

Only aggregate record counts, simulated duration, and coarse result classes are
accepted by the instrumentation API. It has no parameter for HR values, speed
trajectories, profile, device, session or HealthKit identifiers, raw BLE,
health payloads, or exports. Disabled instrumentation uses
`OSSignposter.disabled`. The implementation uses the iOS-15-era `OSSignposter`
API and is valid at the unchanged iOS 26 deployment floor.

MetricKit was not added. `MXMetricManager` delivers delayed daily aggregates,
which does not improve the deterministic per-run A/B evidence here. The iOS 27+
`MetricManager` API remains a future migration option only after a separately
approved platform-floor decision; it is not linked into the iOS 26 target.

## Method

Measurements were taken from exact base `4442210a45ff8bc875926f5cdf24719133cb5cb7`
plus the Issue #31 worktree changes on 2026-08-16. Host: Apple M5 arm64,
macOS 27.0 `26A5406e`, Xcode 27.0 `27A5194q`, Swift 6.4 debug package build.

The deterministic fixture uses one on-disk SwiftData store, one recorder and
one persistence consumer. It emits native HR and treadmill records every
simulated second, one observed canonical frame per second, and a bounded burst
of 32 additional native records every 30 seconds. It explicitly flushes once
per simulated minute for the long evidence runs so the record-count trigger is
exercised. It never backfills or duplicates a canonical frame and never invokes
production transport.

Transaction percentiles use nearest-rank selection over successful batch calls.
Throughput is persisted records divided by hosted wall time. Store footprint is
the allocated size of the SQLite store and discovered sidecars before cleanup.
Resident-memory samples are host RSS observations at simulated-minute
boundaries; they are timing/toolchain dependent and are not deterministic
device limits. The checksum covers deterministic simulated control outputs and
is computed independently of telemetry admission or persistence results.

## Same-workload A/B measurement

The 30-minute workload produced 4 critical, 5,488 native and 1,800 frame
records in each run (7,292 total).

| Measurement | Default `128` | Candidate `256` |
| --- | ---: | ---: |
| persisted critical / native / frames | 4 / 5,488 / 1,800 | 4 / 5,488 / 1,800 |
| coalesced / dropped frames | 0 / 0 | 0 / 0 |
| critical / native loss | 0 / 0 | 0 / 0 |
| queue final / high-water | 0 / 250 | 0 / 250 |
| transactions | 60 | 30 |
| transaction p50 / p95 | 193.789 / 299.750 ms | 475.126 / 637.253 ms |
| transaction min / max | 90.681 / 310.910 ms | 259.146 / 637.440 ms |
| throughput | 620.615 records/s | 523.755 records/s |
| RSS start / peak / end | 17.312 / 32.422 / 32.422 MiB | 17.266 / 36.891 / 36.891 MiB |
| final store | 8.070 MiB | 6.758 MiB |
| hosted wall time | 11.750 s | 13.923 s |
| completion | complete | complete |
| control-output checksum | `8de307efccdb1215` | `8de307efccdb1215` |

The candidate's p95 was 112.59% higher and throughput 15.61% lower. No loss or
control divergence occurred, but the overall tradeoff does not support tuning.

## Accepted-default duration runs

| Measurement | 30 minutes | 60 minutes | 120 minutes |
| --- | ---: | ---: | ---: |
| produced = persisted | 7,292 | 14,612 | 29,252 |
| class counts (critical / native / frames) | 4 / 5,488 / 1,800 | 4 / 11,008 / 3,600 | 4 / 22,048 / 7,200 |
| coalesced / dropped / critical loss / native loss | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| queue final / high-water | 0 / 250 | 0 / 250 | 0 / 250 |
| transactions | 60 | 120 | 240 |
| transaction p50 / p95 | 193.789 / 299.750 ms | 298.214 / 521.253 ms | 603.308 / 1,374.559 ms |
| throughput | 620.615 records/s | 393.272 records/s | 183.421 records/s |
| RSS start / peak / end | 17.312 / 32.422 / 32.422 MiB | 17.250 / 40.609 / 40.609 MiB | 17.312 / 63.562 / 62.469 MiB |
| final store | 8.070 MiB | 12.570 MiB | 25.070 MiB |
| completion | complete | complete | complete |
| control-output checksum | `8de307efccdb1215` | `b0046852a4935e49` | `9fa985bcf9a856a0` |

All queues drained and remained below the fixed 2,048-slot bound. The rising
host RSS and transaction latency are recorded honestly as profiling targets;
the three finite workloads do not establish a mathematical unbounded-memory
failure. They also do not qualify device memory, energy, or the historical
50-ms/1-MB/h/2-MB/h hypotheses. Those remain targets rather than automatic
rejection gates.

Query usability was not used to choose between these two batch counts because
neither candidate changes the schema or read projections. The existing
SwiftData query gate remains authoritative; this decision is based on the
integrated writer measurements that the candidate actually changes.

The explicit two-minute instrumentation ON/OFF runs both produced checksum
`c007ebaa72a51ac4`, with identical produced/persisted class counts and loss
state. This is hosted control-isolation evidence, not physical-device proof.

## Commands

Run from `ios/WalkingPadRemote/WalkingPadRemote`:

```sh
swift run telemetry-soak --minutes 30 --hr-ms 1000 --treadmill-ms 1000 --burst-every-seconds 30 --burst-native-records 32 --flush-every-seconds 60
swift run telemetry-soak --minutes 60 --hr-ms 1000 --treadmill-ms 1000 --burst-every-seconds 30 --burst-native-records 32 --flush-every-seconds 60
swift run telemetry-soak --minutes 120 --hr-ms 1000 --treadmill-ms 1000 --burst-every-seconds 30 --burst-native-records 32 --flush-every-seconds 60
```

Run the documented A/B candidate or instrumentation-isolation variant with:

```sh
swift run telemetry-soak --minutes 30 --hr-ms 1000 --treadmill-ms 1000 --burst-every-seconds 30 --burst-native-records 32 --flush-every-seconds 60 --batch-count 256
swift run telemetry-soak --minutes 2 --instrumentation-off
```

CI runs the stable two-minute profile explicitly and asserts exact
produced/persisted equality, zero native/critical/frame loss, a drained queue,
complete finalization, and a non-empty control-output checksum. Package tests
also compare instrumentation enabled and disabled checksums for equality.
