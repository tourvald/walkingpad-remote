# Telemetry V2 data contract

Status: normative semantic contract.

This document defines evidence, time, provenance, identity, units, records, and
analysis semantics. Concrete Swift names MAY differ, but the distinctions below
MUST remain representable and queryable.

## Truth and provenance vocabulary

| Term | Meaning | Required rule |
| --- | --- | --- |
| factual observation | A value reported by an identified provider or decoded from a device observation | MUST retain native value, unit, source/provenance, and timestamps; absence remains `nil`/unknown |
| measured | The source says the value was measured by a sensor | MUST NOT be inferred from receipt alone |
| reported | The source or device reported the value; measurement method may be unknown | MUST identify that source and MUST NOT be relabeled measured without evidence |
| commanded | A value contained in a command that was queued or sent | MUST NOT be treated as observed device state |
| desired | A controller target before transport/protocol effects | MUST remain distinct from commanded and observed values |
| estimated | A model, interpolation, or app-side calculation | MUST carry method/version and MUST NOT populate a factual field |
| derived | A reproducible calculation from persisted evidence | MUST carry analyzer/derivation version and evidence identity |

`actual`, `current`, `target`, `speed`, `state`, and `duration` are forbidden as
standalone persisted semantics when they do not identify which category above
they mean. Missing factual evidence MUST remain `nil`/unknown. A commanded speed,
desired speed, model estimate, stale last-known value, or controller-native unit
guess MUST NOT fill a factual physical-speed field.

## Time model

Every persisted record MUST carry:

1. wall-clock correlation (`recordedAt` or an equivalent absolute `Date`);
2. a signed integer elapsed offset from the session's monotonic origin, using
   one documented precision such as microseconds or milliseconds;
3. the timestamp roles applicable to that record.

Timestamp roles are distinct:

- `measuredAt`: when the provider says a sample was measured; `nil` when unknown;
- `receivedAt`: when this process received the observation;
- `occurredAt`: when an app-owned event happened;
- `enqueuedAt`, `sentAt`, `acknowledgedAt`, and `timedOutAt`: command lifecycle
  event times, represented as exact events rather than overwritten fields;
- `recordedAt`: wall time assigned when the immutable telemetry record was made.

Control timing MUST use the runtime monotonic clock, never wall-clock deltas.
Swift's [`ContinuousClock`](https://developer.apple.com/documentation/swift/continuousclock)
is suitable at a runtime boundary because it advances monotonically, including
during sleep, but its `Instant` MUST NOT be persisted as a cross-launch or
cross-device identity. Persisted elapsed offsets and wall time MUST be explicit.

Records MUST preserve arrival order even when `measuredAt` is duplicated,
missing, or earlier than a previously received sample. Sorting for display or
analysis MUST NOT rewrite evidence order. Clock regressions, impossible ordering,
and excessive receive delay MUST be quality-flagged.

An exact provider redelivery is idempotent at the persistence boundary only when
the provider supplies a non-empty stable native sample identifier. That identity
MUST be scoped by the signal source's stable provider/local identity. A repeated
native identity MUST NOT create a second scientific sample, even when recorder-
local record and observation IDs differ. Provider sequence, BPM, timestamps, or
value similarity MUST NOT substitute for native identity. When native identity
is absent, otherwise identical observations remain separate evidence. This
storage rule MUST NOT reorder, filter, or deduplicate the controller-facing HR
stream.

Analysis MUST integrate over timestamp intervals for which evidence is fresh.
It MUST define gap and boundary behavior and MUST NOT treat a sample count as a
duration in seconds.

### Time-weighted analysis semantics

The default analytical time coordinate is the persisted monotonic elapsed offset.
For a provider observation, analysis uses the provider measurement time mapped
to that coordinate when it is present and trustworthy; otherwise it uses the
receive-time coordinate and records the fallback as quality/provenance.

For state-like HR, target, zone, and factual-speed metrics, Analyzer V1 MUST use
a left-continuous, piecewise-constant hold from an observation's effective time
until the earliest of the next applicable observation, the accepted freshness
limit, a source/phase/session boundary, or an explicit gap. The interval starts
at the observation and excludes its end boundary. It MUST NOT carry state beyond
freshness expiry or interpolate across a gap.

A metric MAY use bounded interpolation only when its versioned definition names
the method, both bracketing observations are valid/fresh and from compatible
sources, and their separation is inside an explicit maximum gap. Otherwise the
point or interval is unavailable.

