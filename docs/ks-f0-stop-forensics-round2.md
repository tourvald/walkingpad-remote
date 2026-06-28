# KS-F0 Stop Forensics Round 2

Last updated: 2026-06-28

## Context

Imperial HR-control speed smoke on the affected KS-F0-class WalkingPad confirmed
that the confirmed-imperial command projection works: physical km/h targets are
projected to native mph/raw tenths and the first-build cap holds at roughly
`3.7 mph` / `5.95 km/h`.

The same smoke reproduced the unresolved stop issue. App stop is still
best-effort on this treadmill and must be treated as unsafe without physical
manual-stop backup.

## Observed Signals

From `Training_History_last3_20260628_123800.csv`:

- `STOP` was written as `F7 A2 01 00 A3 FD`.
- `MODE STANDBY` was written as `F7 A2 02 02 A6 FD`.
- A later `STOP retry` was written.
- Stop verification remained false.
- Final reported state stayed running-like (`state=1`).
- Device-reported speed decreased but did not reach a fresh confirmed zero.
- `speed_raw_tenths` and `app_speed_raw_tenths` diverged during stop observation.

## Hypotheses

1. `STOP speed=0` is accepted by the controller but clamped to a minimum speed,
   not a full belt stop.
2. `app_speed_raw_tenths` and `speed_raw_tenths` represent different concepts
   such as controller target vs actual/current speed; current logs are not yet
   enough to choose one as the sole stop truth source.
3. `MODE STANDBY` while the belt is moving may not be a normal stop command for
   this controller, or it may be valid only in another state.
4. The official app or physical remote may use a different stop/pause command
   or a stateful sequence not yet captured in this app.
5. There may be a race between stop command writes, stale FE01 notifications,
   and the 30-second post-observation window.
6. This controller may keep `state=1` even near zero speed, so state alone is
   not sufficient for stop confirmation.

## Round 2 Logging Requirements

Stop forensics v2 must log a stop-attempt timeline without changing stop
behavior:

- stable `stop_attempt_id`
- `stop_attempt_started_at`
- stop command sequence number
- command label
- command packet hex
- command source
- write type
- queue size before/after enqueue
- FE01 snapshot before command
- scheduled FE01 snapshots at `0.5s`, `1.5s`, `3s`, `5s`, `8s`, `15s`, `30s`
- response age
- raw FE01 hex
- parsed state
- `speed_raw_tenths`
- `app_speed_raw_tenths`
- native units/speed and physical speed estimate
- manual/mode flag
- controller button field
- fresh/stale/missing marker

## Analyzer Requirements

`tools/analyze_training_log.py` should print a Stop Timeline Report:

| t | command | packet | FE01 before | FE01 after | state | speed_raw | app_speed_raw | confirmed |
|---|---|---|---|---|---|---|---|---|

Stop classification should distinguish:

- `STOP_CONFIRMED`
- `STOP_NOT_CONFIRMED`
- `STOP_STALE`
- `STOP_DECELERATED_BUT_NOT_ZERO`
- `STOP_STATE_STILL_RUNNING`
- `APP_TARGET_CHANGED_BUT_BELT_NOT_STOPPED`

## Current Product Rule

- Do not change the stop sequence without separate design approval.
- Do not add service-menu writes, firmware/OTA actions, or unit switching.
- Do not use HR-control on the affected treadmill without manual-stop readiness.
- Treat app STOP as best-effort until a fresh telemetry-confirmed stop path is
  proven on device.
