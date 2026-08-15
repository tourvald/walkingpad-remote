# Telemetry V2 safety boundary

Status: normative safety and future-adaptation separation contract.

Telemetry V2 observes and records the existing system. It does not own motion,
speed, stop, HR control, or safety authority.

## Immutable invariants

Throughout this Epic:

1. Control and safety MAY emit telemetry; telemetry MUST never authorize motion
   or block the control path.
2. No persistence, serialization, file synchronization, export, or analysis work
   may execute synchronously in a control or sensor callback.
3. Start, stale-HR, speed-bound, controller-unit, disconnect, cooldown,
   manual-stop, and stop-confirmation behavior MUST remain unchanged unless a
   later issue carries its own explicit PM-approved behavior contract.
4. Stop confirmation requires fresh factual device evidence. Desired/commanded
   speed, an ACK, a frame, an estimate, missing telemetry, or stale last-known
   state MUST NOT prove that the treadmill stopped.
5. Unknown or unconfirmed controller-unit semantics MUST NOT enable HR control
   or silent physical-unit conversion.
6. Missing, stale, ambiguous, dropped, estimated, or derived evidence MUST NOT be
   promoted to a safe factual state.
7. Debug, replay, preview, benchmark, simulator, and mock paths MUST NOT bypass
   production gates or reach production transport.
8. Telemetry, persistence, export, and analyzer failure MUST be fail-independent:
   they may degrade evidence health, never motion safety.
9. The Start HR Control affordance MUST remain available under the existing
   connected-treadmill plus current/fresh-visible-HR rule. Telemetry health,
   readiness, factual-speed availability, persistence, migration, analysis,
   history, export, or evidence completeness MUST NOT add an affordance gate.
   Existing non-telemetry runtime authorization checks after a tap remain
   fail-closed.

These are safety boundaries, not learnable parameters.

## One-way authority

```text
provider facts -> control/safety -> command service
       |              |                 |
       +--------------+-----------------+
                      v
                   telemetry
                      v
             persistence / analysis
```

There is no production arrow back from telemetry, persistence, frames, analysis,
history, export, or diagnostics to control in this Epic. A database record or
analyzer result MUST NOT satisfy a runtime safety predicate.

Telemetry emission MUST occur after or alongside the owning action without
becoming a precondition for it. Queue pressure, store locks, migration, export,
or analysis MUST NOT delay, reorder, retry, suppress, or synthesize a control
command.

## Evidence boundaries used by safety review

- Native HR observations preserve controller-facing arrival order. V2 MAY flag
  duplicates, out-of-order measurement times, stale values, and unknown source,
  but normalization MUST NOT reorder or filter what the current controller sees.
- A `usedForControl` fact records the actual existing decision. Analysis MUST
  NOT infer that fact from proximity or freshness after the event.
- Factual treadmill observations remain distinct from desired, commanded,
  controller-reported target, estimated, and derived speed.
- ACK means only the protocol outcome actually evidenced by the transport. It
  is not observed motion and not stop confirmation.
- A canonical frame is a query projection. It cannot upgrade the authority or
  freshness of the evidence it references.
- Missing frames across a gap remain missing. Backfill MUST NOT create apparent
  continuous device evidence.

## Safety policy versus future learnable parameters

Every session MUST snapshot the algorithm, safety-policy, workout-protocol, and
immutable configuration versions that produced its decisions. Safety policy
includes hard start/stop conditions, stale-signal limits, physical speed bounds,
unit confirmation, disconnect behavior, cooldown/manual-stop behavior, and stop
confirmation requirements.

Future research MAY calculate a recommendation from retained evidence only
outside this Epic. Any such recommendation:

- is derived data, not evidence;
- MUST be versioned and explain its evidence/quality inputs;
- MUST remain shadow/read-only until a separate behavior contract authorizes a
  bounded runtime consumer;
- MUST NOT learn, widen, disable, or bypass a safety invariant;
- MUST NOT be applied when required evidence is missing, stale, ambiguous, or
  low quality;
- MUST remain distinguishable from current user configuration and controller
  desire.

No interval engine or automatic adaptation is implemented in issues #23-#36.

## Provider and transport neutrality

The HR contract MUST support unknown, HealthKit-selected, Watch-mediated,
phone-local, and future provider identities without assuming Apple Watch is the
only physical source. Provider/source metadata is evidence; it does not change
the existing HR safety gates or controller acceptance order.

Replacing the current Watch transport with HealthKit workout mirroring is a
separate future change. This Epic MUST NOT couple the data model to that design
or use HealthKit metadata to authorize motion.

## Allowed and prohibited effects

| Telemetry operation | Allowed | Prohibited |
| --- | --- | --- |
| emit record | constant-time immutable value emission | waiting for disk/network or changing the owning decision |
| recorder overflow | bounded loss policy and explicit health/incomplete state | blocking control or presenting dropped evidence as complete |
| persistence failure | preserve committed data, report degraded evidence health | fallback that changes control or silently fabricates records |
| frame materialization | carry referenced last-known evidence with freshness | fabricate a native sample or backfill runtime gaps |
| analysis | deterministic timestamp-weighted post-workout result | sample-count-as-seconds or live command authority |
| replay | compare deterministic outputs in an isolated harness | connecting to production transport or weakening gates |
| export | privacy-conscious non-destructive projection | deleting source evidence or logging private payloads |

## Validation boundary

Hosted tests, replay, benchmarks, and unsigned builds are the automated validation
layer. They MUST report device-only facts as `UNVERIFIED_ON_DEVICE`, not infer
them.

Issue #37 is the mandatory real-evidence layer after V2 read cutover and before
legacy writer retirement. It uses ordinary user/PM-supplied workouts for
read-only analysis. Codex MUST NOT install/launch on a device, connect to a
treadmill, or send controller commands under that gate. Any special physical
experiment requires a separate fixed-whitelist, PM-approved hardware-experiment
contract.

A failure involving safety, factual provenance, causal correlation, unexplained
critical loss, or control divergence blocks legacy retirement. An unverified
item requires explicit PM disposition; simulation alone is not authority to
delete the comparison path.

Executable regression references include
`HeartRateLegacyBehaviorContractTests.testStartAffordanceIsSeparateFromRuntimeAuthorization`
and
`TreadmillTelemetryBoundaryTests.testStartAffordanceAndRuntimeAuthorizationDoNotReadTreadmillTelemetry`.
Treadmill unknown-association and no-heuristic-correlation coverage lives in
`TreadmillTruthTests`.
