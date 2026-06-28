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


if __name__ == "__main__":
    unittest.main()
