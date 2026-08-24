# Treadmill truth and command lifecycle

Issue #29 adds typed, synchronous observation seams around the existing runtime.
The seams are representation-only: they do not authorize or influence BLE,
control, queueing, retry, units, HR, cooldown, Start, or stop behavior.

## Ownership and risk map

| Runtime owner | Authoritative truth | Observation point | Risk boundary |
| --- | --- | --- | --- |
| `BLETransportCodec` | Protocol-native decode | After the existing state update | Preserve native value and quality; never substitute an app target or estimate |
| `ControllerUnitsTruthTracker` | WalkingPad unit truth and connection epoch | After `record` or `recordMalformed` | Unknown, stale, invalid, malformed, or old-epoch truth leaves normalized factual speed absent |
| `CommandQueueService` and `BluetoothManager` | Command bytes, equality, admission, order, coalescing, interval, and write | Side metadata after the authoritative queue operation | IDs never enter `Command`; missing or mismatched metadata loses correlation instead of changing control |
| Legacy global ACK/timeout slot | Existing ACK and timeout behavior | After the existing flag mutation | Association is `unresolvedByLegacyRuntime` with nil command and attempt IDs |
| `StopObservationService` | The only stopped predicate | After its evaluation and finalization | Target zero, modeled zero, write success, ACK, or timeout cannot confirm stop |
| Existing HR decision branch | The HR deliveries actually used by control | At the existing #28 control-use seam | HR decisions reuse exactly those causal references; other decisions have none |
| Existing SwiftUI and runtime gates | Start affordance and post-tap motion authorization | Regression coverage only | Telemetry cannot become a UI or runtime gate |

## Protocol observations

### WalkingPad

- FE01 reports speed as native controller-unit tenths.
- The raw tenths value is retained before the legacy `raw / 10` presentation and
  control conversion.
- Physical km/h is produced only when the current connection epoch has
  checksum-valid metric controller-unit truth.
- During an active HR-controlled workout and cooldown, the existing read-only
  `A6 key=0` query refreshes unit truth on a 20-second cadence only in a proven
  motion-idle window: the command queue is empty, no write is processing, the
  existing WalkingPad write-spacing deadline has passed, and more than two
  seconds remain before the next scheduled HR/cooldown motion decision.
- If no such idle window exists, the query is skipped and factual telemetry may
  degrade when unit truth reaches the existing 30-second limit. The query never
  delays a scheduled motion write; high-priority Stop retains its existing queue
  reset and spacing bypass. The motion gate remains independently unchanged and
  a later Start still requires fresh unit evidence under the same fail-closed
  rule.
- Imperial, unknown, not-read, stale, malformed, invalid-checksum, or old-epoch
  unit truth retains the native evidence but produces no factual physical km/h.
- The callback exposes receive time, not device measurement time, so
  `measuredAt` is nil.

### FTMS

- Treadmill Data instantaneous speed is protocol-native hundredths of km/h.
- The raw hundredths value and the existing moving state are retained.
- No device measurement timestamp is exposed by the current parser.
- Control Point notifications preserve their existing legacy ACK treatment; they
  are not inferred to acknowledge a particular attempt.

### FitShow

- Current decoded speed is native tenths of km/h.
- Checksum quality is retained. A bad checksum still follows the existing legacy
  state-update path but cannot create valid factual speed evidence.
- Status state is retained as a raw value; this change does not invent a new
  state interpretation.
- No device measurement timestamp is exposed.

### Unknown protocol

Unknown remains unknown. No factual speed, state, ACK association, or stop result
is fabricated.

## Typed speed semantics

The domain keeps separate types for:

- protocol-native controller/device speed;
- normalized factual physical km/h;
- a controller-reported target, if a protocol genuinely reports one;
- desired app speed;
- commanded speed;
- expected or modeled app estimates.

`speedKmh` is the existing modeled ramp. `expectedSpeedKmh` is parsed from an app
command label. `desiredSpeedKmh` is an app intent and `deviceTargetSpeedKmh` is a
commanded target. None can populate factual observation evidence.

## Connection epoch

`controllerUnitsConnectionEpoch` remains the single authoritative epoch concept.
Treadmill observations, decisions, command lifecycle evidence, ACK/timeout
observations, and stop evidence wrap that UUID; they do not create a competing
runtime epoch.

