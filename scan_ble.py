import argparse
import asyncio
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import importlib.metadata
import platform
import subprocess
import sys
import time
import uuid
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError

    try:
        from bleak.exc import BleakBluetoothNotAvailableError
    except ImportError:
        class BleakBluetoothNotAvailableError(BleakError):
            pass
except ModuleNotFoundError:
    BleakClient = None
    BleakScanner = None

    class BleakError(Exception):
        pass

    class BleakBluetoothNotAvailableError(BleakError):
        pass

BLE_BASE = "0000{short}-0000-1000-8000-00805f9b34fb"
SERVICE_FE00 = BLE_BASE.format(short="fe00")
SERVICE_FTMS = BLE_BASE.format(short="1826")  # Fitness Machine Service (FTMS)
SERVICE_FFF0 = BLE_BASE.format(short="fff0")  # Common FitShow/FitMonster service
CHAR_NOTIFY_FE01 = BLE_BASE.format(short="fe01")
CHAR_WRITE_FE02 = BLE_BASE.format(short="fe02")
SVC_FFC0 = "f000ffc0-0451-4000-b000-000000000000"
CHAR_FFC1 = "f000ffc1-0451-4000-b000-000000000000"
CHAR_FFC2 = "f000ffc2-0451-4000-b000-000000000000"
PASSIVE_OBSERVER_MODE = "passive_fe01_observer"
PASSIVE_ALL_NOTIFY_MODE = "passive_all_notify_observer"
STOP_EXPERIMENT_MODE = "stop_experiment"
STOP_EXPERIMENT_BASELINE_FRESHNESS_SECONDS = 2.0
STOP_EXPERIMENT_MAX_BASELINE_SPEED_RAW_TENTHS = 40
STOP_EXPERIMENT_ACCELERATION_MARGIN_RAW_TENTHS = 2
STOP_EXPERIMENT_STOPPED_STATES = {0, 2, 5, 7, 9}
STOP_EXPERIMENT_VARIANTS = {
    "speed-zero-only": {
        "label": "SPEED ZERO ONLY",
        "packet": bytes.fromhex("F7 A2 01 00 A3 FD"),
    },
    "toggle-only": {
        "label": "START/STOP TOGGLE ONLY",
        "packet": bytes.fromhex("F7 A2 04 01 A7 FD"),
    },
}
OBSERVE_FE01_CSV_FIELDS = [
    "ts",
    "elapsed_s",
    "observation_id",
    "device_name",
    "device_address",
    "raw_fe01_hex",
    "parse_ok",
    "checksum_ok",
    "state",
    "speed_raw_tenths",
    "app_speed_raw_tenths",
    "mode",
    "button",
    "time_s",
    "distance_raw",
    "steps",
    "notification_index",
    "gap_since_previous_s",
    "observer_mode",
    "writes_count",
]
OBSERVE_ALL_NOTIFY_CSV_FIELDS = [
    "ts",
    "elapsed_s",
    "observation_id",
    "device_name",
    "device_address",
    "char_uuid",
    "char_label",
    "raw_hex",
    "parse_ok",
    "checksum_ok",
    "state",
    "speed_raw_tenths",
    "app_speed_raw_tenths",
    "mode",
    "button",
    "time_s",
    "distance_raw",
    "steps",
    "notification_index",
    "gap_since_previous_s",
    "observer_mode",
    "writes_count",
]
STOP_EXPERIMENT_CSV_FIELDS = OBSERVE_FE01_CSV_FIELDS + [
    "experiment_id",
    "variant",
    "event",
    "command_label",
    "command_packet_hex",
    "baseline_speed_raw_tenths",
    "baseline_state",
    "freshness_s",
    "confirmed_stop",
    "outcome",
    "blocked_writes_count",
]


@dataclass(frozen=True)
class StopExperimentPlan:
    variant: str
    label: str
    packets: tuple[bytes, ...]


@dataclass
class BleDoctorReport:
    mode: str
    python_executable: str
    python_version: str
    bleak_version: str
    macos_version: str
    bluetooth_state: str
    device_name: str
    device_address: str
    device_rssi: str
    device_found: bool
    connected: bool
    services_count: int
    characteristics_count: int
    has_fe00: bool
    has_fe01_notify: bool
    has_fe02_write: bool
    error: str = ""


def _hex(data: bytes) -> str:
    return data.hex(" ").upper()


def _ensure_bleak_available() -> None:
    if BleakClient is None or BleakScanner is None:
        raise RuntimeError("Python package 'bleak' is required for BLE access. Install it to use live BLE commands.")


def _bleak_version() -> str:
    try:
        return importlib.metadata.version("bleak")
    except importlib.metadata.PackageNotFoundError:
        return "not_installed"


