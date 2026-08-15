# Telemetry V2 architecture

Status: normative contract for the Telemetry V2 implementation queue.

This document defines component ownership and dependency direction. The related
[data contract](data-contract.md), [persistence and retention policy](persistence-and-retention.md),
[rollout plan](rollout-and-migration.md), [performance budget](performance-budget.md),
and [safety boundary](safety-boundary.md) are equally normative.

`MUST`, `MUST NOT`, `SHOULD`, `SHOULD NOT`, and `MAY` express requirement
strength. A later issue MAY refine names and internal representation, but it
MUST preserve the requirements in this specification or obtain a new explicit
PM-approved behavior contract.

## Scope and non-goals

Telemetry V2 is a local data platform for timestamped workout evidence,
causal control events, materialized state frames, and reproducible post-workout
analysis. It replaces the prototype JSONL, wide-CSV, and capped `UserDefaults`
architecture through the gated migration described in
[rollout-and-migration.md](rollout-and-migration.md).

This specification does not implement or authorize:

- an interval engine, automatic adaptation, machine learning, or changes to
  control behavior;
- learning or expansion of any safety bound;
- a HealthKit transport redesign or an Apple Watch-only HR architecture;
- CloudKit, cloud synchronization, a backend, or remote telemetry;
- device installation, physical validation, treadmill access, or BLE commands.

## Platform boundary

The core product baseline for this Epic is iOS 26. Issue #39 MUST express that
package platform floor without silently changing the repository's
`swift-tools-version: 5.10`, Swift language mode, or macOS test-host floor. If
the actual toolchain cannot express and build the iOS 26 floor compatibly, #39
MUST stop for PM decision with the exact compiler/package error.

## Component graph

```text
HR providers                    decoded treadmill observations
     |                                      |
     +------ typed normalization -----------+
                        |
                  WorkoutEngine
               /                  \
       safety policies       control decisions
               \                  /
                 command service
                        |
              constant-time emission
                        |
               telemetry ingress
                        |
              bounded memory buffer
                        |
        isolated persistence consumer
                        |
          provisional SwiftData store
                /               \
      versioned analyzer     read projections
                                   |
                         history/charts/export
```

Dependencies MUST point downward. Telemetry components MUST NOT become a
dependency of a control or safety decision. Views and exports MUST consume
read projections and MUST NOT receive a persistence context directly.

## Component responsibilities

### Provider adapters and typed normalization

Provider adapters translate HealthKit, Watch connectivity, BLE-decoded state,
and future sources into the types defined by the
[data contract](data-contract.md). They MUST preserve native values, units,
arrival order, source metadata actually supplied by the provider, and both
measurement and receipt timestamps when available.