Queued metadata from an older epoch is cancelled observationally and cannot be
attached to a later write. If the legacy runtime still performs a write for
which metadata is missing or stale, the evidence is explicitly unassociated.
Telemetry never cancels or delays the legacy write.

## Decision, command, and attempt identity

- `DecisionID` identifies a manual, Start, HR, cooldown, stop, or maintenance
  decision when the existing path exposes one.
- `CommandID` identifies a semantic command request.
- `CommandAttemptID` identifies each actual BLE write attempt.
- Commanded speed retains the exact protocol-native wire scale: WalkingPad
  controller tenths, FTMS hundredths of km/h, or FitShow tenths of km/h.
  WalkingPad command evidence never borrows controller-unit truth or claims km/h.
- Scheduled legacy stop retries reuse one `CommandID` and receive distinct
  attempt IDs and monotonically increasing attempt numbers.
- A sidecar mirrors only labels and typed metadata. The legacy
  `CommandQueueService.Command` remains exactly `Data + label`, so random IDs do
  not affect equality, coalescing, order, or admission.
- Queue delay is observed from authoritative enqueue and write timestamps.

If sidecar order or epoch cannot be proven, correlation becomes nil. The control
path never reads the sidecar or sink disposition.

## ACK, timeout, write result, and response semantics

The legacy runtime has one global pending-ACK flag rather than per-attempt ACK
identity. Per the binding PM decision on Issue #29:

- a matching notification is retained as a factual ACK observation;
- its association is `unresolvedByLegacyRuntime`;
- `commandID` and `attemptID` are nil;
- it never completes a telemetry attempt;
- replay cannot infer an association from latest/oldest/nearest command, timing,
  queue order, target, expected/modelled speed, packet similarity, or the global
  pending slot;
- reconnect epoch prevents later cross-attachment.

The same honesty applies to the global timeout and characteristic write-result
callbacks. `didWriteValueFor` is a write result, not an ACK.

A later treadmill report is always a new factual observation. It remains
unassociated unless a protocol-independent deterministic proof exists; sending a
target or waiting is not proof of response.

## Stop truth

`StopObservationService` remains the sole stop predicate. For WalkingPad it
requires the existing post-write, same-context, fresh, checksum-valid FE01 report
with raw speed zero and an accepted non-running state. Telemetry observes that
evaluation and its finalization.

FTMS and FitShow do not currently participate in that lifecycle. Their stop
outcome therefore remains explicitly unconfirmed/confirmation-unavailable.

The following are never stop confirmation:

- desired, target, commanded, expected, or modeled speed zero;
- a write call or successful write callback;
- an ACK signal;
- timeout;
- a stale, missing, wrong-epoch, or checksum-invalid report.

The existing retry schedule, WalkingPad toggle fallback, raw/app/modelled speed
fallback, unavailable-stop handling, freshness window, and disconnect behavior
are unchanged.

## HR and Start invariants

An HR speed decision reuses the exact `HeartRateControlUseEvidence.inputs` built
at the accepted #28 decision branch. Manual, cooldown, Start, stop, and maintenance
decisions do not borrow the latest HR observation.

The Start HR Control affordance remains:

`treadmill connected && current/fresh HR visible`

It does not read factual speed, units quality, command IDs, ACK correlation, sink
health, recorder, or persistence. After a tap, the existing Watch and controller
units gates still fail closed before `startWithSpeed` and are not weakened.

## Failure isolation and #30 boundary

The optional sink is synchronous and nonthrowing. Its disposition is discarded.
Absent, accepted, degraded, and rejected sinks must produce the same packets,
queue order, deterministic send timing, ACK/timeout/retry behavior, targets, and
stop outcome.

No treadmill observation path performs SwiftData, `ModelContext`, filesystem or
JSON persistence, network work, `Task`, or `await`. No raw BLE `Data` or hex is in
the typed treadmill evidence or sidecar.

Issue #30 remains responsible for production recorder/session ownership,
persistence binding, canonical frame production, and lifecycle orchestration.
Issue #29 does not instantiate `TelemetryRecorder`, `TelemetryPersistence`, or a
Telemetry V2 session.
