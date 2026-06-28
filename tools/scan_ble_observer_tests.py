import asyncio
import importlib
import sys
import types
import unittest


def load_scan_ble():
    bleak = types.ModuleType("bleak")
    bleak.BleakClient = object
    bleak.BleakScanner = object

    bleak_exc = types.ModuleType("bleak.exc")
    bleak_exc.BleakBluetoothNotAvailableError = RuntimeError
    bleak_exc.BleakError = RuntimeError

    sys.modules["bleak"] = bleak
    sys.modules["bleak.exc"] = bleak_exc

    return importlib.import_module("scan_ble")


scan_ble = load_scan_ble()


class PassiveFe01ObserverTests(unittest.TestCase):
    def test_parse_fe01_observation_extracts_raw_fields(self):
        frame = scan_ble._build_sample_fe01_frame(
            state=1,
            speed_raw_tenths=37,
            mode=1,
            time_s=125,
            distance_raw=42,
            steps=321,
            app_speed_raw_tenths=30,
            button=3,
        )

        parsed = scan_ble._parse_fe01_observation(frame)

        self.assertTrue(parsed["parse_ok"])
        self.assertTrue(parsed["checksum_ok"])
        self.assertEqual(parsed["state"], 1)
        self.assertEqual(parsed["speed_raw_tenths"], 37)
        self.assertEqual(parsed["app_speed_raw_tenths"], 30)
        self.assertEqual(parsed["mode"], 1)
        self.assertEqual(parsed["button"], 3)
        self.assertEqual(parsed["time_s"], 125)
        self.assertEqual(parsed["distance_raw"], 42)
        self.assertEqual(parsed["steps"], 321)
        self.assertIn("F8 A2", parsed["raw_fe01_hex"])

    def test_make_observation_row_includes_zero_write_count(self):
        frame = scan_ble._build_sample_fe01_frame(button=0)

        row = scan_ble._make_fe01_observation_row(
            data=frame,
            ts="2026-06-28T10:00:00.000Z",
            elapsed_s=1.2345,
            observation_id="obs-1",
            device_name="KS-F0",
            device_address="AA:BB",
            notification_index=7,
            gap_since_previous_s=None,
            writes_count=0,
        )

        self.assertEqual(row["observer_mode"], "passive_fe01_observer")
        self.assertEqual(row["observation_id"], "obs-1")
        self.assertEqual(row["device_name"], "KS-F0")
        self.assertEqual(row["device_address"], "AA:BB")
        self.assertEqual(row["notification_index"], 7)
        self.assertEqual(row["writes_count"], 0)
        self.assertEqual(row["gap_since_previous_s"], "")
        self.assertTrue(row["parse_ok"])
        self.assertTrue(row["checksum_ok"])

    def test_passive_write_guard_blocks_accidental_write(self):
        class FakeClient:
            async def write_gatt_char(self, *args, **kwargs):
                return None

        client = FakeClient()
        guard = scan_ble.PassiveWriteGuard()
        guard.install(client)

        async def attempt_write():
            await client.write_gatt_char("FE02", b"\x00", response=False)

        with self.assertRaises(RuntimeError):
            asyncio.run(attempt_write())

        self.assertEqual(guard.writes_count, 0)
        self.assertEqual(guard.blocked_writes_count, 1)


