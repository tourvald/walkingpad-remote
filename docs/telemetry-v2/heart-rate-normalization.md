# Telemetry V2 heart-rate normalization

Status: Issue #28 implementation note. The normative Telemetry V2 contracts in
this directory remain authoritative.

Issue #28 adds an observational, provider-neutral heart-rate seam without
binding it to the recorder, a Telemetry V2 session, or persistence. Issue #30
owns that application/session binding. The current HR Control provider remains
the existing Watch workout stream.

## Legacy path and observation point

The unchanged controller-facing path is:

```text
HKLiveWorkoutBuilder callback on Watch
  -> WatchConnectivity payload
  -> BluetoothManager.handleWatchPayload
  -> heartRateBPM / lastKnownHeartRateBPM / hrLastValueAt
  -> recordHrSample
  -> existing stale timer and HR decision timer
```

The Watch payload still contains the legacy `hr` value. It now also carries the
optional `hr_callback_observed_at` and `hr_sequence` fields. The phone accepts
old `hr`-only payloads, ignores unknown fields, and treats malformed optional
metadata as telemetry quality evidence rather than an HR rejection.

`BluetoothManager` first performs the legacy state and predictor updates in the
same order as before. Only then does the synchronous, non-throwing observational
tee normalize the delivery and call an optional sink. No task, actor hop,
persistence call, retry, or telemetry timer is added to this HR hot path. A
missing or rejecting sink therefore changes telemetry completeness only.

## Provider and time semantics

`HeartRateProviderObservation` represents a provider without selecting any new
provider. The production source is explicitly `legacyWatchWorkoutStream`; this
is a stable application-stream identity, not a claim about the physical sensor
that contributed HealthKit data.

The current `HKLiveWorkoutBuilderDelegate` callback exposes the collected sample
types and builder statistics, but not the delivered `HKObject`, its UUID, or an
original sample timestamp. Consequently:

- `measuredAt` is `nil` for the current path;
- `sourceCallbackObservedAt` is the Watch-side time at which the app observed
  the builder callback, not HealthKit measurement time;
- `receivedAt` is captured on iPhone before dispatching the payload to the main
  queue;
- `recordedAt` is the normalization observation time on iPhone;
- `providerNativeIdentity` is `nil` for the current path;
- Watch and iPhone wall clocks are explicitly independent, so their timestamps
  are not subtracted to claim delivery latency or clock regression;
- no identity is synthesized from BPM, time, sequence, arrival order, workout
  UUID, or contributor-source metadata.

These semantics follow the documented API shape of
[`HKLiveWorkoutBuilderDelegate`](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilderdelegate),
[`HKWorkoutBuilder.statistics(for:)`](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/statistics%28for%3A%29),
and [`HKObject.uuid`](https://developer.apple.com/documentation/healthkit/hkobject/uuid).
The API documentation does not promise callback scheduling latency or order, so
the implementation makes no such claim.

## Delivery, sequence, and quality

Every valid legacy HR payload receives a distinct `HeartRateDeliveryID` and a
monotonic phone-local `arrivalOrder` in the exact order in which normalization
observes deliveries. Neither field claims provider causality.

The Watch `hr_sequence` is a Watch-app-local callback delivery sequence reset
when the existing workout start path begins. It records app-observed callback
arrival only; it is not an HK sample ordinal, native identity, or guarantee
about HealthKit callback ordering. The phone preserves it verbatim as
`providerSequence` and never rewrites controller delivery order around it.

Quality flags describe missing/malformed metadata, repeated values, duplicate
or out-of-order sequence, and gaps. Delay or clock-regression flags are produced
only for a future provider that explicitly declares its source timestamp
comparable to the receiver clock; the current cross-device Watch path does not.
They never deduplicate, reorder, debounce, suppress, or gate a controller HR
delivery. Source available/unavailable, started/stopped, stale/recovered, and an
observable stop-then-start restart are derived from existing production state
transitions; there is no second lifecycle or staleness state machine. A first
active sample is not called recovered, and the legacy inactive tick after an
explicit stop does not create a false stale event.

## Canonical observations and causal references

Scientific and delivery identity are separate:

- a canonical scientific observation has one
  `HeartRateCanonicalObservationID`;
- every controller-facing arrival has its own `HeartRateDeliveryID`;
- control-use evidence references both IDs.

Canonicalization is permitted only for a real, non-blank provider-native sample
identity scoped by a non-blank stable source identity. A missing/blank stable
source key disables canonicalization and is flagged; it cannot collapse native
IDs from unrelated sources. An exact native redelivery creates a
new delivery record that points to the already persisted canonical observation;
it does not create a second scientific row or a dangling causal identifier.
When native identity is absent, apparently identical BPM/time/sequence inputs
remain distinct scientific observations. The existing persisted source stable
key, provider-native identity, and observation ID are sufficient for the future
#30 adapter to restore canonical bindings after reopening; #28 adds no schema.

Ingress records only that the legacy controller state accepted the delivery.
It does not claim the sample was used. Separate `HeartRateControlUseEvidence` is
emitted at the existing HR speed-decision branch after that branch has consumed
the current HR and, when available, the exact trend-window deliveries. The event
therefore records actual current-controller use rather than inferring use from
freshness, sequence, or quality.

## Safety invariant and remaining integration

Start HR Control remains governed only by the existing treadmill connection,
Watch reachability, current/fresh HR visibility, and controller-units policy.
Telemetry health, sink presence, recorder state, persistence availability,
metadata quality, sequence anomalies, and canonicalization never participate in
eligibility. Telemetry also does not start, stop, or change treadmill speed,
staleness, grace, cooldown, manual stop, or units behavior.

Issue #30 must supply a real Telemetry V2 session, bind the optional sink to the
recorder/persistence adapter, persist delivery and control-use evidence using
the established contracts, and restore canonical bindings from persisted
stable-native identities. It must preserve this failure-isolated observation
order and must not fabricate a session or provider identity.