Time in stale, missing, ambiguous, or unobserved intervals MUST be reported as
uncovered and excluded from covered-duration denominators; it MUST NOT become
zero or error-free time. Time-weighted MAE, RMSE, AUC, zone time, target-range
time, overshoot/undershoot duration, recovery, and stable-speed drift MUST
integrate their function over covered elapsed intervals. Event counts remain
counts. HRR10/30/60/120 MUST be unavailable or low-confidence when the required
timestamp coverage or permitted interpolation is absent; it MUST NOT select the
Nth sample as though cadence were 1 Hz.

## Identity and causal correlation

Stable typed identifiers MUST exist for at least session, record, source,
observation, decision, command, frame, and analysis. IDs from unrelated domains
MUST NOT be interchangeable.

The causal chain is:

```text
observation(s) used -> decision -> command enqueue/send
                    -> ACK or timeout -> observed treadmill response
```

- A decision MUST reference every observation record it actually used, plus the
  immutable configuration/safety-policy version under which it ran.
- A command lifecycle event MUST reference its decision and command IDs when
  applicable.
- ACK, timeout, write result, cancellation, retry, and transport failure MUST be
  separate factual events. They reference a command attempt only when the
  runtime or protocol proves that exact edge deterministically.
- The accepted legacy global ACK/timeout/write-result callbacks do not prove an
  attempt. Their association is `unresolvedByLegacyRuntime`, with `commandID`
  and `attemptID` absent. Such an event MUST NOT complete or mutate a specific
  attempt in evidence state.
- A consumer MUST NOT infer association from latest/oldest/nearest command,
  timing proximity, queue position, target or expected/modelled speed, packet
  similarity, a canonical frame, or the global pending-ACK slot.
- A retry-scheduled event's queryable primary attempt ID is the next scheduled
  attempt; its typed payload MUST also retain the previous attempt ID so the
  retry edge is not lost.
- A later treadmill observation MAY reference the command as a causal response
  only when independent deterministic evidence proves the edge. Otherwise its
  command and attempt association remains nil/unknown; mere temporal proximity
  MUST NOT be recorded as causation.
- Absence of ACK or observed response remains absence, not success.

## Units

Native evidence MUST preserve the numeric value and native unit exactly as
decoded or supplied. A normalized physical field MUST name its unit explicitly.
The canonical physical treadmill-speed unit is km/h.

- Conversion requires a known source unit and a versioned deterministic rule.
- Unknown or unconfirmed controller unit semantics produce no factual normalized
  km/h value.
- Desired, commanded, reported-native, reported-physical, estimated, and derived
  speed MUST use separate fields or types.
- Distance and duration MUST identify whether they are a native cumulative
  observation, a session projection, or a derived analysis result.

## Source model

A signal source records a provider kind and a stable local key. It MAY include
HealthKit source revision, device metadata, and provider sample UUID only when
those values are actually available. The provider/source kind MUST support at
least `unknown` and a HealthKit-selected source without inventing a sensor name.