class StopExperimentTests(unittest.TestCase):
    def test_stop_experiment_variants_are_whitelisted(self):
        self.assertEqual(set(scan_ble.STOP_EXPERIMENT_VARIANTS), {"speed-zero-only", "toggle-only"})
        self.assertNotIn("raw", scan_ble.STOP_EXPERIMENT_VARIANTS)
        self.assertNotIn("seq", scan_ble.STOP_EXPERIMENT_VARIANTS)

    def test_speed_zero_only_plan_has_exactly_one_stop_packet(self):
        plan = scan_ble._stop_experiment_variant_plan("speed-zero-only")

        self.assertEqual(plan.variant, "speed-zero-only")
        self.assertEqual([scan_ble._hex(packet) for packet in plan.packets], ["F7 A2 01 00 A3 FD"])

    def test_toggle_only_plan_has_exactly_one_toggle_packet(self):
        plan = scan_ble._stop_experiment_variant_plan("toggle-only")

        self.assertEqual(plan.variant, "toggle-only")
        self.assertEqual([scan_ble._hex(packet) for packet in plan.packets], ["F7 A2 04 01 A7 FD"])

    def test_stop_experiment_requires_all_safety_confirmations(self):
        missing = scan_ble._missing_stop_experiment_confirmations(
            confirm_no_load=True,
            confirm_power_switch_ready=False,
            confirm_operator_present=True,
        )

        self.assertEqual(missing, ["--confirm-power-switch-ready"])

    def test_stop_experiment_baseline_accepts_fresh_low_moving_speed(self):
        parsed = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=30))

        error = scan_ble._stop_experiment_baseline_error(parsed, freshness_s=0.4)

        self.assertIsNone(error)

    def test_stop_experiment_baseline_rejects_stopped_stale_and_high_speed(self):
        stopped = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=0))
        moving = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=30))
        high = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=55))

        self.assertEqual(scan_ble._stop_experiment_baseline_error(stopped, freshness_s=0.4), "stopped_baseline")
        self.assertEqual(scan_ble._stop_experiment_baseline_error(moving, freshness_s=5.0), "stale_baseline")
        self.assertEqual(scan_ble._stop_experiment_baseline_error(high, freshness_s=0.4), "high_speed_baseline")

    def test_stop_experiment_outcome_classifies_confirmed_stop(self):
        latest = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=0, speed_raw_tenths=0))

        outcome = scan_ble._classify_stop_experiment_outcome(
            baseline_speed_raw_tenths=30,
            latest_after_command=latest,
            latest_freshness_s=0.3,
            max_after_command_speed_raw_tenths=30,
        )

        self.assertEqual(outcome, "STOP_CONFIRMED")

    def test_stop_experiment_outcome_classifies_deceleration_and_acceleration(self):
        decel = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=8))
        accelerated = scan_ble._parse_fe01_observation(scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=42))

        decel_outcome = scan_ble._classify_stop_experiment_outcome(
            baseline_speed_raw_tenths=30,
            latest_after_command=decel,
            latest_freshness_s=0.3,
            max_after_command_speed_raw_tenths=30,
        )
        acceleration_outcome = scan_ble._classify_stop_experiment_outcome(
            baseline_speed_raw_tenths=30,
            latest_after_command=accelerated,
            latest_freshness_s=0.3,
            max_after_command_speed_raw_tenths=42,
        )

        self.assertEqual(decel_outcome, "DECELERATED_BUT_NOT_ZERO")
        self.assertEqual(acceleration_outcome, "COMMAND_CAUSED_ACCELERATION")

    def test_stop_experiment_row_contains_command_and_outcome_fields(self):
        frame = scan_ble._build_sample_fe01_frame(state=1, speed_raw_tenths=30)
        plan = scan_ble._stop_experiment_variant_plan("speed-zero-only")

        row = scan_ble._make_stop_experiment_row(
            data=frame,
            ts="2026-06-28T10:00:00.000Z",
            elapsed_s=1.0,
            experiment_id="exp-1",
            device_name="KS-F0",
            device_address="AA:BB",
            notification_index=1,
            gap_since_previous_s=None,
            writes_count=1,
            blocked_writes_count=0,
            plan=plan,
            event="notify_fe01",
            baseline_speed_raw_tenths=30,
            baseline_state=1,
            freshness_s=0.2,
            confirmed_stop=False,
            outcome="STATE_STILL_RUNNING",
        )

        self.assertEqual(row["observer_mode"], "stop_experiment")
        self.assertEqual(row["experiment_id"], "exp-1")
        self.assertEqual(row["variant"], "speed-zero-only")
        self.assertEqual(row["command_packet_hex"], "F7 A2 01 00 A3 FD")
        self.assertEqual(row["baseline_speed_raw_tenths"], 30)
        self.assertEqual(row["freshness_s"], 0.2)
        self.assertEqual(row["confirmed_stop"], False)
        self.assertEqual(row["outcome"], "STATE_STILL_RUNNING")

    def test_stop_experiment_write_guard_allows_only_whitelisted_packet(self):
        class FakeClient:
            def __init__(self):
                self.writes = []

            async def write_gatt_char(self, char_uuid, data, response=False):
                self.writes.append((char_uuid, bytes(data), response))

        client = FakeClient()
        packet = scan_ble._stop_experiment_variant_plan("speed-zero-only").packets[0]
        guard = scan_ble.WhitelistedWriteGuard({packet})
        guard.install(client)

        async def attempt_writes():
            await client.write_gatt_char(scan_ble.CHAR_WRITE_FE02, packet, response=False)
            await client.write_gatt_char(scan_ble.CHAR_WRITE_FE02, b"\xF7\xA2\x03\x07\xAC\xFD", response=False)

        with self.assertRaises(RuntimeError):
            asyncio.run(attempt_writes())

        self.assertEqual(guard.writes_count, 1)
        self.assertEqual(guard.blocked_writes_count, 1)
        self.assertEqual(len(client.writes), 1)


if __name__ == "__main__":
    unittest.main()
