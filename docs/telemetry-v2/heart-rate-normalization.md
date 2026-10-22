# Telemetry V2 heart-rate normalization

## Current production path

```text
Native iPhone HKWorkoutSession / HKLiveWorkoutBuilder
  -> IPhoneHealthKitLiveHeartRateProvider
  -> BluetoothManager.handleNativeHeartRateObservation
  -> native attempt/generation and measurement-freshness gates
  -> controller state, normalization and control-use evidence
```

The custom watchOS app and WatchConnectivity transport have been removed.
The provider requests HealthKit heart-rate collection without a device filter;
its application-stream identity is `healthKitSelected` with stable key
`iphone-healthkit-selected`. This does not identify the physical sensor.
HealthKit can supply compatible external sensors and supported headphones.
Apple documents Watch workout mirroring as originating in a watchOS app, so
Watch-only continuous live delivery is not guaranteed by this iPhone-only app.
See [Track workouts with HealthKit](https://developer.apple.com/videos/play/wwdc2025/322/)
and [AirPods heart-rate support](https://support.apple.com/123184).

The live provider keeps measurement interval timestamps separate from callback
and receipt times. Delayed or repeated measurements cannot refresh the controller
merely because a callback arrives. No latest-historical-sample fallback exists.
Native lifecycle generation/attempt checks reject obsolete callbacks. Start,
increase, stale-signal, controller-unit and factual Stop gates remain authoritative.

## Delivery and persisted compatibility

The normalizer preserves delivery order and records quality and causal references.
A canonical scientific observation and a controller-facing delivery have distinct
identities. Canonicalization requires a real provider-native identity scoped by a
stable source identity; similar BPM/timestamps are not a synthetic identity.
Control-use evidence is emitted where the controller consumes the measurement.
Neither telemetry normalization nor cached analysis authorizes treadmill motion.

Persisted source kinds including `legacyWatchWorkoutStream` and
`mirroredWatchWorkout` remain readable for existing history and exports. These
values do not enable a live transport. Historical cross-device timestamps retain
their independent-clock semantics; missing measurement time remains unknown.
The retired Watch payload decoder, callback sequence transport and observational
tee are no longer part of the application.

## Passive prediction snapshots

The HR speed-decision event optionally carries `heartRatePrediction`. It copies
values already calculated by the existing controller: input BPM, controller
input timestamp/age, trend, actual trend window, EMA alpha, slope limit, forecast
horizon, rounded prediction, effective BPM, evaluation time, and workout phase.
The current producer emits it only for main-stage decisions after the existing
HR/device gates, including hold, inertia hold, speed change, and speed limit.
A missing trend/prediction remains absent; it is never exported as zero.

This is observational evidence under the existing algorithm/version, not a new
predictor. Settings, control branches, commands, safety gates and timing cadence
are unchanged. No extra timer, live comparison, adaptation, migration, or new
SwiftData model is introduced. The optional event-payload field is absent from
historical decisions; those records continue to decode. Old readers may ignore
the additive field. Raw JSONL retains the typed snapshot; analysis CSV appends
`prediction_*` columns, blank for historical/unrelated rows.

`controllerInputAt` is the timestamp actually held by control, not a claim that
the provider supplied a measurement timestamp. Use the decision's existing
observation references to retrieve original measured/received timestamps,
source, freshness and quality. Missing measurement time stays unknown. The
snapshot's evaluation time is separate from event emission time and is encoded
as numeric Unix seconds to retain subsecond precision in portable JSONL. The event
retains its existing wall/elapsed envelope. Correlate evaluation with that
session clock before comparing at evaluation plus `horizonSeconds`.

Future accuracy analysis must explicitly choose a bounded measurement-matching
policy, exclude missing/incompatible evidence, and report coverage. Predictions
remain estimates, not factual HR. Existing factual treadmill observations and
command lifecycle records supply speed context without inventing a causal
command-response edge. The existing controller may change speed during the
forecast horizon, so forecast accuracy alone does not prove control benefit.
