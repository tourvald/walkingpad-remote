#!/usr/bin/env python3
import importlib
import stat
import sys
import types
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


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


class BleToolingSetupTests(unittest.TestCase):
    def test_requirements_ble_pins_bleak(self):
        requirements = (REPO_ROOT / "requirements-ble.txt").read_text(encoding="utf-8")

        self.assertIn("bleak==3.0.2", requirements)

    def test_ble_scripts_exist_and_are_executable(self):
        for relative in ("scripts/setup_ble_env.sh", "scripts/run_ble_tool.sh"):
            path = REPO_ROOT / relative
            mode = path.stat().st_mode

            self.assertTrue(path.exists(), relative)
            self.assertTrue(mode & stat.S_IXUSR, relative)

    def test_run_ble_tool_uses_project_ble_venv(self):
        script = (REPO_ROOT / "scripts/run_ble_tool.sh").read_text(encoding="utf-8")

        self.assertIn(".venv-ble", script)
        self.assertIn("scan_ble.py", script)


class BleDoctorTests(unittest.TestCase):
    def test_service_capabilities_detect_fe00_fe01_fe02(self):
        class Characteristic:
            def __init__(self, uuid, properties):
                self.uuid = uuid
                self.properties = properties

        class Service:
            def __init__(self, uuid, characteristics):
                self.uuid = uuid
                self.characteristics = characteristics

        services = [
            Service(
                scan_ble.SERVICE_FE00,
                [
                    Characteristic(scan_ble.CHAR_NOTIFY_FE01, ["notify"]),
                    Characteristic(scan_ble.CHAR_WRITE_FE02, ["write-without-response"]),
                ],
            )
        ]

        capabilities = scan_ble._inspect_ble_services(services)

        self.assertTrue(capabilities["has_fe00"])
        self.assertTrue(capabilities["has_fe01_notify"])
        self.assertTrue(capabilities["has_fe02_write"])
        self.assertEqual(capabilities["services_count"], 1)

    def test_doctor_dry_run_report_contains_environment_and_capabilities(self):
        report = scan_ble._make_ble_doctor_dry_run_report(name_filter="KS-F0")
        lines = scan_ble._format_ble_doctor_report(report)
        text = "\n".join(lines)

        self.assertIn("mode=ble_doctor", text)
        self.assertIn("python_executable=", text)
        self.assertIn("bleak_version=", text)
        self.assertIn("device_name=KS-F0", text)
        self.assertIn("has_fe01_notify=true", text)

    def test_observe_summary_lines_include_required_diagnostics(self):
        lines = scan_ble._format_observe_fe01_summary(
            csv_path="/tmp/fe01.csv",
            device_name="KS-F0",
            device_address="dry-run",
            writes_count=0,
            blocked_writes_count=0,
            notifications_count=0,
            observation_id="obs-1",
            attempted_duration_s=30.0,
            notify_started=True,
        )
        text = "\n".join(lines)

        self.assertIn("subscribed_char=FE01", text)
        self.assertIn("writes_count=0", text)
        self.assertIn("blocked_writes_count=0", text)
        self.assertIn("notifications_count=0", text)
        self.assertIn("notification_handler_invoked=false", text)
        self.assertIn("possible_cause=device_not_moving_or_not_sending_status", text)


if __name__ == "__main__":
    unittest.main()
