# Issue #33 post-workout Analyzer V1

Status: implemented Analyzer V1 contract.

This document owns the concrete metric definitions and lifecycle for
`workout-analyzer-v1`. The canonical evidence, causal, and safety rules remain
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

Canonical frames participate in the deterministic evidence hash but not in V1
metric timelines. They cannot create a native sample, factual speed, or hold,
and cannot bridge or backfill a gap.

## Data quality

The versioned detail stores:

- HR covered/uncovered duration and ratio, gap count and maximum gap;
- effective-time inter-sample cadence and measured-to-received latency
  distributions;
- receive-time fallback, duplicate, out-of-order, and source-switch counts;
- factual treadmill covered/uncovered duration and ratio;
- command-to-ACK and command-to-factual-response causal coverage and latency;
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
- descriptive event-aligned HR change for informative desired-speed changes of
  at least 0.2 km/h. Each side is a 10-second window and requires at least 50%
  HR coverage. The result includes evidence count, distribution, standard error
  when estimable, and explicitly does not claim a causal treatment effect.

The interval result is a versioned empty framework with
`intervalEngineImplemented == false`. Analyzer V1 does not implement an interval
engine.

## Causal metrics

The eligible causal denominator is persisted command-send attempts. ACK or
factual-response latency is calculated only when a typed persisted edge names
the exact matching command and attempt and occurs no earlier than that send.
Unassociated legacy ACK and factual-response evidence increments explicit
unknown-association accounting but yields no latency.

Retry latency uses known command and attempt numbers only. Event-aligned HR
response additionally requires a proven factual-response edge tied through the
typed command-to-decision identity to an informative speed decision.

Analyzer V1 never associates evidence using timestamps, proximity, queue order,
target similarity, desired/commanded/modelled/expected speed, or canonical
frames. Existing nil IDs from Issues #29/#30/#32 remain nil.

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

- analyzer version `workout-analyzer-v1`;
- detail schema version `1`;
- metric definition `timestamp-hold-metrics-v1`;
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
order and missing results are recomputed. Completed, incomplete, and cancelled
sessions are eligible; created, running, and paused sessions are not. Analyzer
failure is contained as an analysis failure and cannot change recorder
finalization or product session completion.