def _macos_bluetooth_state() -> str:
    if platform.system() != "Darwin":
        return "not_macos"
    try:
        result = subprocess.run(
            ["system_profiler", "SPBluetoothDataType"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"unknown:{exc}"

    output = result.stdout or ""
    if "State: On" in output:
        return "on"
    if "State: Off" in output:
        return "off"
    return "unknown"


def _from_hex(payload: str) -> bytes:
    return bytes.fromhex(payload)


def _byte2int(data: bytes) -> int:
    return sum(data[i] << (8 * (len(data) - 1 - i)) for i in range(len(data)))


def _fix_crc(cmd: bytearray) -> bytearray:
    cmd[-2] = sum(cmd[1:-2]) % 256
    return cmd


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _checksum_ok(data: bytes) -> bool:
    if len(data) < 3:
        return False
    checksum_index = len(data) - 2
    expected = data[checksum_index]
    return (sum(data[1:checksum_index]) & 0xFF) == expected


def _bool_text(value: bool) -> str:
    return "true" if value else "false"


def _normalize_uuid(value: str) -> str:
    return str(value or "").lower()


def _normalize_properties(properties) -> set[str]:
    return {str(prop).lower() for prop in (properties or [])}


def _inspect_ble_services(services) -> dict:
    services_count = 0
    characteristics_count = 0
    has_fe00 = False
    has_fe01_notify = False
    has_fe02_write = False

    for service in services or []:
        services_count += 1
        service_uuid = _normalize_uuid(getattr(service, "uuid", ""))
        if service_uuid == SERVICE_FE00:
            has_fe00 = True
        for characteristic in getattr(service, "characteristics", []) or []:
            characteristics_count += 1
            char_uuid = _normalize_uuid(getattr(characteristic, "uuid", ""))
            props = _normalize_properties(getattr(characteristic, "properties", []))
            if char_uuid == CHAR_NOTIFY_FE01 and ("notify" in props or "indicate" in props):
                has_fe01_notify = True
            if char_uuid == CHAR_WRITE_FE02 and (
                "write" in props or "write-without-response" in props or "write_without_response" in props
            ):
                has_fe02_write = True

    return {
        "services_count": services_count,
        "characteristics_count": characteristics_count,
        "has_fe00": has_fe00,
        "has_fe01_notify": has_fe01_notify,
        "has_fe02_write": has_fe02_write,
    }


def _make_ble_doctor_dry_run_report(name_filter: Optional[str]) -> BleDoctorReport:
    return BleDoctorReport(
        mode="ble_doctor",
        python_executable=sys.executable,
        python_version=platform.python_version(),
        bleak_version=_bleak_version(),
        macos_version=platform.platform(),
        bluetooth_state="dry_run",
        device_name=name_filter or "dry-run",
        device_address="dry-run",
        device_rssi="dry-run",
        device_found=True,
        connected=True,
        services_count=1,
        characteristics_count=2,
        has_fe00=True,
        has_fe01_notify=True,
        has_fe02_write=True,
    )


def _format_ble_doctor_report(report: BleDoctorReport) -> list[str]:
    lines = [
        f"mode={report.mode}",
        f"python_executable={report.python_executable}",
        f"python_version={report.python_version}",
        f"bleak_version={report.bleak_version}",
        f"macos_version={report.macos_version}",
        f"bluetooth_state={report.bluetooth_state}",
        f"device_found={_bool_text(report.device_found)}",
        f"device_name={report.device_name}",
        f"device_address={report.device_address}",
        f"device_rssi={report.device_rssi}",
        f"connected={_bool_text(report.connected)}",
        f"services_count={report.services_count}",
        f"characteristics_count={report.characteristics_count}",
        f"has_fe00={_bool_text(report.has_fe00)}",
        f"has_fe01_notify={_bool_text(report.has_fe01_notify)}",
        f"has_fe02_write={_bool_text(report.has_fe02_write)}",
    ]
    if report.error:
        lines.append(f"error={report.error}")
    if not report.has_fe01_notify:
        lines.extend(_no_fe01_notification_possible_causes())
    return lines


def _no_fe01_notification_possible_causes() -> list[str]:
    return [
        "possible_cause=device_not_moving_or_not_sending_status",
        "possible_cause=wrong_characteristic_or_missing_fe01_notify",
        "possible_cause=another_central_connected",
        "possible_cause=macos_bluetooth_permission_or_corebluetooth_issue",
        "possible_cause=ble_adapter_issue",
    ]


def _format_observe_fe01_summary(
    csv_path: str,
    device_name: str,
    device_address: str,
    writes_count: int,
    blocked_writes_count: int,
    notifications_count: int,
    observation_id: str,
    attempted_duration_s: float,
    notify_started: bool,
) -> list[str]:
    lines = [
        f"mode={PASSIVE_OBSERVER_MODE}",
        "subscribed_char=FE01",
        f"csv_path={csv_path}",
        f"device_name={device_name}",
        f"device_address={device_address}",
        f"notify_started={_bool_text(notify_started)}",
        f"notification_handler_invoked={_bool_text(notifications_count > 0)}",
        f"attempted_duration_s={attempted_duration_s:g}",
        f"writes_count={writes_count}",
        f"blocked_writes_count={blocked_writes_count}",
        f"notifications_count={notifications_count}",
        f"observation_id={observation_id}",
    ]
    if notifications_count == 0:
        lines.extend(_no_fe01_notification_possible_causes())
    return lines


def _char_label(uuid_text: str) -> str:
    normalized = _normalize_uuid(uuid_text)
    if normalized == CHAR_NOTIFY_FE01:
        return "FE01"
    if normalized == CHAR_FFC1:
        return "FFC1"
    if normalized == CHAR_FFC2:
        return "FFC2"
    return normalized


def _notify_characteristics(services) -> list[dict]:
    targets: list[dict] = []
    for service in services or []:
        for characteristic in getattr(service, "characteristics", []) or []:
            props = _normalize_properties(getattr(characteristic, "properties", []))
            if "notify" not in props and "indicate" not in props:
                continue
            uuid_text = str(getattr(characteristic, "uuid", ""))
            targets.append(
                {
                    "uuid": uuid_text,
                    "label": _char_label(uuid_text),
                    "properties": ",".join(str(prop) for prop in getattr(characteristic, "properties", []) or []),
                }
            )
    return targets


def _format_observe_all_notify_summary(
    csv_path: str,
    device_name: str,
    device_address: str,
    subscribed_count: int,
    writes_count: int,
    blocked_writes_count: int,
    notifications_count: int,
    observation_id: str,
    attempted_duration_s: float,
) -> list[str]:
    lines = [
        f"mode={PASSIVE_ALL_NOTIFY_MODE}",
        f"csv_path={csv_path}",
        f"device_name={device_name}",
        f"device_address={device_address}",
        f"subscribed_count={subscribed_count}",
        f"notification_handler_invoked={_bool_text(notifications_count > 0)}",
        f"attempted_duration_s={attempted_duration_s:g}",
        f"writes_count={writes_count}",
        f"blocked_writes_count={blocked_writes_count}",
        f"notifications_count={notifications_count}",
        f"observation_id={observation_id}",
    ]
    if notifications_count == 0:
        lines.extend(_no_fe01_notification_possible_causes())
    return lines


def _encode3(value: int) -> list[int]:
    value = max(0, min(0xFF_FF_FF, int(value)))
    return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]


def _build_sample_fe01_frame(
    state: int = 1,
    speed_raw_tenths: int = 0,
    mode: int = 1,
    time_s: int = 0,
    distance_raw: int = 0,
    steps: int = 0,
    app_speed_raw_tenths: int = 0,
    button: int = 0,
) -> bytes:
    frame = bytearray([0xF8, 0xA2, state & 0xFF, speed_raw_tenths & 0xFF, mode & 0xFF])
    frame.extend(_encode3(time_s))
    frame.extend(_encode3(distance_raw))
    frame.extend(_encode3(steps))
    frame.extend([app_speed_raw_tenths & 0xFF, 0x00, button & 0xFF, 0x00, 0x00, 0xFD])
    checksum_index = len(frame) - 2
    frame[checksum_index] = sum(frame[1:checksum_index]) & 0xFF
    return bytes(frame)


def _parse_fe01_observation(data: bytes) -> dict:
    raw_hex = _hex(data)
    if len(data) < 20 or data[0] != 0xF8 or data[1] != 0xA2:
        return {
            "raw_fe01_hex": raw_hex,
            "parse_ok": False,
            "checksum_ok": False,
            "state": "",
            "speed_raw_tenths": "",
            "app_speed_raw_tenths": "",
            "mode": "",
            "button": "",
            "time_s": "",
            "distance_raw": "",
            "steps": "",
        }

    return {
        "raw_fe01_hex": raw_hex,
        "parse_ok": True,
        "checksum_ok": _checksum_ok(data),
        "state": data[2],
        "speed_raw_tenths": data[3],
        "app_speed_raw_tenths": data[14],
        "mode": data[4],
        "button": data[16],
        "time_s": _byte2int(data[5:8]),
        "distance_raw": _byte2int(data[8:11]),
        "steps": _byte2int(data[11:14]),
    }


def _make_fe01_observation_row(
    data: bytes,
    ts: str,
    elapsed_s: float,
    observation_id: str,
    device_name: str,
    device_address: str,
    notification_index: int,
    gap_since_previous_s: Optional[float],
    writes_count: int,
) -> dict:
    parsed = _parse_fe01_observation(data)
    row = {
        "ts": ts,
        "elapsed_s": round(elapsed_s, 3),
        "observation_id": observation_id,
        "device_name": device_name,
        "device_address": device_address,
        "notification_index": notification_index,
        "gap_since_previous_s": "" if gap_since_previous_s is None else round(gap_since_previous_s, 3),
        "observer_mode": PASSIVE_OBSERVER_MODE,
        "writes_count": writes_count,
    }
    row.update(parsed)
    return row


class PassiveWriteGuard:
    def __init__(self) -> None:
        self.writes_count = 0
        self.blocked_writes_count = 0

    def install(self, client) -> None:
        async def blocked_write_gatt_char(*args, **kwargs):
            self.blocked_writes_count += 1
            print("[PASSIVE GUARD] blocked accidental write_gatt_char call")
            raise RuntimeError("Passive FE01 observer forbids BLE writes")

        client.write_gatt_char = blocked_write_gatt_char


class WhitelistedWriteGuard:
    def __init__(self, allowed_packets: set[bytes]) -> None:
        self.allowed_packets = {bytes(packet) for packet in allowed_packets}
        self.writes_count = 0
        self.blocked_writes_count = 0

    def install(self, client) -> None:
        original_write = client.write_gatt_char

        async def guarded_write_gatt_char(char_uuid, data, *args, **kwargs):
            packet = bytes(data)
            if char_uuid != CHAR_WRITE_FE02 or packet not in self.allowed_packets:
                self.blocked_writes_count += 1
                print(f"[STOP EXPERIMENT GUARD] blocked unexpected write {char_uuid} <= {_hex(packet)}")
                raise RuntimeError("Stop experiment runner allows only its whitelisted packet")
            self.writes_count += 1
            return await original_write(char_uuid, packet, *args, **kwargs)

        client.write_gatt_char = guarded_write_gatt_char


def _stop_experiment_variant_plan(variant: str) -> StopExperimentPlan:
    config = STOP_EXPERIMENT_VARIANTS.get(variant)
    if not config:
        raise ValueError(f"Unknown stop experiment variant: {variant}")
    return StopExperimentPlan(
        variant=variant,
        label=str(config["label"]),
        packets=(bytes(config["packet"]),),
    )


def _missing_stop_experiment_confirmations(
    confirm_no_load: bool,
    confirm_power_switch_ready: bool,
    confirm_operator_present: bool,
) -> list[str]:
    missing = []
    if not confirm_no_load:
        missing.append("--confirm-no-load")
    if not confirm_power_switch_ready:
        missing.append("--confirm-power-switch-ready")
    if not confirm_operator_present:
        missing.append("--confirm-operator-present")
    return missing


def _int_or_none(value) -> Optional[int]:
    if value == "" or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _stop_experiment_baseline_error(parsed: dict, freshness_s: float) -> Optional[str]:
    if not parsed.get("parse_ok") or not parsed.get("checksum_ok"):
        return "invalid_fe01"
    if freshness_s > STOP_EXPERIMENT_BASELINE_FRESHNESS_SECONDS:
        return "stale_baseline"
    speed = _int_or_none(parsed.get("speed_raw_tenths"))
    if speed is None:
        return "invalid_speed"
    if speed <= 0:
        return "stopped_baseline"
    if speed > STOP_EXPERIMENT_MAX_BASELINE_SPEED_RAW_TENTHS:
        return "high_speed_baseline"
    return None


def _is_stop_confirmed(parsed: dict) -> bool:
    speed = _int_or_none(parsed.get("speed_raw_tenths"))
    state = _int_or_none(parsed.get("state"))
    return (
        bool(parsed.get("parse_ok"))
        and bool(parsed.get("checksum_ok"))
        and speed == 0
        and state in STOP_EXPERIMENT_STOPPED_STATES
    )


def _classify_stop_experiment_outcome(
    baseline_speed_raw_tenths: int,
    latest_after_command: Optional[dict],
    latest_freshness_s: float,
    max_after_command_speed_raw_tenths: Optional[int],
) -> str:
    if latest_after_command is None or latest_freshness_s > STOP_EXPERIMENT_BASELINE_FRESHNESS_SECONDS:
        return "NO_FRESH_FE01"

    if (
        max_after_command_speed_raw_tenths is not None
        and max_after_command_speed_raw_tenths
        > baseline_speed_raw_tenths + STOP_EXPERIMENT_ACCELERATION_MARGIN_RAW_TENTHS
    ):
        return "COMMAND_CAUSED_ACCELERATION"

    if _is_stop_confirmed(latest_after_command):
        return "STOP_CONFIRMED"

    latest_speed = _int_or_none(latest_after_command.get("speed_raw_tenths"))
    if latest_speed is not None and 0 < latest_speed < baseline_speed_raw_tenths:
        return "DECELERATED_BUT_NOT_ZERO"

    return "STATE_STILL_RUNNING"


def _make_stop_experiment_row(
    data: bytes,
    ts: str,
    elapsed_s: float,
    experiment_id: str,
    device_name: str,
    device_address: str,
    notification_index: int,
    gap_since_previous_s: Optional[float],
    writes_count: int,
    blocked_writes_count: int,
    plan: StopExperimentPlan,
    event: str,
    baseline_speed_raw_tenths: Optional[int],
    baseline_state: Optional[int],
    freshness_s: Optional[float],
    confirmed_stop: bool,
    outcome: str,
) -> dict:
    row = _make_fe01_observation_row(
        data=data,
        ts=ts,
        elapsed_s=elapsed_s,
        observation_id=experiment_id,
        device_name=device_name,
        device_address=device_address,
        notification_index=notification_index,
        gap_since_previous_s=gap_since_previous_s,
        writes_count=writes_count,
    )
    row["observer_mode"] = STOP_EXPERIMENT_MODE
    row.update(
        {
            "experiment_id": experiment_id,
            "variant": plan.variant,
            "event": event,
            "command_label": plan.label,
            "command_packet_hex": _hex(plan.packets[0]),
            "baseline_speed_raw_tenths": "" if baseline_speed_raw_tenths is None else baseline_speed_raw_tenths,
            "baseline_state": "" if baseline_state is None else baseline_state,
            "freshness_s": "" if freshness_s is None else round(freshness_s, 3),
            "confirmed_stop": confirmed_stop,
            "outcome": outcome,
            "blocked_writes_count": blocked_writes_count,
        }
    )
    return row


def _parse_status(data: bytes) -> Optional[dict]:
    if len(data) >= 18 and data[0] == 0xF8 and data[1] == 0xA2:
        dist = _byte2int(data[8:11])
        steps = _byte2int(data[11:14])
        return {
            "type": "cur_status",
            "belt_state": data[2],
            "speed": data[3] / 10.0,
            "manual_mode": data[4],
            "time": _byte2int(data[5:8]),
            "dist": dist / 100.0,
            "steps": steps,
            "app_speed": data[14] / 30.0 if data[14] > 0 else 0.0,
            "controller_button": data[16],
            "raw": _hex(data),
        }

    if len(data) >= 17 and data[0] == 0xF8 and data[1] == 0xA7:
        return {
            "type": "last_status",
            "time": _byte2int(data[8:11]),
            "dist": _byte2int(data[11:14]) / 100.0,
            "steps": _byte2int(data[14:17]),
            "raw": _hex(data),
        }

    return None


def _match_name(name: Optional[str], needle: Optional[str]) -> bool:
    if not needle:
        return True
    if not name:
        return False
    return needle.lower() in name.lower()


async def scan(timeout: float, name_filter: Optional[str]) -> None:
    _ensure_bleak_available()
    seen: dict[str, tuple[Optional[str], list[str]]] = {}

    def detection_callback(device, adv_data):
        if not _match_name(device.name, name_filter):
            return
        uuids = list(adv_data.service_uuids or [])
        seen[device.address] = (device.name, uuids)

    scanner = BleakScanner(detection_callback=detection_callback)
    try:
        await scanner.start()
        await asyncio.sleep(timeout)
        await scanner.stop()
    except BleakBluetoothNotAvailableError:
        print("Bluetooth is not available. Grant Bluetooth access to Python.")
        print("macOS: System Settings -> Privacy & Security -> Bluetooth -> Python.")
        return
    except BleakError as exc:
        print(f"Bluetooth error: {exc}")
        return

    for address, (name, uuids) in seen.items():
        print(address, name, uuids or None)


async def _resolve_device(address: Optional[str], name_filter: Optional[str]) -> tuple[str, str]:
    _ensure_bleak_available()
    if address:
        return address, name_filter or ""

    def predicate(device, adv):
        if name_filter and device.name and name_filter.lower() in device.name.lower():
            return True
        if adv.service_uuids:
            known = {SERVICE_FE00, SERVICE_FTMS, SERVICE_FFF0}
            if any(u in known for u in adv.service_uuids):
                return True
        return False

    found = await BleakScanner.find_device_by_filter(predicate, timeout=10.0)
    if not found:
        raise RuntimeError("Device not found. Make sure the treadmill is advertising and nearby.")
    return found.address, found.name or ""


async def _scan_for_device_snapshot(name_filter: Optional[str], timeout: float = 10.0) -> Optional[dict]:
    _ensure_bleak_available()
    seen: dict[str, dict] = {}

    def detection_callback(device, adv_data):
        if not _match_name(device.name, name_filter):
            return
        rssi = getattr(adv_data, "rssi", None)
        if rssi is None:
            rssi = getattr(device, "rssi", None)
        seen[device.address] = {
            "address": device.address,
            "name": device.name or "",
            "rssi": "" if rssi is None else str(rssi),
            "service_uuids": list(getattr(adv_data, "service_uuids", []) or []),
        }

    scanner = BleakScanner(detection_callback=detection_callback)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()
    if not seen:
        return None
    return sorted(seen.values(), key=lambda item: item.get("rssi") or "", reverse=True)[0]


async def _get_client_services(client):
    if hasattr(client, "get_services"):
        return await client.get_services()
    return client.services


async def _resolve_address(address: Optional[str], name_filter: Optional[str]) -> str:
    resolved, _ = await _resolve_device(address, name_filter)
    return resolved


async def ble_doctor(address: Optional[str], name_filter: Optional[str], dry_run_sample: bool) -> None:
    if dry_run_sample:
        for line in _format_ble_doctor_report(_make_ble_doctor_dry_run_report(name_filter)):
            print(line)
        return

    report = BleDoctorReport(
        mode="ble_doctor",
        python_executable=sys.executable,
        python_version=platform.python_version(),
        bleak_version=_bleak_version(),
        macos_version=platform.platform(),
        bluetooth_state=_macos_bluetooth_state(),
        device_name=name_filter or "",
        device_address=address or "",
        device_rssi="",
        device_found=False,
        connected=False,
        services_count=0,
        characteristics_count=0,
        has_fe00=False,
        has_fe01_notify=False,
        has_fe02_write=False,
    )

    try:
        if address:
            snapshot = {"address": address, "name": name_filter or "", "rssi": ""}
        else:
            snapshot = await _scan_for_device_snapshot(name_filter)
        if not snapshot:
            report.error = "device_not_found"
            for line in _format_ble_doctor_report(report):
                print(line)
            return

        report.device_found = True
        report.device_name = snapshot.get("name") or name_filter or ""
        report.device_address = snapshot.get("address") or ""
        report.device_rssi = snapshot.get("rssi") or ""

        async with BleakClient(report.device_address) as client:
            report.connected = bool(client.is_connected)
            services = await _get_client_services(client)
            capabilities = _inspect_ble_services(services)
            report.services_count = int(capabilities["services_count"])
            report.characteristics_count = int(capabilities["characteristics_count"])
            report.has_fe00 = bool(capabilities["has_fe00"])
            report.has_fe01_notify = bool(capabilities["has_fe01_notify"])
            report.has_fe02_write = bool(capabilities["has_fe02_write"])
    except Exception as exc:
        report.error = f"{type(exc).__name__}: {exc}"

    for line in _format_ble_doctor_report(report):
        print(line)


async def dump_services(address: Optional[str], name_filter: Optional[str], dry_run_sample: bool) -> None:
    if dry_run_sample:
        report = _make_ble_doctor_dry_run_report(name_filter)
        print("mode=ble_dump_services")
        for line in _format_ble_doctor_report(report)[1:]:
            print(line)
        print("service=FE00")
        print(f"  char={CHAR_NOTIFY_FE01} props=notify")
        print(f"  char={CHAR_WRITE_FE02} props=write-without-response")
        return

    resolved, resolved_name = await _resolve_device(address, name_filter)
    print("mode=ble_dump_services")
    print(f"device_name={resolved_name or name_filter or ''}")
    print(f"device_address={resolved}")
    async with BleakClient(resolved) as client:
        print(f"connected={_bool_text(bool(client.is_connected))}")
        services = await _get_client_services(client)
        capabilities = _inspect_ble_services(services)
        print(f"has_fe00={_bool_text(bool(capabilities['has_fe00']))}")
        print(f"has_fe01_notify={_bool_text(bool(capabilities['has_fe01_notify']))}")
        print(f"has_fe02_write={_bool_text(bool(capabilities['has_fe02_write']))}")
        for service in services:
            print(f"service={service.uuid}")
            for characteristic in service.characteristics:
                props = ",".join(characteristic.properties)
                print(f"  char={characteristic.uuid} props={props}")


async def connect_and_list(address: Optional[str], name_filter: Optional[str]) -> None:
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        services = await _get_client_services(client)
        for s in services:
            print("Service:", s.uuid)
            for c in s.characteristics:
                print("  Char:", c.uuid, c.properties)


async def listen(address: Optional[str], duration: float, name_filter: Optional[str]) -> None:
    def on_notify(sender: int, data: bytearray) -> None:
        parsed = _parse_status(bytes(data))
        if parsed:
            print(f"[NOTIFY] {parsed}")
        else:
            print(f"[NOTIFY] sender={sender} data={_hex(bytes(data))}")

    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        await client.start_notify(CHAR_NOTIFY_FE01, on_notify)
        await asyncio.sleep(duration)
        await client.stop_notify(CHAR_NOTIFY_FE01)


async def observe_fe01(
    address: Optional[str],
    duration: float,
    name_filter: Optional[str],
    csv_path: str,
    dry_run_sample: bool,
) -> None:
    observation_id = str(uuid.uuid4())
    if dry_run_sample:
        guard = PassiveWriteGuard()
        sample = _build_sample_fe01_frame(
            state=1,
            speed_raw_tenths=0,
            mode=1,
            time_s=0,
            distance_raw=0,
            steps=0,
            app_speed_raw_tenths=0,
            button=0,
        )
        with open(csv_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=OBSERVE_FE01_CSV_FIELDS)
            writer.writeheader()
            writer.writerow(
                _make_fe01_observation_row(
                    data=sample,
                    ts=_utc_now_iso(),
                    elapsed_s=0,
                    observation_id=observation_id,
                    device_name=name_filter or "dry-run",
                    device_address=address or "dry-run",
                    notification_index=1,
                    gap_since_previous_s=None,
                    writes_count=guard.writes_count,
                )
            )
        print(f"mode={PASSIVE_OBSERVER_MODE}")
        for line in _format_observe_fe01_summary(
            csv_path=csv_path,
            device_name=name_filter or "dry-run",
            device_address=address or "dry-run",
            writes_count=guard.writes_count,
            blocked_writes_count=guard.blocked_writes_count,
            notifications_count=1,
            observation_id=observation_id,
            attempted_duration_s=duration,
            notify_started=True,
        )[1:]:
            print(line)
        return

    resolved, resolved_name = await _resolve_device(address, name_filter)
    device_name = resolved_name or name_filter or ""
    guard = PassiveWriteGuard()
    notifications_count = 0
    previous_monotonic: Optional[float] = None
    started_monotonic = time.monotonic()

    print("Using address:", resolved)
    print(f"Observation id: {observation_id}")
    print("Passive FE01 observer: writes are guarded and forbidden.")

    with open(csv_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OBSERVE_FE01_CSV_FIELDS)
        writer.writeheader()

        def on_notify(sender: int, data: bytearray) -> None:
            nonlocal notifications_count, previous_monotonic
            now = time.monotonic()
            notifications_count += 1
            gap = None if previous_monotonic is None else now - previous_monotonic
            previous_monotonic = now
            row = _make_fe01_observation_row(
                data=bytes(data),
                ts=_utc_now_iso(),
                elapsed_s=now - started_monotonic,
                observation_id=observation_id,
                device_name=device_name,
                device_address=resolved,
                notification_index=notifications_count,
                gap_since_previous_s=gap,
                writes_count=guard.writes_count,
            )
            writer.writerow(row)
            handle.flush()
            print(
                "[OBSERVE] "
                f"#{notifications_count} state={row['state']} "
                f"speed_raw={row['speed_raw_tenths']} "
                f"app_raw={row['app_speed_raw_tenths']} "
                f"mode={row['mode']} button={row['button']} "
                f"checksum={row['checksum_ok']} raw={row['raw_fe01_hex']}"
            )

        async with BleakClient(resolved) as client:
            print("Connected:", client.is_connected)
            guard.install(client)
            await client.start_notify(CHAR_NOTIFY_FE01, on_notify)
            await asyncio.sleep(duration)
            await client.stop_notify(CHAR_NOTIFY_FE01)

    for line in _format_observe_fe01_summary(
        csv_path=csv_path,
        device_name=device_name,
        device_address=resolved,
        writes_count=guard.writes_count,
        blocked_writes_count=guard.blocked_writes_count,
        notifications_count=notifications_count,
        observation_id=observation_id,
        attempted_duration_s=duration,
        notify_started=True,
    ):
        print(line)


async def observe_all_notify(
    address: Optional[str],
    duration: float,
    name_filter: Optional[str],
    csv_path: str,
    dry_run_sample: bool,
) -> None:
    observation_id = str(uuid.uuid4())
    if dry_run_sample:
        guard = PassiveWriteGuard()
        sample = _build_sample_fe01_frame(state=1, speed_raw_tenths=0, mode=1)
        parsed = _parse_fe01_observation(sample)
        with open(csv_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=OBSERVE_ALL_NOTIFY_CSV_FIELDS)
            writer.writeheader()
            writer.writerow(
                {
                    "ts": _utc_now_iso(),
                    "elapsed_s": 0,
                    "observation_id": observation_id,
                    "device_name": name_filter or "dry-run",
                    "device_address": address or "dry-run",
                    "char_uuid": CHAR_NOTIFY_FE01,
                    "char_label": "FE01",
                    "raw_hex": parsed["raw_fe01_hex"],
                    "parse_ok": parsed["parse_ok"],
                    "checksum_ok": parsed["checksum_ok"],
                    "state": parsed["state"],
                    "speed_raw_tenths": parsed["speed_raw_tenths"],
                    "app_speed_raw_tenths": parsed["app_speed_raw_tenths"],
                    "mode": parsed["mode"],
                    "button": parsed["button"],
                    "time_s": parsed["time_s"],
                    "distance_raw": parsed["distance_raw"],
                    "steps": parsed["steps"],
                    "notification_index": 1,
                    "gap_since_previous_s": "",
                    "observer_mode": PASSIVE_ALL_NOTIFY_MODE,
                    "writes_count": guard.writes_count,
                }
            )
        for line in _format_observe_all_notify_summary(
            csv_path=csv_path,
            device_name=name_filter or "dry-run",
            device_address=address or "dry-run",
            subscribed_count=3,
            writes_count=guard.writes_count,
            blocked_writes_count=guard.blocked_writes_count,
            notifications_count=1,
            observation_id=observation_id,
            attempted_duration_s=duration,
        ):
            print(line)
        return

    resolved, resolved_name = await _resolve_device(address, name_filter)
    device_name = resolved_name or name_filter or ""
    guard = PassiveWriteGuard()
    notifications_count = 0
    previous_monotonic: Optional[float] = None
    started_monotonic = time.monotonic()

    print("Using address:", resolved)
    print(f"Observation id: {observation_id}")
    print("Passive all-notify observer: writes are guarded and forbidden.")

    with open(csv_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OBSERVE_ALL_NOTIFY_CSV_FIELDS)
        writer.writeheader()

        async with BleakClient(resolved) as client:
            print("Connected:", client.is_connected)
            guard.install(client)
            services = await _get_client_services(client)
            targets = _notify_characteristics(services)
            subscribed: list[str] = []

            def make_callback(target: dict):
                def on_notify(sender: int, data: bytearray) -> None:
                    nonlocal notifications_count, previous_monotonic
                    now = time.monotonic()
                    notifications_count += 1
                    gap = None if previous_monotonic is None else now - previous_monotonic
                    previous_monotonic = now
                    payload = bytes(data)
                    parsed = _parse_fe01_observation(payload) if _normalize_uuid(target["uuid"]) == CHAR_NOTIFY_FE01 else {}
                    row = {
                        "ts": _utc_now_iso(),
                        "elapsed_s": round(now - started_monotonic, 3),
                        "observation_id": observation_id,
                        "device_name": device_name,
                        "device_address": resolved,
                        "char_uuid": target["uuid"],
                        "char_label": target["label"],
                        "raw_hex": _hex(payload),
                        "parse_ok": parsed.get("parse_ok", ""),
                        "checksum_ok": parsed.get("checksum_ok", ""),
                        "state": parsed.get("state", ""),
                        "speed_raw_tenths": parsed.get("speed_raw_tenths", ""),
                        "app_speed_raw_tenths": parsed.get("app_speed_raw_tenths", ""),
                        "mode": parsed.get("mode", ""),
                        "button": parsed.get("button", ""),
                        "time_s": parsed.get("time_s", ""),
                        "distance_raw": parsed.get("distance_raw", ""),
                        "steps": parsed.get("steps", ""),
                        "notification_index": notifications_count,
                        "gap_since_previous_s": "" if gap is None else round(gap, 3),
                        "observer_mode": PASSIVE_ALL_NOTIFY_MODE,
                        "writes_count": guard.writes_count,
                    }
                    writer.writerow(row)
                    handle.flush()
                    print(
                        "[OBSERVE ALL] "
                        f"#{notifications_count} char={target['label']} "
                        f"checksum={row['checksum_ok']} raw={row['raw_hex']}"
                    )

                return on_notify

            for target in targets:
                try:
                    await client.start_notify(target["uuid"], make_callback(target))
                    subscribed.append(target["uuid"])
                    print(f"Subscribed: {target['label']} {target['uuid']} props={target['properties']}")
                except Exception as exc:
                    print(f"Subscribe failed: {target['label']} {target['uuid']} error={exc}")

            await asyncio.sleep(duration)

            for uuid_text in subscribed:
                try:
                    await client.stop_notify(uuid_text)
                except Exception as exc:
                    print(f"Stop notify error for {uuid_text}: {exc}")

    for line in _format_observe_all_notify_summary(
        csv_path=csv_path,
        device_name=device_name,
        device_address=resolved,
        subscribed_count=len(subscribed),
        writes_count=guard.writes_count,
        blocked_writes_count=guard.blocked_writes_count,
        notifications_count=notifications_count,
        observation_id=observation_id,
        attempted_duration_s=duration,
    ):
        print(line)


async def stop_experiment(
    address: Optional[str],
    variant: str,
    duration: float,
    name_filter: Optional[str],
    csv_path: str,
    confirm_no_load: bool,
    confirm_power_switch_ready: bool,
    confirm_operator_present: bool,
    dry_run_sample: bool,
    baseline_timeout: float,
) -> None:
    missing = _missing_stop_experiment_confirmations(
        confirm_no_load=confirm_no_load,
        confirm_power_switch_ready=confirm_power_switch_ready,
        confirm_operator_present=confirm_operator_present,
    )
    if missing:
        raise RuntimeError(f"Stop experiment refused: missing safety confirmations: {', '.join(missing)}")

    plan = _stop_experiment_variant_plan(variant)
    experiment_id = str(uuid.uuid4())

    if dry_run_sample:
        baseline = _build_sample_fe01_frame(state=1, speed_raw_tenths=30, mode=1, app_speed_raw_tenths=30)
        after = _build_sample_fe01_frame(state=1, speed_raw_tenths=8, mode=1, app_speed_raw_tenths=0)
        latest_after = _parse_fe01_observation(after)
        outcome = _classify_stop_experiment_outcome(
            baseline_speed_raw_tenths=30,
            latest_after_command=latest_after,
            latest_freshness_s=0.1,
            max_after_command_speed_raw_tenths=30,
        )
        with open(csv_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=STOP_EXPERIMENT_CSV_FIELDS)
            writer.writeheader()
            writer.writerow(
                _make_stop_experiment_row(
                    data=baseline,
                    ts=_utc_now_iso(),
                    elapsed_s=0.0,
                    experiment_id=experiment_id,
                    device_name=name_filter or "dry-run",
                    device_address=address or "dry-run",
                    notification_index=1,
                    gap_since_previous_s=None,
                    writes_count=0,
                    blocked_writes_count=0,
                    plan=plan,
                    event="notify_fe01",
                    baseline_speed_raw_tenths=30,
                    baseline_state=1,
                    freshness_s=0.0,
                    confirmed_stop=False,
                    outcome="",
                )
            )
            writer.writerow(
                _make_stop_experiment_row(
                    data=baseline,
                    ts=_utc_now_iso(),
                    elapsed_s=0.05,
                    experiment_id=experiment_id,
                    device_name=name_filter or "dry-run",
                    device_address=address or "dry-run",
                    notification_index=1,
                    gap_since_previous_s=None,
                    writes_count=1,
                    blocked_writes_count=0,
                    plan=plan,
                    event="command_sent",
                    baseline_speed_raw_tenths=30,
                    baseline_state=1,
                    freshness_s=0.0,
                    confirmed_stop=False,
                    outcome="",
                )
            )
            writer.writerow(
                _make_stop_experiment_row(
                    data=after,
                    ts=_utc_now_iso(),
                    elapsed_s=0.1,
                    experiment_id=experiment_id,
                    device_name=name_filter or "dry-run",
                    device_address=address or "dry-run",
                    notification_index=2,
                    gap_since_previous_s=0.1,
                    writes_count=1,
                    blocked_writes_count=0,
                    plan=plan,
                    event="notify_fe01",
                    baseline_speed_raw_tenths=30,
                    baseline_state=1,
                    freshness_s=0.0,
                    confirmed_stop=False,
                    outcome="",
                )
            )
            writer.writerow(
                _make_stop_experiment_row(
                    data=after,
                    ts=_utc_now_iso(),
                    elapsed_s=duration,
                    experiment_id=experiment_id,
                    device_name=name_filter or "dry-run",
                    device_address=address or "dry-run",
                    notification_index=2,
                    gap_since_previous_s=None,
                    writes_count=1,
                    blocked_writes_count=0,
                    plan=plan,
                    event="summary",
                    baseline_speed_raw_tenths=30,
                    baseline_state=1,
                    freshness_s=0.1,
                    confirmed_stop=_is_stop_confirmed(latest_after),
                    outcome=outcome,
                )
            )
        print(f"mode={STOP_EXPERIMENT_MODE}")
        print(f"dry_run_sample=true")
        print(f"variant={plan.variant}")
        print(f"command_packet={_hex(plan.packets[0])}")
        print(f"csv_path={csv_path}")
        print("writes_count=1")
        print("blocked_writes_count=0")
        print("notifications_count=2")
        print(f"outcome={outcome}")
        print(f"experiment_id={experiment_id}")
        return

    resolved, resolved_name = await _resolve_device(address, name_filter)
    device_name = resolved_name or name_filter or ""
    guard = WhitelistedWriteGuard(set(plan.packets))
    notifications_count = 0
    previous_monotonic: Optional[float] = None
    latest_data: Optional[bytes] = None
    latest_parsed: Optional[dict] = None
    latest_monotonic: Optional[float] = None
    latest_after_command: Optional[dict] = None
    latest_after_command_monotonic: Optional[float] = None
    max_after_command_speed: Optional[int] = None
    baseline_data: Optional[bytes] = None
    baseline_parsed: Optional[dict] = None
    command_sent = False
    started_monotonic = time.monotonic()

    print("Using address:", resolved)
    print(f"Stop experiment id: {experiment_id}")
    print(f"Variant: {plan.variant}")
    print("Safety: no-load confirmed, power switch ready, operator present.")

    with open(csv_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=STOP_EXPERIMENT_CSV_FIELDS)
        writer.writeheader()

        def write_row(data: bytes, event: str, outcome: str = "") -> None:
            nonlocal notifications_count
            now = time.monotonic()
            parsed = _parse_fe01_observation(data)
            baseline_speed = _int_or_none(baseline_parsed.get("speed_raw_tenths")) if baseline_parsed else None
            baseline_state = _int_or_none(baseline_parsed.get("state")) if baseline_parsed else None
            freshness = None if latest_monotonic is None else now - latest_monotonic
            row = _make_stop_experiment_row(
                data=data,
                ts=_utc_now_iso(),
                elapsed_s=now - started_monotonic,
                experiment_id=experiment_id,
                device_name=device_name,
                device_address=resolved,
                notification_index=notifications_count,
                gap_since_previous_s=None if previous_monotonic is None else now - previous_monotonic,
                writes_count=guard.writes_count,
                blocked_writes_count=guard.blocked_writes_count,
                plan=plan,
                event=event,
                baseline_speed_raw_tenths=baseline_speed,
                baseline_state=baseline_state,
                freshness_s=freshness,
                confirmed_stop=_is_stop_confirmed(parsed),
                outcome=outcome,
            )
            writer.writerow(row)
            handle.flush()

        def on_notify(sender: int, data: bytearray) -> None:
            nonlocal notifications_count, previous_monotonic, latest_data, latest_parsed, latest_monotonic
            nonlocal latest_after_command, latest_after_command_monotonic, max_after_command_speed
            now = time.monotonic()
            notifications_count += 1
            latest_data = bytes(data)
            latest_parsed = _parse_fe01_observation(latest_data)
            latest_monotonic = now
            if command_sent:
                latest_after_command = latest_parsed
                latest_after_command_monotonic = now
                speed = _int_or_none(latest_parsed.get("speed_raw_tenths"))
                if speed is not None:
                    max_after_command_speed = speed if max_after_command_speed is None else max(max_after_command_speed, speed)

            gap = None if previous_monotonic is None else now - previous_monotonic
            previous_monotonic = now
            baseline_speed = _int_or_none(baseline_parsed.get("speed_raw_tenths")) if baseline_parsed else None
            baseline_state = _int_or_none(baseline_parsed.get("state")) if baseline_parsed else None
            freshness = 0.0
            row = _make_stop_experiment_row(
                data=latest_data,
                ts=_utc_now_iso(),
                elapsed_s=now - started_monotonic,
                experiment_id=experiment_id,
                device_name=device_name,
                device_address=resolved,
                notification_index=notifications_count,
                gap_since_previous_s=gap,
                writes_count=guard.writes_count,
                blocked_writes_count=guard.blocked_writes_count,
                plan=plan,
                event="notify_fe01",
                baseline_speed_raw_tenths=baseline_speed,
                baseline_state=baseline_state,
                freshness_s=freshness,
                confirmed_stop=_is_stop_confirmed(latest_parsed),
                outcome="",
            )
            writer.writerow(row)
            handle.flush()
            print(
                "[STOP EXPERIMENT] "
                f"#{notifications_count} state={row['state']} "
                f"speed_raw={row['speed_raw_tenths']} "
                f"app_raw={row['app_speed_raw_tenths']} "
                f"mode={row['mode']} button={row['button']} "
                f"writes={guard.writes_count} checksum={row['checksum_ok']}"
            )

        async with BleakClient(resolved) as client:
            print("Connected:", client.is_connected)
            guard.install(client)
            await client.start_notify(CHAR_NOTIFY_FE01, on_notify)

            baseline_deadline = time.monotonic() + baseline_timeout
            baseline_error = "NO_FRESH_FE01"
            while time.monotonic() < baseline_deadline:
                if latest_parsed is not None and latest_monotonic is not None:
                    freshness = time.monotonic() - latest_monotonic
                    baseline_error = _stop_experiment_baseline_error(latest_parsed, freshness)
                    if baseline_error is None:
                        baseline_data = latest_data
                        baseline_parsed = dict(latest_parsed)
                        write_row(baseline_data or latest_data or _build_sample_fe01_frame(), "baseline_ready")
                        break
                await asyncio.sleep(0.1)

            if baseline_parsed is None:
                fallback = latest_data or _build_sample_fe01_frame()
                write_row(fallback, "summary", "NO_FRESH_FE01")
                await client.stop_notify(CHAR_NOTIFY_FE01)
                print(f"mode={STOP_EXPERIMENT_MODE}")
                print(f"variant={plan.variant}")
                print(f"command_packet={_hex(plan.packets[0])}")
                print(f"csv_path={csv_path}")
                print(f"writes_count={guard.writes_count}")
                print(f"blocked_writes_count={guard.blocked_writes_count}")
                print(f"notifications_count={notifications_count}")
                print("outcome=NO_FRESH_FE01")
                print(f"baseline_error={baseline_error}")
                print(f"experiment_id={experiment_id}")
                return

            await client.write_gatt_char(CHAR_WRITE_FE02, plan.packets[0], response=False)
            command_sent = True
            write_row(baseline_data or latest_data or _build_sample_fe01_frame(), "command_sent")
            print(f"[STOP EXPERIMENT WRITE] FE02 <= {_hex(plan.packets[0])}")

            observe_deadline = time.monotonic() + duration
            baseline_speed = _int_or_none(baseline_parsed.get("speed_raw_tenths")) or 0
            while time.monotonic() < observe_deadline:
                if (
                    plan.variant == "toggle-only"
                    and max_after_command_speed is not None
                    and max_after_command_speed > baseline_speed + STOP_EXPERIMENT_ACCELERATION_MARGIN_RAW_TENTHS
                ):
                    print("[STOP EXPERIMENT] aborting observation: command caused acceleration")
                    break
                await asyncio.sleep(0.2)

            latest_freshness = (
                STOP_EXPERIMENT_BASELINE_FRESHNESS_SECONDS + 1.0
                if latest_after_command_monotonic is None
                else time.monotonic() - latest_after_command_monotonic
            )
            outcome = _classify_stop_experiment_outcome(
                baseline_speed_raw_tenths=baseline_speed,
                latest_after_command=latest_after_command,
                latest_freshness_s=latest_freshness,
                max_after_command_speed_raw_tenths=max_after_command_speed,
            )
            summary_data = latest_data or baseline_data or _build_sample_fe01_frame()
            write_row(summary_data, "summary", outcome)
            await client.stop_notify(CHAR_NOTIFY_FE01)

    print(f"mode={STOP_EXPERIMENT_MODE}")
    print(f"variant={plan.variant}")
    print(f"command_packet={_hex(plan.packets[0])}")
    print(f"csv_path={csv_path}")
    print(f"device_name={device_name}")
    print(f"device_address={resolved}")
    print(f"writes_count={guard.writes_count}")
    print(f"blocked_writes_count={guard.blocked_writes_count}")
    print(f"notifications_count={notifications_count}")
    print(f"outcome={outcome}")
    print(f"experiment_id={experiment_id}")


async def write_hex(address: Optional[str], hex_payload: str, name_filter: Optional[str]) -> None:
    payload = bytes.fromhex(hex_payload)
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        await client.write_gatt_char(CHAR_WRITE_FE02, payload, response=False)
        print(f"[WRITE] FE02 <= {_hex(payload)}")


async def dump(address: Optional[str], duration: float, subscribe_all: bool, name_filter: Optional[str]) -> None:
    notifications_started = []

    def make_cb(label: str):
        def on_notify(sender: int, data: bytearray) -> None:
            print(f"[NOTIFY] {label} sender={sender} data={_hex(bytes(data))}")
        return on_notify

    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        services = await _get_client_services(client)
        for s in services:
            print("Service:", s.uuid)
            for c in s.characteristics:
                props = ",".join(c.properties)
                print(f"  Char: {c.uuid} [{props}]")
                if "read" in c.properties:
                    try:
                        value = await client.read_gatt_char(c.uuid)
                        print(f"    Read: {_hex(value)}")
                    except Exception as exc:
                        print(f"    Read error: {exc}")
                if subscribe_all and ("notify" in c.properties or "indicate" in c.properties):
                    try:
                        await client.start_notify(c.uuid, make_cb(c.uuid))
                        notifications_started.append(c.uuid)
                        print("    Notify: subscribed")
                    except Exception as exc:
                        print(f"    Notify error: {exc}")

        if subscribe_all and notifications_started:
            print(f"Listening for notifications for {duration} seconds...")
            await asyncio.sleep(duration)
            for uuid in notifications_started:
                try:
                    await client.stop_notify(uuid)
                except Exception as exc:
                    print(f"Stop notify error for {uuid}: {exc}")


async def ask_stats(address: Optional[str], duration: float, name_filter: Optional[str]) -> None:
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)

    async def on_notify(sender: int, data: bytearray) -> None:
        parsed = _parse_status(bytes(data))
        if parsed:
            print(f"[NOTIFY] {parsed}")
        else:
            print(f"[NOTIFY] sender={sender} data={_hex(bytes(data))}")

    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        await client.start_notify(CHAR_NOTIFY_FE01, on_notify)

        cmd = bytearray([0xF7, 0xA2, 0x00, 0x00, 0xFF, 0xFD])
        _fix_crc(cmd)
        await client.write_gatt_char(CHAR_WRITE_FE02, cmd, response=False)
        print(f"[WRITE] FE02 <= {_hex(bytes(cmd))}")

        await asyncio.sleep(duration)
        await client.stop_notify(CHAR_NOTIFY_FE01)