HealthKit `sourceRevision` describes the app/device that saved an object and is
not always a complete physical-sensor identity; supported hardware is not
Apple Watch-only. The contract therefore MUST keep provider, saving source, and
physical device metadata as separate optional facts. See
[`HKObject.sourceRevision`](https://developer.apple.com/documentation/healthkit/hkobject/sourcerevision)
and [`HKSourceRevision`](https://developer.apple.com/documentation/healthkit/hksourcerevision).

## Quality and freshness

Quality is additive metadata, not permission to discard evidence. The typed
domain MUST represent at least:

- missing source or measurement time;
- duplicate provider identity/sequence;
- out-of-arrival-order measurement time;
- invalid or out-of-domain native value;
- stale-at-use evidence and unknown freshness;
- clock regression or implausible receive latency;
- gap before the record;
- recorder loss before the record;
- estimated/derived provenance where applicable.

Duplicate-value, duplicate-sequence, and out-of-order HR observations MUST be
preserved and flagged unless they are an exact provider redelivery proven by the
same stable native sample identity described above. The controller-facing
ordering and acceptance decision remain unchanged during V2 normalization. A
record MUST separately state whether it was accepted/used for control; quality
flags alone MUST NOT reconstruct that decision.

Freshness MUST be evaluated from the original observation time role and the
policy/version that consumed it. A stale value carried into a frame remains
stale and references its original record.

## Conceptual records

Telemetry V2 has seven conceptual records. The implementation MAY refine names
or split storage tables, but MUST NOT collapse them into one giant nullable event
table.

### 1. Workout session

Required semantics: stable session ID; profile-local identity; lifecycle and
completion/incomplete reason; workout mode; start/end wall and elapsed times;
app/build/OS; telemetry schema; algorithm, safety-policy, and workout-protocol
versions; immutable configuration snapshot/hash; optional HealthKit workout UUID;
and recorder health summary.

### 2. Signal source

Required semantics: source ID, provider kind, stable local key, optional known
provider/device metadata, and first/last seen timestamps. Unknown facts remain
absent.

### 3. Heart-rate sample

Required semantics: observation ID, session/source IDs, BPM, provider sequence
or UUID when present, measured/received/recorded/elapsed times, arrival order,
quality/freshness, and explicit accepted/used-for-control state.

### 4. Treadmill sample

Required semantics: observation ID, session/source IDs, raw/native value and
unit, optional factual normalized physical value, device state, timestamps,
arrival order, quality/freshness, and provenance. Estimates and command targets
do not belong in factual observation fields.

### 5. Event

An event has a compact common envelope (record/session ID, event kind, event
time, elapsed offset, source, causal IDs, payload schema version) and a typed,
versioned payload. Routine query fields MUST remain indexable; event-specific
detail MUST NOT create hundreds of nullable columns.

The event taxonomy MUST cover:

- session lifecycle and incomplete/recovery state;
- workout phase transition;
- HR source/provider transition;
- treadmill connection/state transition;
- control decision and observations used;
- command enqueue, send/attempt, ACK, timeout, cancellation, retry, and failure;
- manual stop, cooldown, safety-gate, and stop-confirmation evidence;
- recorder pressure, loss, drain, persistence, and recovery health.

Raw BLE payloads are diagnostic chatter, not normal event payloads.

### 6. Canonical frame

A frame is a query-oriented materialized state view keyed uniquely by session
and canonical elapsed second. It MUST carry its materialization time and the IDs,
timestamps, provenance, and freshness of evidence represented in the frame.

At most one frame MAY exist per canonical second. A real-time materializer MAY
carry the latest observation across an active second only as a last-known value
with unchanged evidence identity and explicit freshness. It MUST NOT create a
new native observation. It MUST NOT backfill a frame after a runtime gap. Missing
seconds remain missing. A later frame or typed recorder/lifecycle event MUST
identify the elapsed gap boundary and whether it reflects no observation,
runtime suspension/stall, recorder outage/loss, or an unknown cause when that is
all that is known.

### 7. Workout analysis

Required semantics: session ID, analyzer version, evidence identity/hash,
generation time, data-quality grade, queryable key metrics, and a versioned
detailed payload. Results MUST be deterministic, idempotent, and recomputable
from retained evidence. Recommendations, if introduced after this Epic, MUST be
separate from both analysis and evidence.

## Source-of-truth matrix

| Question | Authoritative evidence | Explicitly not authoritative |
| --- | --- | --- |
| HR received/used by control | Native HR observation plus accepted-for-control state and decision reference | Frame, chart point, average, inferred sensor name |
| Treadmill factual state/speed | Native decoded treadmill observation with known unit/provenance | Desired, commanded, estimated, or last-known value without freshness |
| Controller intent | Typed decision and desired value | Device observation |
| Command requested/sent/outcome | Correlated command lifecycle events | Target snapshot or later speed alone |
| Session/phase/source/connection/safety transition | Exact typed event | Frame-only state change inference |
| Fast chart/replay join | Canonical frame with evidence references | Fabricated 1 Hz sensor series |
| Metric or duration | Versioned timestamp-weighted analysis | Sample count treated as seconds |
| Performance/recorder health | Privacy-safe diagnostic metrics and recorder-health events | Unified logs containing workout payloads |

## Legacy terminology mapping

Legacy fields are migration inputs, not V2 names. Import/replay code MUST map
them explicitly and preserve ambiguity rather than guess.

| Legacy term | Required V2 interpretation |
| --- | --- |
| `speed_actual_kmh` | factual only if the source proves physical treadmill speed; otherwise import as reported/estimated with provenance |
| `speed_target_kmh` | desired controller speed |
| `speed_device_target_kmh` | controller/device command-domain target, not observation |
| `speed_reported_kmh`, `speed_reported_app_kmh` | reported values with their original source and unit semantics |
| `target_bpm` | event-scoped target; main-workout and cooldown targets MUST be distinct |
| `duration_s` | cumulative snapshot field, not automatically session wall duration |
| `session_duration_s`, `workout_duration_s` | derived summary projections with documented start/end inputs |
| `distance_km` | identify native cumulative observation versus derived session summary |
| `phase`, `session_state`, `treadmill_status` | separate workout phase, app session lifecycle, and device state domains |
| `steps` | identify cumulative source value versus delta/derived total; synthetic values are not factual |
| `workout_history_v1` | legacy summary/history projection, not raw telemetry evidence |
| raw/session-summary CSV | export/projection of legacy evidence, not an independent source of truth |

Legacy Python diagnostic fields (`belt_state`, `speed`, `time`, `dist`, `steps`,
and `app_speed`) and stop-truth experiment JSONL have their own schemas. They
MUST NOT be silently interpreted as iOS Telemetry V2 records.