The normalized HR boundary MUST be provider-agnostic. HealthKit source metadata
can identify an app or hardware such as an iPhone, Apple Watch, or Bluetooth HR
monitor; code MUST NOT infer a physical sensor identity or assume Apple Watch
when the provider reports only an unknown or selected HealthKit source. See
[`HKSourceRevision`](https://developer.apple.com/documentation/healthkit/hksourcerevision).

Normalization MAY add explicit quality flags. It MUST NOT reorder, deduplicate,
drop, or alter the controller-facing HR stream. It MUST NOT turn an estimate or
unit guess into a factual treadmill observation.

### WorkoutEngine, safety policies, and command service

These existing owners remain authoritative for workout state, safety decisions,
and command behavior. They MAY emit immutable typed telemetry records. Emission
MUST be constant-time, non-blocking, and independent of persistence success.

The command service owns enqueue/send behavior and protocol outcomes. Telemetry
records the resulting causal lifecycle; it does not initiate, retry, cancel, or
confirm commands. Stop confirmation continues to require fresh factual device
evidence as defined by the current safety contract.

### Telemetry ingress and bounded buffer

Ingress accepts already-formed value records and assigns recorder-local ordering
metadata where required. It MUST NOT perform database access, JSON encoding,
file I/O, export, analysis, or synchronous cross-process work in a control or
sensor callback.

The buffer MUST be bounded. Overflow behavior MUST follow the evidence classes
and loss accounting in [performance-budget.md](performance-budget.md); it MUST
never block control. Buffer health and any loss MUST be observable without
logging private payloads.

### Isolated persistence consumer

One isolated consumer drains the buffer in bounded batches and is the only
production writer to the V2 store. It owns transactions, relationships,
deduplication by real identity, store lifecycle, and incomplete-session recovery.
SwiftData is provisional until its explicit benchmark, protection, and recovery
gate passes. Details are in
[persistence-and-retention.md](persistence-and-retention.md).

### Canonical frames

A frame is an at-most-1-Hz materialized view of state actually available while
the recorder is running. It MAY carry the latest known value only with the
source record ID, original timestamp, and freshness/quality state. It MUST NOT
claim that carried state is a new sensor observation.

The recorder MUST persist at most one frame for a session's canonical elapsed
second. It MUST NOT synthesize frames after a pause, process suspension, crash,
restart, disconnect gap, or other interval in which no frame was materialized.
Missing seconds remain gaps, and a later frame or recorder/lifecycle event MUST
make the gap boundary explicit so analysis can distinguish an observed second
with no new native sample from an unobserved or unpersisted second. Native
observations and exact events retain their own cadence independently of frames.

### Versioned analyzer

The analyzer is a post-workout consumer. It MUST read immutable evidence, use
timestamp- and freshness-aware calculations, and write a versioned result keyed
by analyzer version and evidence identity/hash. The same inputs and version MUST
produce the same result, and rerunning MUST be idempotent.

Analysis and recommendations are derived data, not evidence. They MUST NOT feed
the production controller in this Epic. No analyzer operation may run on a
control or sensor callback.

### Read projections, export, and instrumentation

History, charts, statistics, and export consume bounded V2 queries and explicit
projections. CSV and summaries become export formats, not independent stores.
Export MUST be non-destructive.

Performance instrumentation is a separate privacy-safe diagnostic channel. On
the iOS 26 baseline it SHOULD use `OSSignposter`, Instruments, and
availability-correct MetricKit APIs. The newer `MetricManager` async API is an
iOS 27+ API; it MUST NOT be presented as an iOS 26 dependency. Instrumentation
MUST NOT contain HR values, private identifiers, raw BLE payloads, or workout
exports.

## Availability and failure direction

- Control and safety MUST operate when telemetry is disabled, unavailable,
  backpressured, corrupt, or recovering.
- Telemetry failure MUST be surfaced as recorder/session health and MUST NOT
  authorize motion, weaken a safety gate, or delay a command.
- A read, export, or analyzer failure MUST remain in that subsystem. It MUST NOT
  fall back silently to contradictory legacy facts after V2 read cutover.
- Debug, preview, benchmark, replay, and simulator paths MUST remain isolated
  from production transport and MUST obey the same type/provenance rules.

## Implementation ownership by queue

| Issue | Contract-owned output |
| --- | --- |
| #39 | Combined Foundation: pure typed domain first, then a versioned V1 schema and isolated local store after the domain checkpoint passes |
| #26 | Automated SwiftData scale, recovery, protection, and fallback gate after #39 |
| #27 | Constant-time ingress, bounded buffering, batching, and loss accounting |
| #28 | HR normalization with unchanged controller arrival behavior |
| #29 | Factual treadmill truth and command/estimate separation |
| #30 | Session lifecycle, observed frames, and production dual-write |
| #31 | Privacy-safe instrumentation and soak harness |
| #32 | Deterministic replay and legacy-to-V2 parity |
| #33 | Versioned timestamp-weighted post-workout analysis |
| #34 | Idempotent conservative legacy import/reconciliation |
| #35 | V2 read cutover with temporary legacy shadow-write |
| #37 | Separate user/PM-supplied real-evidence validation gate |
| #36 | Legacy retirement only after the #37 gate authorizes it |

Each issue MUST use the inputs and invariants defined here and in the linked
documents. Sequential delivery and the gates in
[rollout-and-migration.md](rollout-and-migration.md) prevent a later issue from
silently changing an earlier contract.