async def control(address: Optional[str], action: str, value: Optional[int], name_filter: Optional[str]) -> None:
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)

    if action == "start":
        cmd = bytearray([0xF7, 0xA2, 0x04, 0x01, 0xFF, 0xFD])
    elif action == "stop":
        cmd = bytearray([0xF7, 0xA2, 0x01, 0x00, 0xFF, 0xFD])
    elif action == "speed":
        if value is None:
            raise ValueError("speed requires --value (speed*10, e.g. 20 for 2.0 km/h)")
        cmd = bytearray([0xF7, 0xA2, 0x01, value, 0xFF, 0xFD])
    elif action == "mode":
        if value is None:
            raise ValueError("mode requires --value (0=auto,1=manual,2=standby)")
        cmd = bytearray([0xF7, 0xA2, 0x02, value, 0xFF, 0xFD])
    else:
        raise ValueError(f"Unknown action: {action}")

    _fix_crc(cmd)

    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        await client.write_gatt_char(CHAR_WRITE_FE02, cmd, response=False)
        print(f"[WRITE] FE02 <= {_hex(bytes(cmd))}")


async def write_raw(address: Optional[str], char_uuid: str, hex_payload: str, name_filter: Optional[str]) -> None:
    payload = _from_hex(hex_payload)
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        await client.write_gatt_char(char_uuid, payload, response=False)
        print(f"[WRITE] {char_uuid} <= {_hex(payload)}")


