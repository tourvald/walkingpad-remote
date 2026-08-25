# Issue #33 post-workout Analyzer V1

Status: implemented Analyzer V1 contract.

This document owns the concrete metric definitions and lifecycle for
`workout-analyzer-v1.1`. The canonical evidence, causal, and safety rules remain
owned by the [data contract](data-contract.md),
[treadmill truth contract](treadmill-truth-and-command-lifecycle.md), and
[safety boundary](safety-boundary.md).

## Scope and dependency direction

Analyzer V1 is an offline consumer of one terminal Telemetry V2 session. Its
immutable input is the stored session, native HR observations, native treadmill
observations, typed events, and canonical frames. It writes only a derived
`WorkoutAnalysisResult`.

The pure `TelemetryAnalysis` target depends on `TelemetryDomain` and has no
dependency on the app, controller, BLE transport, recorder, or SwiftData.
`TelemetryPersistence` loads an immutable input snapshot, computes on a detached
utility task, and stores the result. `TelemetryRuntime` discovers that optional
persistence capability only after recorder finalization. Session completion is
published before analysis starts, and the result is ignored by runtime.

Analyzer availability, result, quality, failure, confidence, or exclusions are
never an input to Start HR Control, post-tap authorization, control decisions,
speed selection, Stop, cooldown, Watch lifecycle, source selection, settings, or
safety policy.

## Time and coverage

The session time coordinate is persisted monotonic elapsed time. A valid
terminal `endedElapsed` is authoritative. Only a terminal record without that
field falls back to the latest persisted/evidence elapsed coordinate.

An observation starts at `measuredElapsed` when present. Otherwise it starts at
`receivedElapsed`, and the fallback is counted. Analyzer V1 performs no
interpolation. HR and factual treadmill speed use half-open, left-continuous
holds:

- HR: from the effective observation time until the earliest of the next HR
  observation, a typed source-transition, phase or target boundary, session end,
  or 7 seconds;
- factual treadmill speed: from the effective observation time until the
  earliest of the next treadmill observation, a typed connection transition,
  phase boundary, session end, or 5 seconds.

Invalid, out-of-domain, stale, or unknown-freshness evidence starts no hold.
Treadmill evidence starts a hold only when it contains a factual normalized
speed. Desired, commanded, controller-target, expected, and modeled speeds are
never substituted.

Time after hold expiry and every uncovered gap remains uncovered. It is excluded
from covered-duration denominators and is never counted as zero, in-zone,
error-free, stable, or recovered. Sample count is used only for event/evidence
counts and distributions; it is never duration.

The workout-level factual average speed uses the persisted one-second canonical
frame ledger when frames are present. A second is covered only when that frame
contains factual normalized speed and explicitly marks the referenced native
observation fresh; a stale or missing frame remains uncovered. This is a
materialized bounded hold of decoded factual evidence, not interpolation or a
desired/commanded/estimated-speed fallback. Inputs without canonical frames use
the existing native-observation five-second hold as a deterministic legacy
fallback.

The average is available only when this factual-speed coverage is at least 90%
of the terminal session duration. This reuses Analyzer V1's accepted
high-coverage boundary so a small startup slice cannot be presented as a
representative full-workout average. Lower coverage keeps the average
unavailable and `workout-session-summary-v2` exports covered seconds, uncovered
seconds, the coverage ratio, the required ratio, and an explicit warning.
Desired, commanded, controller-target, expected, and modeled speed never fill
coverage. Canonical frames still cannot turn missing or non-factual native
evidence into factual speed or bridge a missing frame.

## Data quality

The versioned detail stores:

- HR covered/uncovered duration and ratio, gap count and maximum gap;
- effective-time inter-sample cadence and measured-to-received latency
  distributions;
- receive-time fallback, duplicate, out-of-order, and source-switch counts;
- factual treadmill covered/uncovered duration and ratio;
- command-to-ACK and command-to-factual-response causal coverage, with latency
  explicitly unavailable when persisted independent proof is absent;
- incomplete-session and recorder-loss flags;
- session and per-phase grades, explicit issues, exclusions, and unavailable
  reasons.

Quality issues preserve four separate classes:

1. `recorderEvidenceLoss`;
2. `protocolRuntimeCausalAmbiguity`;
3. `sourceCoverageUnavailable`;
4. `malformedCorruptEvidence`.

Protocol/runtime ambiguity does not set recorder loss. With HR coverage present,
the deterministic session grade is `low` for malformed evidence, recorder loss,
an incomplete session, or coverage below 50%; `medium` for coverage below 90%
or causal ambiguity; otherwise `high`. No HR coverage is `unusable`. Per-phase
grades use the same coverage/loss/malformed thresholds for that phase and list
their own HR and factual-speed exclusions.

