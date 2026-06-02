# Project Status — WalkingPad Remote

*Source of truth for project management. Keep this short and current.*
*Last updated: 2026-06-02*

## Where development is
- **Branch:** `ios/hr-decision-engine-and-background`
- **Last code commit:** `d2ec861` (runtime_gap logging)
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
| runtime_gap logging | 🟡 QA — awaiting owner device test |
| C — recovery after kill | 📋 Planned (post-v1) |

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

## QA procedure — runtime_gap
**Goal:** confirm a backgrounded session is logged and the belt is unaffected.
1. HR source = iPhone HealthKit; start a 3-min session at a safe speed (stay nearby).
2. After ~30 s switch to another app (e.g. Telegram) for 20–30 s, then return.
3. Let it finish → Debug → **Export Training CSV** (last 3 sessions) → send to engineering.

**Report (filled from the log):** device / iOS · `runtime_gap` present? · example `gap_s` · effect on speed/stop (expected: none) · unexpected side effects.
**Definition of Done:** report confirms `runtime_gap` present **and** belt unaffected.

## QA devices
Real iPhone (iOS 26-class) + WalkingPad-class treadmill (KS-F0 referenced) + Apple Watch/AirPods for HR.
*Exact iPhone model / iOS version / treadmill model: TBD — confirm with owner.*