async def sequence(
    address: Optional[str],
    char_uuid: str,
    payloads: list[str],
    delay: float,
    name_filter: Optional[str],
    notify: bool,
) -> None:
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)

    def on_notify(sender: int, data: bytearray) -> None:
        parsed = _parse_status(bytes(data))
        if parsed:
            print(f"[NOTIFY] {parsed}")
        else:
            print(f"[NOTIFY] sender={sender} data={_hex(bytes(data))}")

    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        if notify:
            await client.start_notify(CHAR_NOTIFY_FE01, on_notify)

        for payload in payloads:
            data = _from_hex(payload)
            await client.write_gatt_char(char_uuid, data, response=False)
            print(f"[WRITE] {char_uuid} <= {_hex(data)}")
            await asyncio.sleep(delay)

        if notify:
            await asyncio.sleep(max(0.5, delay))
            await client.stop_notify(CHAR_NOTIFY_FE01)


def main() -> None:
    parser = argparse.ArgumentParser(description="BLE helper for KS-F0")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_scan = sub.add_parser("scan", help="Scan nearby BLE devices")
    p_scan.add_argument("--timeout", type=float, default=8.0)
    p_scan.add_argument("--name", type=str, default=None)

    p_list = sub.add_parser("list", help="List services/characteristics")
    p_list.add_argument("address", type=str, nargs="?")
    p_list.add_argument("--name", type=str, default=None)

    p_listen = sub.add_parser("listen", help="Subscribe to FE01 notify")
    p_listen.add_argument("address", type=str, nargs="?")
    p_listen.add_argument("--duration", type=float, default=20.0)
    p_listen.add_argument("--name", type=str, default=None)

    p_observe = sub.add_parser("observe-fe01", help="Passive FE01 observer with CSV export and zero-write guard")
    p_observe.add_argument("address", type=str, nargs="?")
    p_observe.add_argument("--duration", type=float, default=60.0)
    p_observe.add_argument("--name", type=str, default=None)
    p_observe.add_argument("--csv", required=True, dest="csv_path")
    p_observe.add_argument("--dry-run-sample", action="store_true")

    p_observe_all = sub.add_parser("observe-all-notify", help="Passive observer for every notify/indicate characteristic")
    p_observe_all.add_argument("address", type=str, nargs="?")
    p_observe_all.add_argument("--duration", type=float, default=60.0)
    p_observe_all.add_argument("--name", type=str, default=None)
    p_observe_all.add_argument("--csv", required=True, dest="csv_path")
    p_observe_all.add_argument("--dry-run-sample", action="store_true")

    p_doctor = sub.add_parser("doctor", help="Read-only BLE environment and WalkingPad service preflight")
    p_doctor.add_argument("address", type=str, nargs="?")
    p_doctor.add_argument("--name", type=str, default=None)
    p_doctor.add_argument("--dry-run-sample", action="store_true")

    p_dump_services = sub.add_parser("dump-services", help="Read-only BLE service/characteristic dump")
    p_dump_services.add_argument("address", type=str, nargs="?")
    p_dump_services.add_argument("--name", type=str, default=None)
    p_dump_services.add_argument("--dry-run-sample", action="store_true")

    p_stop_exp = sub.add_parser(
        "stop-experiment",
        help="Run a whitelisted no-load stop experiment with FE01 CSV timeline",
    )
    p_stop_exp.add_argument("address", type=str, nargs="?")
    p_stop_exp.add_argument("--variant", choices=sorted(STOP_EXPERIMENT_VARIANTS), required=True)
    p_stop_exp.add_argument("--duration", type=float, default=60.0)
    p_stop_exp.add_argument("--baseline-timeout", type=float, default=20.0)
    p_stop_exp.add_argument("--name", type=str, default=None)
    p_stop_exp.add_argument("--csv", required=True, dest="csv_path")
    p_stop_exp.add_argument("--confirm-no-load", action="store_true")
    p_stop_exp.add_argument("--confirm-power-switch-ready", action="store_true")
    p_stop_exp.add_argument("--confirm-operator-present", action="store_true")
    p_stop_exp.add_argument("--dry-run-sample", action="store_true")

    p_write = sub.add_parser("write", help="Write hex payload to FE02")
    p_write.add_argument("address", type=str, nargs="?")
    p_write.add_argument("hex_payload", type=str)
    p_write.add_argument("--name", type=str, default=None)

    p_dump = sub.add_parser("dump", help="Dump services, readables, and notifications")
    p_dump.add_argument("address", type=str, nargs="?")
    p_dump.add_argument("--duration", type=float, default=20.0)
    p_dump.add_argument("--no-notify", action="store_true")
    p_dump.add_argument("--name", type=str, default=None)

    p_stats = sub.add_parser("stats", help="Send ask_stats and parse notifications")
    p_stats.add_argument("address", type=str, nargs="?")
    p_stats.add_argument("--duration", type=float, default=5.0)
    p_stats.add_argument("--name", type=str, default=None)

    p_ctl = sub.add_parser("ctl", help="Control: start/stop/speed/mode")
    p_ctl.add_argument("action", type=str, choices=["start", "stop", "speed", "mode"])
    p_ctl.add_argument("--value", type=int, default=None)
    p_ctl.add_argument("address", type=str, nargs="?")
    p_ctl.add_argument("--name", type=str, default=None)

    p_raw = sub.add_parser("raw", help="Write raw hex to a characteristic")
    p_raw.add_argument("char_uuid", type=str, choices=[CHAR_FFC1, CHAR_FFC2, CHAR_WRITE_FE02])
    p_raw.add_argument("hex_payload", type=str)
    p_raw.add_argument("address", type=str, nargs="?")
    p_raw.add_argument("--name", type=str, default=None)

    p_seq = sub.add_parser("seq", help="Send a sequence of raw hex payloads in one session")
    p_seq.add_argument("payloads", type=str, nargs="+")
    p_seq.add_argument("--char", type=str, default=CHAR_WRITE_FE02)
    p_seq.add_argument("--delay", type=float, default=1.0)
    p_seq.add_argument("--notify", action="store_true")
    p_seq.add_argument("address", type=str, nargs="?")
    p_seq.add_argument("--name", type=str, default=None)

    args = parser.parse_args()

    if args.cmd == "scan":
        asyncio.run(scan(args.timeout, args.name))
    elif args.cmd == "list":
        asyncio.run(connect_and_list(args.address, args.name))
    elif args.cmd == "listen":
        asyncio.run(listen(args.address, args.duration, args.name))
    elif args.cmd == "observe-fe01":
        asyncio.run(observe_fe01(args.address, args.duration, args.name, args.csv_path, args.dry_run_sample))
    elif args.cmd == "observe-all-notify":
        asyncio.run(observe_all_notify(args.address, args.duration, args.name, args.csv_path, args.dry_run_sample))
    elif args.cmd == "doctor":
        asyncio.run(ble_doctor(args.address, args.name, args.dry_run_sample))
    elif args.cmd == "dump-services":
        asyncio.run(dump_services(args.address, args.name, args.dry_run_sample))
    elif args.cmd == "stop-experiment":
        missing = _missing_stop_experiment_confirmations(
            args.confirm_no_load,
            args.confirm_power_switch_ready,
            args.confirm_operator_present,
        )
        if missing:
            parser.error(f"stop-experiment refused: missing safety confirmations: {', '.join(missing)}")
        asyncio.run(
            stop_experiment(
                args.address,
                args.variant,
                args.duration,
                args.name,
                args.csv_path,
                args.confirm_no_load,
                args.confirm_power_switch_ready,
                args.confirm_operator_present,
                args.dry_run_sample,
                args.baseline_timeout,
            )
        )
    elif args.cmd == "write":
        asyncio.run(write_hex(args.address, args.hex_payload, args.name))
    elif args.cmd == "dump":
        asyncio.run(dump(args.address, args.duration, not args.no_notify, args.name))
    elif args.cmd == "stats":
        asyncio.run(ask_stats(args.address, args.duration, args.name))
    elif args.cmd == "ctl":
        asyncio.run(control(args.address, args.action, args.value, args.name))
    elif args.cmd == "raw":
        asyncio.run(write_raw(args.address, args.char_uuid, args.hex_payload, args.name))
    elif args.cmd == "seq":
        asyncio.run(sequence(args.address, args.char, args.payloads, args.delay, args.name, args.notify))


if __name__ == "__main__":
    main()