## Workout and control metrics

All duration/error/state metrics below integrate the covered half-open segments:

- time in each of five configured HR zones;
- time and covered-time ratio inside the configured zone containing the current
  target;
- HR error from the current target: time-weighted MAE, RMSE, and integral
  absolute error;
- overshoot and undershoot duration, maximum and time-weighted mean magnitude,
  and magnitude integral;
- time from main-phase start to first covered target-range entry;
- time from main-phase start to the beginning of the first continuous 30-second
  covered target-range window;
- distinct command count and distribution of consecutive typed treadmill
  desired-speed decision deltas;
- HR drift in each continuous factual-speed window of at least 30 covered
  seconds whose speed remains within 0.1 km/h of that window's reference speed.
  V1 combines window slopes by covered-duration weight and reports covered time,
  window count, slope, and duration-weighted fit;
- a reserved descriptive event-aligned HR change metric for informative
  desired-speed changes of at least 0.2 km/h. It requires a persisted,
  independently verifiable factual-response causal proof before its 10-second
  before/after HR windows may be evaluated. The current accepted schema contains
  no such proof representation, so Analyzer V1 reports this metric unavailable.

The interval result is a versioned empty framework with
`intervalEngineImplemented == false`. Analyzer V1 does not implement an interval
engine.

## Causal metrics

The eligible causal denominator is persisted command-send attempts. Under the
current accepted persisted schema, neither ACK nor factual-response evidence
contains an independently verifiable proof representation for a specific
command/attempt association. A persisted
`deterministicallyCorrelated(commandID, attemptID)` claim therefore does not
prove an edge, even when its IDs, protocol, connection epoch, and ordering are
structurally consistent.

Consequently, command-to-ACK latency, command-to-factual-response latency, and
event-aligned HR response requiring a factual-response edge are unavailable.
Specific persisted claims are recorded as unsupported malformed causal evidence;
they are not counted as honest protocol/runtime ambiguity and do not imply
recorder loss. Honest unassociated evidence with nil causal IDs remains explicit
protocol/runtime ambiguity.

Structural checks such as missing attempts, duplicate identities, protocol or
epoch mismatch, and impossible ordering may reject a claim. They never establish
proof in the opposite direction. Analyzer V1 also never associates evidence
using timestamps, proximity, queue order, target similarity,
desired/commanded/modelled/expected speed, or canonical frames. Existing nil IDs
from Issues #29/#30/#32 remain nil.

Retry latency is a separate attempt-based metric. It may be calculated from
persisted command identity, unique attempt IDs, monotonic attempt numbers, typed
protocol/connection scope, and independently valid persisted ordering. Its
availability does not depend on ACK or factual-response causal proof.

## Cooldown

The typed cooldown phase defines the analysis interval. V1 reports duration and
HR coverage; covered start/end/peak HR; typed/configured target; time to first
covered HR at or below target; HR-below-target duration; factual time at or
below configured minimum speed; overlap duration and maximum continuous streak;
and the last typed cooldown lifecycle outcome.

HRR10/30/60/120 is `HR at cooldown start - HR at the named elapsed timestamp`.
The value is unavailable if the cooldown ended first or either exact timestamp
is not covered by a valid hold. It never selects the Nth sample. The recovery
slope and fit are weighted regressions over covered cooldown intervals and
require at least 30 covered seconds; the slope is signed bpm/min, so a falling
HR is negative. Timeout blocker remains explicitly
unavailable because V1 has no typed persisted blocker evidence.

## Reproducibility, persistence, and resume

Analyzer metadata includes:

- analyzer version `workout-analyzer-v1.1`;
- detail schema version `1`;
- metric definition `timestamp-hold-metrics-v2`;
- accepted telemetry schema range `1.0.0...1.0.0`;
- complete analyzer policy;
- generation timestamp;
- SHA-256 over deterministically ordered immutable inputs plus analyzer policy;
- quality grade, issues, exclusions, confidence, and unavailable reasons.

Analysis and record IDs are deterministic from session ID, analyzer version,
and evidence hash. Persistence keys results by the same logical identity. A
recompute with the same version and evidence hash returns the existing result;
if its logical payload differs, persistence reports a conflict rather than
overwriting evidence or the prior result.

On store preparation, terminal sessions are scanned in deterministic session
order and results missing the current analyzer identity are recomputed. The
version bump prevents a stored `workout-analyzer-v1` partial-speed result from
being reused as the current result. Completed, incomplete, and cancelled
sessions are eligible; created, running, and paused sessions are not. Analyzer
failure is contained as an analysis failure and cannot change recorder
finalization or product session completion.
