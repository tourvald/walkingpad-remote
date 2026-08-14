# Telemetry V2 performance budget

Status: normative measurement and acceptance contract.

Performance and storage numbers in this document are design targets and
hypotheses to measure. They are not scientific justification to downsample,
coalesce, reorder, or delete native training evidence. A miss requires analysis
and PM decision, not a silent semantic change.

## Control-path budget

The primary hard requirement is architectural:

- no database, JSON serialization, file synchronization, export, analysis, or
  blocking wait may run synchronously in a control or sensor callback;
- telemetry emission MUST be constant-time with respect to store size and MUST
  not run on the main actor merely because UI state is involved;
- the buffer MUST be bounded and telemetry backpressure MUST never propagate to
  command or safety execution;
- telemetry enabled and disabled MUST produce identical control outputs for the
  same deterministic input replay.

Wall-clock latency measurements do not replace inspection of actor/queue
ownership and code paths.

## Evidence pressure classes

| Class | Records | Pressure behavior |
| --- | --- | --- |
| critical causal evidence | observations used by control, decisions, command lifecycle, safety/stop/session transitions | MUST NOT be intentionally sampled for storage targets; reserve capacity where practical; unavoidable loss marks the interval and session incomplete |
| native scientific evidence | all HR/treadmill observations with native cadence and quality | MUST preserve arrival order and MUST NOT be silently downsampled; unavoidable loss is counted by type and time range |
| canonical frames | at-most-one per canonical second | MAY coalesce candidates within the same second; MUST NOT backfill gaps or replace native evidence |
| derived analysis | recomputable post-workout results | MAY be deferred/recomputed; MUST retain evidence identity/version |
| diagnostic chatter | raw BLE/debug/benchmark detail | First class eligible for bounded dropping/rotation; MUST remain separate from training evidence |

The implementation MUST define capacity, high-water mark, priority behavior, and
drain strategy before production integration. When a bound is reached it MUST
prefer dropping bounded diagnostic chatter, then eligible same-second frame
candidates. It MUST NOT block control. Any native or critical loss MUST create a
privacy-safe loss record containing record class, count, and elapsed interval,
not the private payload.

## Benchmark profiles

Issue #26 MUST provide a deterministic fixture generator and runner with:

- a fast CI profile;
- a configurable full profile representing approximately 1,000 workout-hours
  and several million records;
- documented deterministic seed, schema/build/toolchain, hardware/OS, store
  state, warm-up, repetitions, and percentile method;
- realistic proportions of native HR, treadmill changes, exact causal/lifecycle
  events, at-most-1-Hz frames, incomplete sessions, and analyses;
- history, chart, analysis, export, and last-N-comparable-session query shapes;
- reopen, forced interruption, partial-tail, and repeated migration scenarios.

Fixture generation MUST NOT be exposed as a production debug action capable of
accidentally allocating a full data set on a user's device.

## Measurements and hypotheses

The report MUST capture raw run summaries plus p50/p95 where meaningful for:

- ingress-to-buffer time and buffer high-water mark;
- batch size, transaction latency, throughput, retry/failure count, and drain
  time;
- recent-history, single-workout time-series, chart, analysis, export, and
  comparable-session query latency;
- peak memory during generation, persistence, fetch, analysis, export, and
  reopen;
- SQLite store/WAL/SHM size, growth per workout-hour, and post-checkpoint state;
- interruption recovery, committed-batch preservation, incomplete marking, and
  migration/reopen behavior;
- file protection and backup-exclusion state for the main store and every
  discovered sidecar after each relevant lifecycle operation.

Initial product hypotheses from the implementation queue are:

| Hypothesis | Measurement context |
| --- | --- |
| p95 transaction below 50 ms for a provisional 5-second/128-record batch | designated target device; batching parameters remain benchmark-derived |
| median ordinary-workout storage at or below 1 MB/hour | representative session mix, including indices and sidecars under the documented measurement method |
| p95 ordinary-workout storage at or below 2 MB/hour | same method; a miss does not authorize evidence loss |
| recent history and a normal single-workout fetch remain interactive at full fixture scale | query-specific target MUST be declared before the acceptance run and reported with device/context |
| previously committed batches survive interruption and reopen | forced-interruption scenario with evidence-count/hash comparison |

`5 seconds / 128 records` is only a provisional internal batching default if
measurements do not select a better bounded value. Changing it MUST NOT change
evidence semantics.

## Result classification and gates

Each item is classified:

- `PASS`: executed with the required environment/evidence and met the accepted
  architectural or measured target;
- `FAIL`: executed and violated a requirement or exposed material product risk;
- `UNVERIFIED_ON_DEVICE`: automated evidence cannot establish a device-only
  property. This is not a pass.

CI and hosted automation form the first validation layer. Every device-only item
MUST be carried verbatim to real-evidence gate #37. Physical validation is a
separate PM/user activity; normal implementation MUST NOT perform it implicitly.

A target miss MUST include the measured delta, confidence/variance, profiler
evidence, and product impact. It blocks only when it violates a hard architecture,
privacy, recovery, or safety requirement, or demonstrates material product risk.
Otherwise PM decides whether to accept, tune, or revise the hypothesis. Native
evidence MUST NOT be silently sampled to make a number pass.

A material SwiftData failure triggers the explicit fallback process in
[persistence-and-retention.md](persistence-and-retention.md), not an in-issue
technology switch.

## Privacy-safe observability

On iOS 26, instrumentation SHOULD use
[`OSSignposter`](https://developer.apple.com/documentation/os/ossignposter),
Instruments, and availability-correct MetricKit APIs. `MXMetricManager` is the
compatibility API for earlier systems and provides delayed aggregate reports;
the replacement `MetricManager` async API is iOS 27+. Neither is durable workout
telemetry or an immediate causal event stream.

Signposts, unified logs, MetricKit payloads, and benchmark summaries MUST NOT
include BPM/HR values, person-linked speed trajectories, private identifiers,
HealthKit UUIDs, raw BLE payloads, workout exports, or configuration snapshots.
They MAY contain only bounded opaque run IDs and aggregate record-class counts,
durations, queue depths, sizes, and error classes that cannot reconstruct or be
linked back to a private workout.
