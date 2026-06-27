#!/usr/bin/env python3
"""Analyze an exported WalkingPad training-log CSV for `runtime_gap` events.

A `runtime_gap` is written when the app's 1-second session loop was suspended
(e.g. the user switched apps mid-workout) and resumed late. This tool:

  * lists every `runtime_gap` (duration, whether it was a backgrounding);
  * checks, for each gap, that the treadmill was NOT stopped and that the
    commanded speed stayed continuous across the gap;
  * prints a QA verdict (PASS / FAIL / NO-GAP).

It is read-only and stdlib-only — no dependencies, safe to run on any export.

Definition of "near" a gap
--------------------------
A gap at time T with duration G covers the interval [T - G, T]; by construction
there are NO rows inside it (the timer did not fire). "Near" means the analysis
windows just outside that interval, `--near-seconds` wide (default 5s):

    pre-gap  = the last logged row at/just before (T - G)   -> state going in
    post-gap = the gap row itself + rows within T .. T+near -> state coming out

Session rows are ~1 Hz, so ±5s ≈ ±5 neighbouring rows. We compare the pre/post
belt state and scan the post window for any stop/abort signal.

Usage:
    python3 tools/analyze_training_log.py <export.csv> [--near-seconds 5] [--json]
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

# Events that mean the session/control terminated (a real stop) if they show up
# around a gap rather than at the planned end of the workout.
STOP_EVENTS = {"session_end", "hr_control_failed", "workout_not_saved", "command_queue_reset"}
MOVING_SPEED_KMH = 0.3  # below this, the belt is effectively stopped


def _to_float(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_bool(value) -> bool:
    return str(value).strip().lower() in {"true", "1", "yes"}


def _parse_ts(value: str) -> float | None:
    """Parse an ISO-8601 timestamp into epoch seconds (UTC), tolerant of formats."""
    text = (value or "").strip()
    if not text:
        return None
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        dt = None
        for fmt in (
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S",
        ):
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
    index: int
    ts_raw: str
    t: float | None
    session: str
    event: str
    raw: dict
    data: dict

    def get(self, key: str):
        value = self.data.get(key)
        if value is None or value == "":
            value = self.raw.get(key)
        return value

    def commanded_speed(self) -> float | None:
        device = self._num("speed_device_target_kmh")
        target = self._num("speed_target_kmh")
        if device is not None and device > 0.1:
            return device
        return target if target is not None else device

    def reported_speed(self) -> float | None:
        return self._num("speed_reported_kmh")

    def _num(self, key: str) -> float | None:
        return _to_float(self.get(key))


@dataclass
class UnitsObservation:
    unit_pref: str
    source: str
    checksum_ok: str
    command_units: str
    display_units: str
    physical_confidence: str
    raw_params_hex: str
    count: int = 0
    latest_ts: str = ""


@dataclass
class GapReport:
    session: str
    ts_raw: str
    gap_s: float
    was_backgrounded: bool
    background_s: float | None
    pre_commanded: float | None
    post_commanded: float | None
    pre_reported: float | None
    post_reported: float | None
    pre_state: str
    post_state: str
    stop_signals: list[str] = field(default_factory=list)

    @property
    def commanded_continuous(self) -> bool:
        if self.pre_commanded is None or self.post_commanded is None:
            return True  # cannot disprove continuity -> do not fail on missing data
        return abs(self.pre_commanded - self.post_commanded) <= 0.2

    @property
    def belt_impacted(self) -> bool:
        target_dropped = (
            self.pre_commanded is not None
            and self.pre_commanded > MOVING_SPEED_KMH
            and self.post_commanded is not None
            and self.post_commanded < MOVING_SPEED_KMH
        )
        return bool(self.stop_signals) or target_dropped

    @property
    def verdict(self) -> str:
        return "BELT-IMPACT" if self.belt_impacted else "OK"


def load_rows(path: str) -> list[Row]:
    rows: list[Row] = []
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for i, data in enumerate(reader):
            raw = {}
            raw_text = data.get("raw_json")
            if raw_text:
                try:
                    raw = json.loads(raw_text)
                except (json.JSONDecodeError, TypeError):
                    raw = {}
            rows.append(
                Row(
                    index=i,
                    ts_raw=(data.get("ts") or "").strip(),
                    t=_parse_ts(data.get("ts") or ""),
                    session=(data.get("session_id") or raw.get("session_id") or "").strip(),
                    event=(data.get("event") or raw.get("event") or "").strip(),
                    raw=raw,
                    data=data,
                )
            )
    rows.sort(key=lambda r: (r.session, r.t if r.t is not None else float("inf"), r.index))
    return rows


def analyze_gap(gap: Row, session_rows: list[Row], near_seconds: float) -> GapReport:
    gap_s = _to_float(gap.raw.get("gap_s")) or 0.0
    gap_start = (gap.t - gap_s) if gap.t is not None else None

    pre = None
    if gap_start is not None:
        for row in session_rows:
            if row is gap or row.t is None:
                continue
            if row.t <= gap_start + 0.5:
                pre = row
            elif row.t >= gap.t:
                break

    stop_signals: list[str] = []
    for row in session_rows:
        if row.t is None or gap.t is None:
            continue
        if gap.t <= row.t <= gap.t + near_seconds:
            if row.event in STOP_EVENTS:
                stop_signals.append(f"{row.event}@+{row.t - gap.t:.0f}s")
            if _to_bool(row.data.get("stop_confirmed")) or _to_bool(row.raw.get("stop_confirmed")):
                stop_signals.append(f"stop_confirmed@+{row.t - gap.t:.0f}s")

    return GapReport(
        session=gap.session,
        ts_raw=gap.ts_raw,
        gap_s=gap_s,
        was_backgrounded=_to_bool(gap.raw.get("was_backgrounded")),
        background_s=_to_float(gap.raw.get("background_s")),
        pre_commanded=pre.commanded_speed() if pre else None,
        post_commanded=gap.commanded_speed(),
        pre_reported=pre.reported_speed() if pre else None,
        post_reported=gap.reported_speed(),
        pre_state=(pre.data.get("session_state") if pre else "") or "",
        post_state=gap.data.get("session_state") or "",
        stop_signals=stop_signals,
    )


def build_reports(rows: list[Row], near_seconds: float) -> list[GapReport]:
    by_session: dict[str, list[Row]] = {}
    for row in rows:
        by_session.setdefault(row.session, []).append(row)
    reports: list[GapReport] = []
    for row in rows:
        if row.event == "runtime_gap":
            reports.append(analyze_gap(row, by_session.get(row.session, []), near_seconds))
    return reports


def collect_scene_events(rows: list[Row]) -> list[tuple[str, str, str]]:
    """(session, ts, phase) for every `scene_phase` event (foreground/background transitions)."""
    events = []
    for row in rows:
        if row.event == "scene_phase":
            phase = row.raw.get("phase") or row.data.get("phase") or "?"
            events.append((row.session, row.ts_raw, str(phase)))
    return events


def collect_units_observations(rows: list[Row]) -> list[UnitsObservation]:
    observations: dict[tuple[str, str, str, str, str, str, str], UnitsObservation] = {}
    for row in rows:
        unit_pref = str(row.get("speed_unit_pref") or "").strip()
        source = str(row.get("units_source") or "").strip()
        command_units = str(row.get("command_units") or "").strip()
        display_units = str(row.get("display_units") or "").strip()
        physical_confidence = str(row.get("physical_speed_confidence") or "").strip()
        raw_params_hex = str(row.get("controller_params_raw_hex") or "").strip()
        checksum_ok = str(row.get("controller_params_checksum_ok") or "").strip().lower()

        if not any((unit_pref, source, command_units, display_units, physical_confidence, raw_params_hex, checksum_ok)):
            continue

        key = (
            unit_pref or "?",
            source or "?",
            checksum_ok or "?",
            command_units or "?",
            display_units or "?",
            physical_confidence or "?",
            raw_params_hex or "?",
        )
        if key not in observations:
            observations[key] = UnitsObservation(
                unit_pref=key[0],
                source=key[1],
                checksum_ok=key[2],
                command_units=key[3],
                display_units=key[4],
                physical_confidence=key[5],
                raw_params_hex=key[6],
            )
        observations[key].count += 1
        observations[key].latest_ts = row.ts_raw or observations[key].latest_ts

    return sorted(observations.values(), key=lambda item: (-item.count, item.unit_pref, item.source))


def count_backgroundings(scene: list[tuple[str, str, str]]) -> int:
    return sum(1 for _, _, phase in scene if phase == "background")


def _fmt(value: float | None, suffix: str = "") -> str:
    return "—" if value is None else f"{value:.1f}{suffix}"


def print_text(
    path: str,
    rows: list[Row],
    reports: list[GapReport],
    scene: list,
    units: list[UnitsObservation],
    near_seconds: float,
) -> None:
    sessions = sorted({r.session for r in rows if r.session})
    backgroundings = count_backgroundings(scene)
    print("WalkingPad runtime_gap analyzer")
    print(f"File: {path}")
    print(f"Rows: {len(rows)} · Sessions: {len(sessions)} · near-window: ±{near_seconds:g}s")
    print()
    backgrounded = sum(1 for g in reports if g.was_backgrounded)
    total_gap = sum(g.gap_s for g in reports)
    max_gap = max((g.gap_s for g in reports), default=0.0)
    print(f"runtime_gap events: {len(reports)}")
    if reports:
        print(f"  total gap: {total_gap:.1f}s · max: {max_gap:.1f}s · backgrounded: {backgrounded}/{len(reports)}")
    print()

    print("units observations:")
    if units:
        for obs in units[:8]:
            raw = "" if obs.raw_params_hex in {"", "?"} else f" raw={obs.raw_params_hex}"
            print(
                "  "
                f"unit={obs.unit_pref} source={obs.source} checksum={obs.checksum_ok} "
                f"command={obs.command_units} display={obs.display_units} "
                f"physical={obs.physical_confidence} rows={obs.count} latest={obs.latest_ts or '—'}"
                f"{raw}"
            )
        if len(units) > 8:
            print(f"  … {len(units) - 8} more")
    else:
        print("  none (export predates units telemetry)")
    print()

    for n, g in enumerate(reports, 1):
        print(f"[gap {n}] session={g.session or '—'}  at {g.ts_raw or '—'}")
        bg = f"true (bg {_fmt(g.background_s, 's')})" if g.was_backgrounded else "false"
        print(f"  gap_s={g.gap_s:.1f}  was_backgrounded={bg}")
        cont = "continuous" if g.commanded_continuous else "CHANGED"
        print(f"  commanded speed: {_fmt(g.pre_commanded)} → {_fmt(g.post_commanded)} km/h   ({cont})")
        print(f"  reported speed:  {_fmt(g.pre_reported)} → {_fmt(g.post_reported)} km/h")
        print(f"  session_state:   {g.pre_state or '—'} → {g.post_state or '—'}")
        print(f"  stop signals in window: {', '.join(g.stop_signals) if g.stop_signals else 'none'}")
        print(f"  → {g.verdict}" + ("" if g.verdict == "OK" else "  (belt/control affected!)"))
        print()

    if scene:
        print(f"scene transitions: {len(scene)}  (backgroundings: {backgroundings})")
        for _, ts_raw, phase in scene[:12]:
            print(f"  {ts_raw}  {phase}")
        if len(scene) > 12:
            print(f"  … {len(scene) - 12} more")
        print()

    print(verdict_line(reports, backgroundings))


def verdict_line(reports: list[GapReport], backgroundings: int) -> str:
    if reports:
        impacted = [g for g in reports if g.belt_impacted]
        if impacted:
            return f"QA VERDICT: FAIL — {len(impacted)}/{len(reports)} gap(s) show belt/control impact."
        return f"QA VERDICT: PASS — {len(reports)} runtime_gap logged, belt unaffected."
    if backgroundings > 0:
        return (
            f"QA VERDICT: NO-STALL — app backgrounded {backgroundings}x but stayed alive "
            "(no runtime_gap). Good for reliability; the detector was not exercised."
        )
    return "QA VERDICT: NO-GAP — no runtime_gap and no backgrounding seen; re-run with an app switch."


def to_json(path: str, rows: list[Row], reports: list[GapReport], scene: list, units: list[UnitsObservation]) -> dict:
    impacted = [g for g in reports if g.belt_impacted]
    backgroundings = count_backgroundings(scene)
    if reports:
        status = "FAIL" if impacted else "PASS"
    elif backgroundings > 0:
        status = "NO-STALL"
    else:
        status = "NO-GAP"
    return {
        "file": path,
        "rows": len(rows),
        "runtime_gaps": len(reports),
        "scene_transitions": len(scene),
        "backgroundings": backgroundings,
        "units_observations": [
            {
                "speed_unit_pref": item.unit_pref,
                "units_source": item.source,
                "controller_params_checksum_ok": item.checksum_ok,
                "command_units": item.command_units,
                "display_units": item.display_units,
                "physical_speed_confidence": item.physical_confidence,
                "controller_params_raw_hex": item.raw_params_hex,
                "rows": item.count,
                "latest_ts": item.latest_ts,
            }
            for item in units
        ],
        "backgrounded": sum(1 for g in reports if g.was_backgrounded),
        "total_gap_s": round(sum(g.gap_s for g in reports), 1),
        "max_gap_s": round(max((g.gap_s for g in reports), default=0.0), 1),
        "verdict": status,
        "gaps": [
            {
                "session": g.session,
                "ts": g.ts_raw,
                "gap_s": g.gap_s,
                "was_backgrounded": g.was_backgrounded,
                "commanded_before": g.pre_commanded,
                "commanded_after": g.post_commanded,
                "stop_signals": g.stop_signals,
                "verdict": g.verdict,
            }
            for g in reports
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze runtime_gap events in a WalkingPad training-log CSV.")
    parser.add_argument("csv_path", help="Path to an exported Training_History_*.csv")
    parser.add_argument(
        "--near-seconds",
        type=float,
        default=5.0,
        help="Window (seconds) just outside the gap used to check belt impact (default: 5).",
    )
    parser.add_argument("--json", action="store_true", help="Emit a machine-readable JSON summary instead of text.")
    args = parser.parse_args()

    try:
        rows = load_rows(args.csv_path)
    except FileNotFoundError:
        print(f"error: file not found: {args.csv_path}", file=sys.stderr)
        return 2

    reports = build_reports(rows, args.near_seconds)
    scene = collect_scene_events(rows)
    units = collect_units_observations(rows)

    if args.json:
        print(json.dumps(to_json(args.csv_path, rows, reports, scene, units), indent=2))
    else:
        print_text(args.csv_path, rows, reports, scene, units, args.near_seconds)

    # Exit code: 0 = PASS / NO-STALL, 1 = FAIL (belt impact), 3 = NO-GAP. Handy for CI/automation.
    if reports:
        return 1 if any(g.belt_impacted for g in reports) else 0
    return 0 if count_backgroundings(scene) > 0 else 3


if __name__ == "__main__":
    raise SystemExit(main())
