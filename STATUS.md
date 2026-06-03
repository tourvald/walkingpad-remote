# Project Status — WalkingPad Remote

*Source of truth for project management. Keep this short and current.*
*Last updated: 2026-06-03*

## Where development is
- **Branch:** `ios/hr-decision-engine-and-background`
- **Last code commit:** `a87fb6a` (Test Run diagnostics unification)
- **Push status:** local only — not pushed to remote
- **Repo:** `github.com/tourvald/walkingpad-remote` (canonical)

## Roadmap
**v1 — in scope**
- Treadmill control (WalkingPad / FTMS / FitShow) + safe stop
- HR-driven speed control + adaptive cooldown
- HR source: Apple Watch or iPhone HealthKit (AirPods, etc.)
- Telemetry + CSV export, Stats, Plank, local profiles
- Screen stays on during a session
- Background reliability for iPhone-HealthKit + locked screen (field-validated)

**Post-v1 — deferred**
- C: recovery after a full app kill / crash
- Full background support for Apple Watch HR mode
- Wider FTMS / FitShow device validation
- Data-driven cooldown tuning; replay-test harness

**Non-goals**
- Cloud accounts · multi-user backend · smart-home integrations

## Feature status
| Feature | Status |
|---|---|
| Treadmill control + safe stop | ✅ Done |
| HR control + adaptive step / cooldown | ✅ Done |
| HR sources (Watch / iPhone HealthKit) | ✅ Done |
| Telemetry + export · Stats · Plank · profiles | ✅ Done |
| Screen-on during session | ✅ Done (device-confirmed) |
| Decision-engine refactor (tested core logic) | ✅ Done |
| `bluetooth-central` background mode | ✅ Done (field-confirmed) |
| `stop_confirmed_ever` logging | ✅ Done (field-confirmed) |
| runtime_gap logging | 🟡 QA pending |
| scene_phase telemetry | 🟡 QA pending |
| post-observation background-task (safety) | 🟡 QA pending |
| post-observation telemetry (events / outcome) | 🟡 QA pending |
| Test Run diagnostics unification (session_kind) | 🟡 QA pending |
| C — recovery after kill | 📋 Planned (post-v1 — do not start) |

## Safety decisions (fixed)
- Background HR runtime is anchored on the **iPhone HealthKit** workout session.
- v1 background = **safety-first** (guarantee cooldown + stop).
- **runtime_gap logs only — it never stops the belt.**
- Stop = speed 0 + standby, with confirmation of the actual stop.
- Recovery after kill (C): reconnect + **safe stop** + log (resume is a later refinement).
- Local-first: no cloud, no accounts.

## Top risks
- iOS 26 SDK → hosted CI can't always run a full build.
- After a full app kill the BLE link isn't restored yet (→ addressed by C).
- Apple Watch HR mode in background is unreliable (only iPhone HealthKit is validated).
- Loss-of-HR-while-locked path is not yet device-tested.

## Tech debt
- `BluetoothManager` is large; decomposition is ongoing (core logic now lives in tested engines).
- No direct unit tests on the orchestrator (the pure engines are covered).
- Accumulated work landed as one snapshot commit — coarse history.

## What blocks v1
No hard blockers. What remains is **validation, not development**:
1. runtime_gap device QA (in progress)
2. one clean uninterrupted locked run + one long session (30+ min)
3. loss-of-HR-while-locked → safe-stop test

> **C (recovery after kill) is NOT a v1 blocker** — deferred to post-v1.

## Pending QA — blocks acceptance of the items above
Two device runs needed. Log analysis is **paused** until both CSVs arrive.

**QA-1 — Debug Test Run + lock** (this is what actually exercises the gap detector —
a test run has no workout session, so it really suspends when locked):
1. Debug → Start Test Run (3 min); after ~30–40 s lock the iPhone ~30 s; unlock.
2. Let it finish → Export Training CSV (last session).
3. Check: `session_kind=test_run` · `scene_phase` present · **`runtime_gap` present** ·
   `post_observation_*` timing sane (~30 s, not minutes) · `stop_confirmed_ever`.

**QA-2 — Real HR workout + lock** (expected to stay alive → NO-STALL):
1. HR-контроль · iPhone HealthKit · start (3 min, safe speed, stay nearby);
   after ~30–40 s lock ~30 s; unlock; let it finish.
2. Export Training CSV (last session).
3. Check: `session_kind=hr_control` · `scene_phase` present · **NO-STALL or PASS** ·
   no effect on speed / commands / stop.

**After both CSVs:** run `tools/analyze_training_log.py` and fill the QA report.

**Acceptance gate:** until QA passes, **runtime_gap and the post-observation
changes (commits `5d22296` / `4eb6293` / `a87fb6a`) stay QA pending.**

**Push / merge:** do **not** push or merge without final owner confirmation.

## QA devices
Real iPhone (iOS 26-class) + WalkingPad-class treadmill (KS-F0 referenced) + Apple Watch/AirPods for HR.
*Exact iPhone model / iOS version / treadmill model: TBD — confirm with owner.*
