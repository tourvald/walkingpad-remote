#!/usr/bin/env python3
"""Stop-sequence forensics for an exported WalkingPad training-log CSV.

For every Stop in the log this produces the fixed 10-point report agreed with
the owner and a single explicit verdict, to investigate the KS-F0 stuck-belt
incident from field logs.

A "Stop" = a `command_write` row whose `command_source == "stop"` (the user/
session stop that starts `stopBeltSafely`). The escalating `STOP retry` /
`MODE STANDBY` assist writes and the `stop_verification` rows that follow belong
to the SAME stop sequence, not new stops.

Report sections (per stop):
  1. stop sequence timeline
  2. every command_write in [stop-60s, stop+60s]
  3. was there a non-zero speed write AFTER Stop?
  4. who sent the commands (command_source)
  5. controller_state before / after
  6. controller_manual_mode before / after
  7. speed_reported_kmh before / after
  8. stop_confirmed / stop_confirmed_ever
  9. race-condition suspicion
 10. verdict

Verdicts:
  SAFE_STOP_CONFIRMED  - no post-stop non-zero speed/start write, and the stop
                         was confirmed (stop_confirmed_ever) with the controller
                         reporting not-moving and speed <= threshold.
  STOP_RACE_SUSPECTED  - a non-zero speed write (or start/resume) was sent AFTER
                         the Stop. This is the dangerous pattern.
  STOP_UNCONFIRMED     - no race, but the stop was never confirmed (controller
                         kept reporting moving / speed > threshold).
  STOP_NOT_VERIFIED    - belt was already at rest, no verification scheduled.

Read-only, stdlib-only. Usage:
    python3 tools/treadmill_analyzer/analyze_stop_sequences.py <export.csv> [--window 60] [--json]
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

STOP_SPEED_KMH = 0.3       # at/below this the belt is treated as stopped
MOVING_STATE = 1           # controller belt_state == 1 means "moving" (per app)
SPEED_SOURCES = {"user_manual", "hr_algorithm", "cooldown", "test_run"}
START_SOURCES = {"start"}


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _b(v) -> bool:
    return str(v).strip().lower() in {"true", "1", "yes"}


def _parse_ts(value: str):
    text = (value or "").strip()
    if not text:
        return None
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        dt = None
        for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z",
                    "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
            try:
                dt = datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
        if dt is None:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


@dataclass
class Row:
    i: int
    t: float | None
    ts_raw: str
    session: str
    event: str
    data: dict
    raw: dict

    def get(self, key):
        v = self.data.get(key)
        if v is None or v == "":
            v = self.raw.get(key)
        return v

    def num(self, key):
        return _f(self.get(key))

    @property
    def label(self) -> str:
        return (self.get("label") or "").strip()

    @property
    def source(self) -> str:
        return (self.get("command_source") or "").strip()

    def commanded_speed(self) -> float | None:
        for key in ("speed_device_target_kmh", "speed_target_kmh"):
            v = self.num(key)
            if v is not None:
                return v
        # last resort: parse a number out of the label ("SPEED 2.0 km/h (HR)")
        for part in self.label.replace("/", " ").split():
            v = _f(part)
            if v is not None:
                return v
        return None

    def is_speed_write(self) -> bool:
        return self.event == "command_write" and (
            self.source in SPEED_SOURCES or self.label.upper().startswith("SPEED")
        )


def load_rows(path: str) -> list[Row]:
    rows: list[Row] = []
    with open(path, newline="", encoding="utf-8") as fh:
        for i, data in enumerate(csv.DictReader(fh)):
            raw = {}
            rt = data.get("raw_json")
            if rt:
                try:
                    raw = json.loads(rt)
                except (json.JSONDecodeError, TypeError):
                    raw = {}
            rows.append(Row(
                i=i,
                t=_parse_ts(data.get("ts") or raw.get("ts") or ""),
                ts_raw=(data.get("ts") or raw.get("ts") or "").strip(),
                session=(data.get("session_id") or raw.get("session_id") or "").strip(),
                event=(data.get("event") or raw.get("event") or "").strip(),
                data=data,
                raw=raw,
            ))
    rows.sort(key=lambda r: (r.session, r.t if r.t is not None else float("inf"), r.i))
    return rows


@dataclass
class StopReport:
    session: str
    stop_ts: str
    stop_t: float
    timeline: list[dict] = field(default_factory=list)
    window_writes: list[dict] = field(default_factory=list)
    nonzero_speed_after: list[dict] = field(default_factory=list)
    start_after: list[dict] = field(default_factory=list)
    source_tally: dict = field(default_factory=dict)
    ctrl_state_before: float | None = None
    ctrl_state_after: float | None = None
    manual_before: float | None = None
    manual_after: float | None = None
    speed_before: float | None = None
    speed_after: float | None = None
    stop_confirmed: bool = False
    stop_confirmed_ever: bool = False
    had_verification: bool = False

    @property
    def race_suspected(self) -> bool:
        return bool(self.nonzero_speed_after or self.start_after)

    @property
    def controller_stopped_after(self) -> bool:
        return self.ctrl_state_after is not None and int(self.ctrl_state_after) != MOVING_STATE

    @property
    def reported_at_rest_after(self) -> bool:
        return self.speed_after is not None and self.speed_after <= STOP_SPEED_KMH

    @property
    def verdict(self) -> str:
        if self.race_suspected:
            return "STOP_RACE_SUSPECTED"
        if self.stop_confirmed_ever and self.controller_stopped_after and self.reported_at_rest_after:
            return "SAFE_STOP_CONFIRMED"
        if not self.had_verification and self.reported_at_rest_after:
            return "STOP_NOT_VERIFIED"
        return "STOP_UNCONFIRMED"


def build_stop_reports(rows: list[Row], window: float) -> list[StopReport]:
    by_session: dict[str, list[Row]] = {}
    for r in rows:
        by_session.setdefault(r.session, []).append(r)

    reports: list[StopReport] = []
    for r in rows:
        if r.event == "command_write" and r.source == "stop" and r.t is not None:
            reports.append(_analyze_stop(r, by_session.get(r.session, []), window))
    return reports


def _last_before(srows, stop_t, key, want_speed=False):
    val = None
    for r in srows:
        if r.t is None or r.t > stop_t:
            continue
        v = r.num(key)
        if v is not None:
            val = v
    return val


def _first_after(srows, stop_t, key, window):
    for r in srows:
        if r.t is None or r.t <= stop_t or r.t > stop_t + window:
            continue
        v = r.num(key)
        if v is not None:
            return v
    return None


def _last_after(srows, stop_t, key, window):
    val = None
    for r in srows:
        if r.t is None or r.t <= stop_t or r.t > stop_t + window:
            continue
        v = r.num(key)
        if v is not None:
            val = v
    return val


def _analyze_stop(stop: Row, srows: list[Row], window: float) -> StopReport:
    t0 = stop.t
    rep = StopReport(session=stop.session, stop_ts=stop.ts_raw, stop_t=t0)

    rep.ctrl_state_before = stop.num("controller_state")
    if rep.ctrl_state_before is None:
        rep.ctrl_state_before = _last_before(srows, t0, "controller_state")
    rep.manual_before = stop.num("controller_manual_mode")
    if rep.manual_before is None:
        rep.manual_before = _last_before(srows, t0, "controller_manual_mode")
    rep.speed_before = stop.num("speed_reported_kmh")
    if rep.speed_before is None:
        rep.speed_before = _last_before(srows, t0, "speed_reported_kmh")

    rep.ctrl_state_after = _last_after(srows, t0, "controller_state", window)
    rep.manual_after = _last_after(srows, t0, "controller_manual_mode", window)
    rep.speed_after = _last_after(srows, t0, "speed_reported_kmh", window)

    for r in srows:
        if r.t is None:
            continue
        dt = r.t - t0
        if not (-window <= dt <= window):
            continue

        if r.event == "command_write":
            cs = r.commanded_speed()
            entry = {
                "dt": round(dt, 1), "label": r.label, "source": r.source,
                "commanded_kmh": cs, "controller_state": r.num("controller_state"),
                "speed_reported_kmh": r.num("speed_reported_kmh"),
                "speed_unit_pref": (r.get("speed_unit_pref") or "").strip(),
                "command_units": (r.get("command_units") or "").strip(),
                "display_units": (r.get("display_units") or "").strip(),
                "physical_speed_confidence": (r.get("physical_speed_confidence") or "").strip(),
            }
            rep.window_writes.append(entry)
            rep.source_tally[r.source] = rep.source_tally.get(r.source, 0) + 1
            if dt > 0:  # strictly after Stop
                if r.is_speed_write() and cs is not None and cs > STOP_SPEED_KMH:
                    rep.nonzero_speed_after.append(entry)
                if r.source in START_SOURCES or "RESUME" in r.label.upper():
                    rep.start_after.append(entry)

        if dt >= 0 and r.event in ("command_write", "stop_verification", "session_end"):
            if r.event == "stop_verification":
                rep.had_verification = True
                if _b(r.get("stop_confirmed")):
                    rep.stop_confirmed = True
                if _b(r.get("stop_confirmed_ever")):
                    rep.stop_confirmed_ever = True
            rep.timeline.append({
                "dt": round(dt, 1),
                "event": r.event,
                "action": (r.get("action") or "").strip(),
                "label": r.label,
                "source": r.source,
                "stop_confirmed": _b(r.get("stop_confirmed")) if r.event == "stop_verification" else None,
                "stop_assist": (r.get("stop_assist_command") or "").strip(),
                "assist_sent": _b(r.get("stop_assist_sent")) if r.get("stop_assist_sent") is not None else None,
                "controller_state": r.num("controller_state"),
                "speed_reported_kmh": r.num("speed_reported_kmh"),
            })
    # stop_confirmed (final) = confirmed at the last verification
    if not rep.stop_confirmed_ever:
        rep.stop_confirmed_ever = rep.stop_confirmed
    return rep


def _fmt(v, suffix=""):
    if v is None:
        return "—"
    if isinstance(v, float) and v.is_integer():
        return f"{int(v)}{suffix}"
    return f"{v}{suffix}"


def print_text(path: str, reports: list[StopReport], window: float) -> None:
    print("WalkingPad stop-sequence forensics")
    print(f"File: {path}")
    print(f"Stops found: {len(reports)} · window: ±{window:g}s · stop threshold: {STOP_SPEED_KMH} km/h")
    print()
    for n, r in enumerate(reports, 1):
        print(f"================ STOP {n}/{len(reports)} · session={r.session or '—'} · at {r.stop_ts} ================")

        print("1) STOP SEQUENCE TIMELINE")
        for e in r.timeline:
            bits = [f"  +{e['dt']:>5.1f}s  {e['event']}"]
            if e["action"]:
                bits.append(f"[{e['action']}]")
            if e["label"]:
                bits.append(e["label"])
            if e["stop_confirmed"] is not None:
                bits.append(f"confirmed={e['stop_confirmed']}")
            if e["stop_assist"]:
                bits.append(f"assist={e['stop_assist']}(sent={e['assist_sent']})")
            bits.append(f"ctrl_state={_fmt(e['controller_state'])}")
            bits.append(f"reported={_fmt(e['speed_reported_kmh'])}")
            print(" ".join(bits))

        print("\n2) ALL command_write IN WINDOW [-{w:g}s .. +{w:g}s]".format(w=window))
        for e in r.window_writes:
            units = ""
            if e["speed_unit_pref"] or e["command_units"] or e["display_units"]:
                units = (
                    f"  units={e['speed_unit_pref'] or '?'}"
                    f"/cmd:{e['command_units'] or '?'}"
                    f"/ui:{e['display_units'] or '?'}"
                )
            print(f"  {e['dt']:>+6.1f}s  {e['source']:<14} {e['label']:<26} "
                  f"cmd={_fmt(e['commanded_kmh'],' km/h')}  ctrl_state={_fmt(e['controller_state'])}{units}")

        print("\n3) NON-ZERO SPEED WRITE AFTER STOP?")
        if r.nonzero_speed_after:
            print(f"  YES — {len(r.nonzero_speed_after)} write(s):")
            for e in r.nonzero_speed_after:
                print(f"    +{e['dt']:.1f}s  {e['source']}  {e['label']}  cmd={_fmt(e['commanded_kmh'],' km/h')}")
        else:
            print("  NO non-zero speed write after Stop.")
        if r.start_after:
            for e in r.start_after:
                print(f"  ALSO start/resume after Stop: +{e['dt']:.1f}s {e['source']} {e['label']}")

        print("\n4) WHO SENT COMMANDS (command_source)")
        if r.source_tally:
            print("  " + ", ".join(f"{k}={v}" for k, v in sorted(r.source_tally.items())))
        else:
            print("  (no command_write in window)")

        print("\n5) controller_state  before → after : "
              f"{_fmt(r.ctrl_state_before)} → {_fmt(r.ctrl_state_after)}"
              f"   ({'moving' if r.ctrl_state_after == MOVING_STATE else 'stopped'} after)")
        print(f"6) controller_manual_mode before → after : {_fmt(r.manual_before)} → {_fmt(r.manual_after)}")
        print(f"7) speed_reported_kmh before → after : {_fmt(r.speed_before,' km/h')} → {_fmt(r.speed_after,' km/h')}")
        print(f"8) stop_confirmed={r.stop_confirmed} · stop_confirmed_ever={r.stop_confirmed_ever}")

        print("9) RACE CONDITION SUSPICION")
        if r.race_suspected:
            why = []
            if r.nonzero_speed_after:
                why.append(f"{len(r.nonzero_speed_after)} non-zero speed write(s) after Stop "
                           f"(source: {', '.join(sorted({e['source'] for e in r.nonzero_speed_after}))})")
            if r.start_after:
                why.append("start/resume after Stop")
            print(f"  SUSPECTED — {'; '.join(why)}.")
        else:
            print("  none — no commands re-accelerated the belt after Stop.")

        print(f"\n10) VERDICT: {r.verdict}\n")

    print(overall_line(reports))


def overall_line(reports: list[StopReport]) -> str:
    if not reports:
        return "OVERALL: NO-STOP — no command_source=stop write found in this log."
    verdicts = [r.verdict for r in reports]
    if "STOP_RACE_SUSPECTED" in verdicts:
        return f"OVERALL: STOP_RACE_SUSPECTED ({verdicts.count('STOP_RACE_SUSPECTED')}/{len(verdicts)} stop(s))."
    if "STOP_UNCONFIRMED" in verdicts:
        return f"OVERALL: STOP_UNCONFIRMED ({verdicts.count('STOP_UNCONFIRMED')}/{len(verdicts)} stop(s))."
    if all(v == "SAFE_STOP_CONFIRMED" for v in verdicts):
        return f"OVERALL: SAFE_STOP_CONFIRMED (all {len(verdicts)} stop(s))."
    return "OVERALL: " + ", ".join(verdicts)


def to_json(path: str, reports: list[StopReport]) -> dict:
    return {
        "file": path,
        "stops": len(reports),
        "verdicts": [r.verdict for r in reports],
        "details": [
            {
                "session": r.session, "stop_ts": r.stop_ts, "verdict": r.verdict,
                "nonzero_speed_after_stop": r.nonzero_speed_after,
                "start_after_stop": r.start_after,
                "source_tally": r.source_tally,
                "controller_state_before": r.ctrl_state_before,
                "controller_state_after": r.ctrl_state_after,
                "controller_manual_mode_before": r.manual_before,
                "controller_manual_mode_after": r.manual_after,
                "speed_reported_before": r.speed_before,
                "speed_reported_after": r.speed_after,
                "stop_confirmed": r.stop_confirmed,
                "stop_confirmed_ever": r.stop_confirmed_ever,
                "race_suspected": r.race_suspected,
            }
            for r in reports
        ],
    }


def main() -> int:
    p = argparse.ArgumentParser(description="Stop-sequence forensics for a WalkingPad training-log CSV.")
    p.add_argument("csv_path", help="Path to an exported Training_History_*.csv")
    p.add_argument("--window", type=float, default=60.0, help="Seconds before/after Stop to inspect (default 60).")
    p.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    args = p.parse_args()

    try:
        rows = load_rows(args.csv_path)
    except FileNotFoundError:
        print(f"error: file not found: {args.csv_path}", file=sys.stderr)
        return 2

    reports = build_stop_reports(rows, args.window)
    if args.json:
        print(json.dumps(to_json(args.csv_path, reports), indent=2))
    else:
        print_text(args.csv_path, reports, args.window)

    # Exit code: 0 safe/no-stop, 1 race suspected, 3 unconfirmed.
    verdicts = [r.verdict for r in reports]
    if "STOP_RACE_SUSPECTED" in verdicts:
        return 1
    if "STOP_UNCONFIRMED" in verdicts:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
