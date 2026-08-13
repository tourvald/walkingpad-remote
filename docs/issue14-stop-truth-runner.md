# Issue #14 fixed Stop-truth runner

This tooling prepares the fixed Issue #11 experiment runner. It does not
authorize or perform hardware validation.

## Ordinary-build boundary

Ordinary builds do not define `STOP_TRUTH_EXPERIMENT_CAPABILITY`. The experiment
UI and `BluetoothManager` transport adapter are therefore absent, while the
runtime build identity also evaluates disabled. No production manual, HR,
session, Stop, start, speed, queue, or notification path routes through the
experiment executor.

The experiment command API is typed. It has no raw hex, command, value, sequence,
or generic write input. Exact packets are owned by `BLETransportCodec` and the
fixed sequence is enforced before transport invocation.

## Exact future build binding

After this change is merged and a later Issue #11 PM contract names an exact
approved SHA, build an unsigned experiment-capable artifact only from a clean
checkout of that exact commit:

```bash
scripts/build_stop_truth_experiment.sh \
  --expected-sha <exact-approved-40-character-git-sha> \
  --derived-data /tmp/walkingpad-stop-truth-derived-data
```

The helper fails closed when:

- the expected SHA is missing or malformed;
- `git rev-parse HEAD` differs from the expected SHA;
- the checkout is dirty.

It injects both expected and actual SHA into an explicit executable-name binding
(`-issue14-stop-truth-v1-e<expected>-a<actual>`) and enables the compile-time
capability. Runtime parses the built bundle's `CFBundleExecutable` and requires
the fixed binding plus identical valid exact SHA values. A normal/default build
has no such suffix and remains disabled.

The helper builds the generic iOS scheme, which has an explicit Watch App target
dependency, then fails unless both the unsigned iOS executable and its embedded
unsigned watchOS executable exist with the exact SHA-bound suffix.

Building does not authorize installation, launch, BLE connection, treadmill
commands, or a physical experiment. Those require the separate Issue #11 exact
SHA PM approval.

## Safety behavior

- The fixed matrix is one core case, three repetitions, one uninterrupted
  context, and zero reconnects.
- Raw 5 is allowed only after checksum-valid same-context A6 bounds contain 5.
- Stationary and moving gates require the latest two consecutive checksum-valid
  same-context FE01 frames with monotonic age `0...2.0s`.
- The initial Stop is high priority. Recovery toggle and conditional retry use
  the production `+2.0s` / `+4.0s` timing and `max(speedKmh,
  deviceReportedSpeedKmh) > 0.2` predicate.
- All experiment invocations and abort transitions share one lock. Delayed
  actions are token-bound and cancellable. ABORT invalidates the token and never
  sends a software recovery command.
- Leaving the active app lifecycle aborts the run fail-closed so a background or
  suspension interval cannot be treated as continuous critical-timing evidence.
- After an abort following any motion-capable actual write, recovery is physical
  power cutoff by the operator.
- MOVING, STOPPED, and ABORT controls write evidence only; marker actions never
  send BLE commands.

## Private evidence

The dedicated writer uses:

`Application Support/TrainingLogs/issue11_stop_truth_<experiment_id>.jsonl`

It records exact build binding, typed commands and transport receipts, unified
`DispatchTime.now().uptimeNanoseconds` timestamps, raw FE01 bytes, stop truth,
physical markers, command sequencing, and abort-barrier ordering. Existing
`notify_fe01` event fields and training-log meanings are unchanged.

The runner records the 30-second final state and the dedicated `deadline + 2.1s`
freshness state as separate events. It reports core evidence and leaves natural
contradictory trajectory subclaims `UNKNOWN / NOT OBSERVED`; it never claims a
hardware PASS by itself.
