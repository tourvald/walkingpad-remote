# Telemetry V2 recorder ingress

Status: Issue #27 implementation note. The normative contracts in this directory
remain authoritative.

Issue #27 provides an unwired recorder pipeline. It does not connect any current
sensor, engine, application-lifecycle, BLE, controller, UI, history, or export
producer. Issues #28 through #30 own production integration.

## Dependency direction

```text
TelemetryDomain
      ^
      |
TelemetryRecorder       (no SwiftData dependency)
      ^
      |
TelemetryPersistence    (TelemetryStore adapter and SwiftData transaction)
```

`TelemetryRecorder` owns ingress, buffering, sequencing, scheduling, batching,
and recorder lifecycle. `TelemetryPersistence` implements the recorder-facing
protocol on the existing `TelemetryStore`. The application and
`WalkingPadCoreLogic` do not depend on or instantiate the recorder in #27.

## Producer contract and recorder ordering

`TelemetryIngress.yield(_:)` is synchronous and non-throwing. It assigns a
recorder-local monotonic sequence while holding a short lock, applies bounded
admission, optionally wakes the single consumer, and returns an admission
receipt. It performs no actor hop, await, task creation, persistence, filesystem
access, JSON work, analysis, export, or network work.

The sequence is an operational total order after concurrent calls are
linearized. It does not replace provider arrival sequence, native identity,
measurement time, receipt time, or causal identifiers. It is passed to the
persistence boundary to preserve batch order but is not a new durable cross-table
scientific ordering field.

The buffer reserves its slot arena and exact-frame identity index at recorder
creation. Global FIFO links, a bulk-frame eviction list, and exact-identity hash
lookup keep normal enqueue, coalescing, and permitted eviction bounded without
buffer scans or `Array.removeFirst()`.

## Record classes and pressure rules

The initial injected buffer policy is 2,048 total slots, including 256 slots
reserved from non-critical use and 512 additional slots reserved from bulk
frames for native evidence. This represents 16 provisional 128-record batches,
with two batches protected for critical evidence and four for native evidence.
It is a conservative integration starting point, not a permanent product
constant; #31 owns tuning with integrated soak evidence.

Records are classified as follows:

- Critical: source/connection identity transitions and typed workout events.
  Normal bulk pressure cannot consume the critical reserve. If the arena is full,
  a critical record evicts the oldest queued frame. Critical loss occurs only
  when no frame is available to evict.
- Native: HR and treadmill observations. They are never value-, timestamp-, or
  similarity-coalesced. Native admission may evict the oldest frame, but it
  cannot consume the critical reserve.
- Bulk: canonical frames. A queued frame may be replaced only by a later
  candidate with the exact same session and canonical-second identity. The new
  candidate moves to the global sequence tail. Otherwise excess frames are
  dropped before native or critical evidence.

Every coalesced or dropped frame and every unavoidable native or critical loss
is counted. Any drop or loss makes the session incomplete. The recorder never
fabricates or backfills frames, alters native observations, or affects treadmill,
speed, HR selection, cooldown, command, or safety behavior.

## Consumer, batching, and persistence

Each recorder owns one long-lived utility-priority consumer. An `AsyncStream`
with a one-element wake buffer coalesces wake notifications. At most one
monotonic scheduler operation is armed for a batch deadline or retry; ingress
does not create timers or tasks per record.

The initial injected batch policy flushes at 128 records or five seconds from
the oldest queued record, whichever occurs first. Explicit and lifecycle flush
reasons use the same recorder control plane. They are not wired to application
lifecycle callbacks in #27.

The session header is submitted first by the asynchronous consumer. Body batches
do not pass that boundary until the header succeeds. A body batch is delivered
to `TelemetryRecorderPersistence.persistBatch(_:)` in strictly increasing
recorder sequence. `TelemetryStore` validates that order and maps the entire
batch through one explicit SwiftData transaction; it does not loop over
independently saving public calls.

## Retry, failure, completion, and recovery

The initial injected retry policy permits one retry after 250 milliseconds, only
when the persistence implementation explicitly reports a failure known to have
happened before commit. Terminal failures and unknown commit outcomes are never
retried because replay could duplicate an already committed batch. #31 may tune
the conservative retry default from integrated evidence without changing this
safety distinction.

Normal `finish` stops admission, drains the accepted prefix, finalizes the
session, and reports complete only when no record is known lost and all required
persistence succeeded. Explicit failure, retry exhaustion, ambiguous commit,
catastrophic pressure, and discarded or uncertain tail evidence cannot become a
complete session. A persistence adapter must resolve an ambiguous final-state
commit by reading back exact stored state; the SwiftData adapter does so. If an
unresolved completion update still fails, the recorder makes a fail-closed,
best-effort terminal update and reports failure rather than success.
Failure or cancellation accepted while completion finalization is in flight
changes terminal intent under the recorder lock. A possibly committed completion
is followed by an idempotent fail-closed incomplete or cancelled finalization;
the recorder does not claim that the earlier transaction was rolled back.
Cancellation accounts the queued or in-flight uncertain tail, persists the
terminal `cancelled` lifecycle, does not fabricate success, and terminates the
consumer.

`unfinishedSessions()` exposes only persisted `created`, `running`, or `paused`
sessions. Persisted `completed`, `cancelled`, and `incomplete` states are terminal
and excluded. `recoverUnfinishedSessions(using:)` marks genuinely unfinished
sessions incomplete without inventing an end time, end elapsed value, or
successful completion. Repeated recovery therefore preserves an existing
incomplete reason and recorder-health summary. The method is deliberately not
connected to app launch in #27 and is not a claim of crash-proof delivery.

## Privacy-safe operational state

The recorder exposes queue depth and peak, coalesced and dropped frame counts,
lost native and critical counts, writer failures, retries, successful flushes,
last committed recorder sequence, latest flush duration, lifecycle state, and
completeness. These counters contain no BPM, samples, source identifiers, raw
BLE payloads, or exports and are not a user-facing UI contract.

Issue #31 is expected to retune buffer capacities, reserves, batch count/time,
and the conservative pre-commit retry parameters from integrated soak evidence.
It must not use tuning to weaken native evidence, causal fidelity, safety
boundaries, or completion semantics.
