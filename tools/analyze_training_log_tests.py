#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path

from analyze_training_log import (
    Row,
    collect_diagnostic_observations,
    collect_imperial_training_projection_observations,
    collect_stop_experiment_reports,
    collect_stop_timeline_reports,
    load_rows,
)


class DiagnosticObservationTests(unittest.TestCase):
    def test_device_distance_alone_does_not_produce_physical_verdict(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T00:00:00Z",
                t=0.0,
                session="s1",
                event="treadmill_test_started",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "distance_km": "0.000",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T00:01:00Z",
                t=60.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "distance_km": "0.081",
                    "distance_raw": "30",
                    "distance_raw_units_unknown": "true",
                    "distance_unit_pref": "imperial",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=2,
                ts_raw="2026-06-28T00:01:30Z",
                t=90.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "0",
                    "command_native_units": "imperial",
                    "command_native_speed": "0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
        ]

        observations = collect_diagnostic_observations(rows)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0].command_raw_tenths, "30")
        self.assertEqual(observations[0].command_native_speed, "3.0")
        self.assertEqual(observations[0].verdict, "inconclusive_without_external_measurement")
        self.assertEqual(observations[0].device_distance_raw_delta, 30.0)
        self.assertIsNone(observations[0].external_distance_m)

    def test_external_distance_can_produce_physical_verdict(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T00:00:00Z",
                t=0.0,
                session="s1",
                event="treadmill_test_started",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "30",
                    "command_native_units": "imperial",
                    "command_native_speed": "3.0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T00:01:00Z",
                t=60.0,
                session="s1",
                event="treadmill_test_finished",
                raw={},
                data={
                    "diagnostic_profile": "imperial_units_discriminator_60s",
                    "command_raw_tenths": "0",
                    "command_native_units": "imperial",
                    "command_native_speed": "0",
                    "external_distance_m": "81.0",
                    "physical_discriminator_expected_kmh_distance_m": "50.0",
                    "physical_discriminator_expected_mph_distance_m": "80.5",
                },
            ),
        ]

        observations = collect_diagnostic_observations(rows)

        self.assertEqual(observations[0].verdict, "physical_likely_mph")
        self.assertEqual(observations[0].external_distance_m, 81.0)


class ImperialProjectionObservationTests(unittest.TestCase):
    def test_normalized_cap_noop_fields_take_precedence_over_raw_json(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-07-05T18:53:53Z",
                t=0.0,
                session="session-cap",
                event="speed_command_projection",
                raw={
                    "projection_noop": False,
                    "projection_will_send": True,
                    "capped_noop": False,
                    "capped_physical_speed_kmh": 5.8,
                },
                data={
                    "label": "SPEED 6.0 km/h (HR)",
                    "command_native_units": "imperial",
                    "command_native_speed_mph": "3.7",
                    "command_raw_tenths": "37",
                    "requested_physical_speed_kmh": "6.0",
                    "capped_physical_speed_kmh": "6.0",
                    "physical_speed_kmh_estimate": "5.9545728",
                    "projection_noop": "true",
                    "projection_will_send": "false",
                    "speed_cap_source": "device_max",
                    "capped_noop": "true",
                    "speed_display_value": "3.6",
                    "speed_display_units": "mph",
                    "speed_display_semantics": "native_mph",
                    "speed_physical_kmh_estimate": "5.7936384",
                    "speed_physical_estimate_label": "physical km/h estimate",
                    "manual_stop_acknowledged": "true",
                },
            )
        ]

        observations = collect_imperial_training_projection_observations(rows)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0].command_raw_tenths, "37")
        self.assertFalse(observations[0].projection_will_send)
        self.assertTrue(observations[0].projection_noop)
        self.assertEqual(observations[0].speed_cap_source, "device_max")
        self.assertTrue(observations[0].capped_noop)
        self.assertFalse(observations[0].legacy_artificial_cap_noop)
        self.assertEqual(observations[0].capped_physical_speed_kmh, 6.0)
        self.assertEqual(observations[0].display_speed_value, 3.6)
        self.assertEqual(observations[0].display_speed_units, "mph")
        self.assertEqual(observations[0].display_speed_semantics, "native_mph")
        self.assertEqual(observations[0].speed_physical_kmh_estimate, 5.7936384)
        self.assertEqual(observations[0].speed_physical_estimate_label, "physical km/h estimate")

    def test_old_exports_classify_artificial_cap_without_current_capped_noop(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-07-05T18:53:53Z",
                t=0.0,
                session="session-cap",
                event="speed_command_projection",
                raw={
                    "label": "SPEED 6.0 km/h (HR)",
                    "command_native_units": "imperial",
                    "command_native_speed_mph": 3.7,
                    "command_raw_tenths": 37,
                    "requested_physical_speed_kmh": 6.0,
                    "capped_physical_speed_kmh": 6.0,
                    "native_speed_mph": 3.6,
                    "physical_speed_kmh_estimate": 5.7936384,
                    "projection_noop": True,
                    "projection_will_send": False,
                    "manual_stop_acknowledged": True,
                },
                data={
                    "event": "speed_command_projection",
                    "projection_noop": "",
                    "projection_will_send": "",
                    "capped_noop": "",
                },
            )
        ]

        observations = collect_imperial_training_projection_observations(rows)

        self.assertEqual(len(observations), 1)
        self.assertFalse(observations[0].projection_will_send)
        self.assertTrue(observations[0].projection_noop)
        self.assertEqual(observations[0].speed_cap_source, "legacy_artificial")
        self.assertFalse(observations[0].capped_noop)
        self.assertTrue(observations[0].legacy_artificial_cap_noop)
        self.assertEqual(observations[0].display_speed_value, 3.6)
        self.assertEqual(observations[0].display_speed_units, "mph")
        self.assertEqual(observations[0].display_speed_semantics, "native_mph")
        self.assertEqual(observations[0].speed_physical_kmh_estimate, 5.7936384)
        self.assertEqual(observations[0].speed_physical_estimate_label, "physical km/h estimate")


