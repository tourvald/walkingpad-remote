# Project Status — WalkingPad Remote

*Source of truth for project management. Keep this short and current.*
*Last updated: 2026-06-11*

## Where development is
- **Branch:** `ios/hr-decision-engine-and-background`
- **Last code commit:** `1bb0f09` (read-only controller params query in Debug menu; on device)
- **Push status:** local only — not pushed to remote
- **Repo:** `github.com/tourvald/walkingpad-remote` (canonical)

## Incident: KS-F0 stuck-belt (P0, active)
Owner's KS-F0 treadmills won't fully stop — belt creeps at 0.2–0.3 km/h, KSFIT hangs
on "Device Stopping", the native remote can't stop them either, persists across
multi-day power-off. Investigating whether our BLE could have changed persistent
controller state.

**BLE write audit (done):** the app emits only **runtime** commands. The single
WalkingPad packet builder hardcodes type `0xA2` (runtime) and is structurally
incapable of `0xA6` (`set_pref_*` / NVRAM). Surface: stop / set-speed / mode-manual /
mode-standby / start (WalkingPad) + standard FTMS/FitShow runtime opcodes. No
calibration, no prefs, nothing written on connect (bar a FitShow status query).
→ The app **cannot** have written a persistent setting via the documented protocol.

**Field reproduction (2026-06-11, diagnostic builds):**
- Log 1 (baseline stop = STOP + STANDBY): belt wedged at **0.3 km/h, state=1**; no race;
  `stop_confirmed_ever=false`.
- Log 2 (STOP-only build `d419b2a`, no STANDBY): belt wedged at **0.8 km/h, state=1**;
  `stop_confirmed_ever=false`.
- → **`CONTROLLER_STUCK_ON_STOP_ONLY`**: even pure repeated speed-0 does not bring the
  belt to 0. STANDBY-while-moving hypothesis **refuted** (STANDBY actually lowered the
  residual 0.8→0.3). Race hypothesis **refuted** (app never re-accelerates after Stop).
  Root cause is **controller-side**: KS-F0 won't honor BLE speed-0 to fully stop from a
  moving state.

**Units / miles thread (separate, open):**
- A persistent units pref **exists**: WalkingPad `0xA6`, key 8 (`set_pref_units_miles`).
- **Our app never sends it** (cannot emit `0xA6`).
- Units **may** explain a speed **display** mismatch (km/h vs mph).
- Units does **not** explain `Device Stopping` / `state=1` / `speed 0.2–0.3` (controller
  state; wire values are self-consistent km/h).
- **Open:** corrupted / externally-changed persistent controller state stays a live
  hypothesis (a units flip signals something persistent changed — but not via our app).
  Owner to check physically: belt-screen units, KSFIT toggle, rough scale test.
- **Rule:** no `set_pref_units` / `0xA6` / persistent-write until the protocol is fully understood.

**P0 fix path:** controller-side → manufacturer factory / service / calibration reset
(KingSmith). No app-side change stops a controller that won't honor speed-0. Diagnostic
logging shipped: `controller_state` / `controller_manual_mode` / `command_source`
(`03db316`); stop-forensics analyzer (`06ae3fe`).

**External research (2026-06-11):** independent RE sources (ph4-walkingpad, QWalkingPad
Protocol.cpp, CodeJawn, huserben) confirm our runtime bytes; no BLE factory-reset exists;
no public report of this symptom. Two follow-ups recorded:
- **Toggle-stop fallback (deferred, owner decision):** `F7 A2 04 01` is a start/stop
  *toggle* (QWalkingPad uses it as its Stop; "start_belt is actually toggle_belt").
  Not adopted now — the native remote is also a toggle and fails on affected pads.
  Side effect: explains why START must never be re-sent mid-run (our guards already prevent it).
- **Read-only params query shipped (`1bb0f09`):** Debug → "Read Controller Params" sends
  documented query `F7 A6 00 00 00 00 00 A6 FD` (write-free), parses unit / regulate /
  maxSpeed / startSpeed / sensitivity / display / lock; UI + `controller_params` log event.
  Plan: read params on healthy vs stuck pad and diff (incl. `unit` for the miles thread).
  All `set_pref_*` / 0xA6 **writes** remain forbidden until a separate owner decision.

**Research v2 + first params read (2026-06-11 evening):**
- queryParams from the test pad: **`unit=1` (imperial!)**, `maxSpeed=7.5` (explains our 8.0→7.5
  clamp), `startSpeed=0.5` (≈ creep floor 0.3–0.8), cali=0, lock=0 → controller **NVRAM was
  modified outside our app**; units/mph thread is open and important (wire scale still looks
  km/h: QZ sends km/h×10 with no unit conversion; physical measurement pending).
- QZ (qdomyos-zwift) explicitly supports KS-F0 → `kingsmithr1protreadmill`; **QZ's stop is the
  `F7 A2 04 01` toggle** (no speed-0, no standby) → on F0, speed-0 may be floor-not-stop.
- Toggle will likely NOT rescue an already-wedged controller (KSFIT over BLE already fails on
  those pads) — it's a full-matrix item + future stop-path candidate, not a proven fix.
- **Full incident record: `docs/ks-f0-incident.md`** (protocol map, params table, safety rules,
  open actions).

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

**After both CSVs:** run `tools/treadmill_analyzer/analyze_training_log.py` and fill the QA report.

**Acceptance gate:** until QA passes, **runtime_gap and the post-observation
changes (commits `5d22296` / `4eb6293` / `a87fb6a`) stay QA pending.**

**Push / merge:** do **not** push or merge without final owner confirmation.

## QA devices
Real iPhone (iOS 26-class) + WalkingPad-class treadmill (KS-F0 referenced) + Apple Watch/AirPods for HR.
*Exact iPhone model / iOS version / treadmill model: TBD — confirm with owner.*