class StopExperimentReportTests(unittest.TestCase):
    def test_collect_stop_experiment_report_from_cli_csv_rows(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T10:00:00Z",
                t=0.0,
                session="",
                event="notify_fe01",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-1",
                    "variant": "speed-zero-only",
                    "command_packet_hex": "F7 A2 01 00 A3 FD",
                    "writes_count": "0",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "30",
                    "baseline_speed_raw_tenths": "30",
                    "confirmed_stop": "false",
                    "outcome": "",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T10:01:00Z",
                t=60.0,
                session="",
                event="summary",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-1",
                    "variant": "speed-zero-only",
                    "command_packet_hex": "F7 A2 01 00 A3 FD",
                    "writes_count": "1",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "8",
                    "baseline_speed_raw_tenths": "30",
                    "confirmed_stop": "false",
                    "outcome": "DECELERATED_BUT_NOT_ZERO",
                },
            ),
        ]

        reports = collect_stop_experiment_reports(rows)

        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0].experiment_id, "exp-1")
        self.assertEqual(reports[0].variant, "speed-zero-only")
        self.assertEqual(reports[0].command_packet_hex, "F7 A2 01 00 A3 FD")
        self.assertEqual(reports[0].writes_count, 1)
        self.assertEqual(reports[0].blocked_writes_count, 0)
        self.assertEqual(reports[0].baseline_speed_raw_tenths, 30.0)
        self.assertEqual(reports[0].final_speed_raw_tenths, 8.0)
        self.assertEqual(reports[0].outcome, "DECELERATED_BUT_NOT_ZERO")

    def test_collect_stop_experiment_preserves_acceleration_outcome_over_later_stale_summary(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T10:00:00Z",
                t=0.0,
                session="",
                event="stop_experiment_snapshot",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-accel",
                    "variant": "toggle-only",
                    "command_packet_hex": "F7 A2 04 01 A7 FD",
                    "writes_count": "1",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "12",
                    "baseline_speed_raw_tenths": "8",
                    "confirmed_stop": "false",
                    "outcome": "COMMAND_CAUSED_ACCELERATION",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T10:01:00Z",
                t=60.0,
                session="",
                event="stop_experiment_summary",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-accel",
                    "variant": "toggle-only",
                    "command_packet_hex": "F7 A2 04 01 A7 FD",
                    "writes_count": "1",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "12",
                    "baseline_speed_raw_tenths": "8",
                    "confirmed_stop": "false",
                    "outcome": "NO_FRESH_FE01",
                },
            ),
        ]

        reports = collect_stop_experiment_reports(rows)

        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0].outcome, "COMMAND_CAUSED_ACCELERATION")
        self.assertEqual(reports[0].final_speed_raw_tenths, 12.0)

    def test_collect_stop_experiment_preserves_acceleration_over_unified_skip(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-28T10:00:00Z",
                t=0.0,
                session="",
                event="stop_experiment_snapshot",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-unified",
                    "variant": "unified-a-b",
                    "stop_experiment_command_packet_hex": "F7 A2 01 00 A3 FD | F7 A2 04 01 A7 FD",
                    "writes_count": "4",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "12",
                    "baseline_speed_raw_tenths": "8",
                    "confirmed_stop": "false",
                    "outcome": "COMMAND_CAUSED_ACCELERATION",
                },
            ),
            Row(
                index=1,
                ts_raw="2026-06-28T10:00:05Z",
                t=5.5,
                session="",
                event="stop_experiment_summary",
                raw={},
                data={
                    "observer_mode": "stop_experiment",
                    "experiment_id": "exp-unified",
                    "variant": "unified-a-b",
                    "stop_experiment_command_packet_hex": "F7 A2 01 00 A3 FD | F7 A2 04 01 A7 FD",
                    "writes_count": "4",
                    "blocked_writes_count": "0",
                    "speed_raw_tenths": "12",
                    "baseline_speed_raw_tenths": "8",
                    "confirmed_stop": "false",
                    "outcome": "B_SKIPPED_ACCELERATED_BASELINE",
                },
            ),
        ]

        reports = collect_stop_experiment_reports(rows)

        self.assertEqual(reports[0].outcome, "COMMAND_CAUSED_ACCELERATION")

    def test_load_rows_reads_raw_jsonl_stop_experiment(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
            path = Path(handle.name)
            handle.write(json.dumps({
                "ts": "2026-06-29T00:00:00Z",
                "session_id": "session-a",
                "event": "stop_experiment_summary",
                "observer_mode": "stop_experiment",
                "experiment_id": "experiment-a",
                "variant": "speed-zero-only",
                "stop_experiment_command_packet_hex": "F7 A2 01 00 A3 FD",
                "outcome": "STOP_CONFIRMED",
                "writes_count": 1,
                "blocked_writes_count": 0,
                "confirmed_stop": True,
                "baseline_speed_raw_tenths": 3,
                "speed_raw_tenths": 0,
            }) + "\n")

        rows = load_rows(str(path))
        reports = collect_stop_experiment_reports(rows)

        self.assertEqual(len(rows), 1)
        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0].experiment_id, "experiment-a")
        self.assertEqual(reports[0].command_packet_hex, "F7 A2 01 00 A3 FD")
        self.assertEqual(reports[0].outcome, "STOP_CONFIRMED")
        self.assertTrue(reports[0].confirmed_stop)

    def test_load_rows_reads_jsonl_directory_tree_in_session_order(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            nested = directory / "TrainingLogs"
            nested.mkdir()
            (nested / "b.jsonl").write_text(json.dumps({
                "ts": "2026-06-29T00:00:01Z",
                "session_id": "session-b",
                "event": "stop_experiment_summary",
                "observer_mode": "stop_experiment",
                "experiment_id": "experiment-b",
                "variant": "toggle-only",
                "stop_experiment_command_packet_hex": "F7 A2 04 01 A7 FD",
                "outcome": "STATE_STILL_RUNNING",
            }) + "\n", encoding="utf-8")
            (nested / "a.jsonl").write_text(json.dumps({
                "ts": "2026-06-29T00:00:00Z",
                "session_id": "session-a",
                "event": "stop_experiment_summary",
                "observer_mode": "stop_experiment",
                "experiment_id": "experiment-a",
                "variant": "speed-zero-only",
                "stop_experiment_command_packet_hex": "F7 A2 01 00 A3 FD",
                "outcome": "DECELERATED_BUT_NOT_ZERO",
            }) + "\n", encoding="utf-8")

            rows = load_rows(str(directory))

        self.assertEqual([row.session for row in rows], ["session-a", "session-b"])
        self.assertEqual([row.event for row in rows], ["stop_experiment_summary", "stop_experiment_summary"])


class StopTimelineReportTests(unittest.TestCase):
    def test_stop_confirmation_requires_fresh_zero_speed_evidence(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-29T00:00:00Z",
                t=0.0,
                session="session-a",
                event="stop_verification",
                raw={},
                data={
                    "stop_confirmed": "true",
                    "stop_has_fresh_report": "false",
                    "stop_fe01_after_app_speed_raw_tenths": "8",
                },
            )
        ]

        reports = collect_stop_timeline_reports(rows)

        self.assertEqual(len(reports), 1)
        self.assertNotEqual(reports[0].classification, "STOP_CONFIRMED")

    def test_stop_confirmation_accepts_fresh_zero_speed_evidence(self):
        rows = [
            Row(
                index=0,
                ts_raw="2026-06-29T00:00:00Z",
                t=0.0,
                session="session-a",
                event="stop_verification",
                raw={},
                data={
                    "stop_confirmed": "true",
                    "stop_has_fresh_report": "true",
                    "stop_fe01_after_state": "0",
                    "stop_fe01_after_speed_raw_tenths": "0",
                    "stop_fe01_after_app_speed_raw_tenths": "0",
                },
            )
        ]

        reports = collect_stop_timeline_reports(rows)

        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0].classification, "STOP_CONFIRMED")


if __name__ == "__main__":
    unittest.main()
