import argparse
import asyncio
import csv
from datetime import datetime, timezone
import time
import uuid
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakBluetoothNotAvailableError, BleakError
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


def _hex(data: bytes) -> str:
    return data.hex(" ").upper()


def _ensure_bleak_available() -> None:
    if BleakClient is None or BleakScanner is None:
        raise RuntimeError("Python package 'bleak' is required for BLE access. Install it to use live BLE commands.")


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


async def _resolve_address(address: Optional[str], name_filter: Optional[str]) -> str:
    resolved, _ = await _resolve_device(address, name_filter)
    return resolved


async def connect_and_list(address: Optional[str], name_filter: Optional[str]) -> None:
    resolved = await _resolve_address(address, name_filter)
    print("Using address:", resolved)
    async with BleakClient(resolved) as client:
        print("Connected:", client.is_connected)
        services = None
        if hasattr(client, "get_services"):
            services = await client.get_services()
        else:
            services = client.services
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
        print(f"subscribed_char=FE01")
        print(f"csv_path={csv_path}")
        print(f"writes_count={guard.writes_count}")
        print(f"blocked_writes_count={guard.blocked_writes_count}")
        print("notifications_count=1")
        print(f"observation_id={observation_id}")
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

    print(f"mode={PASSIVE_OBSERVER_MODE}")
    print("subscribed_char=FE01")
    print(f"csv_path={csv_path}")
    print(f"device_name={device_name}")
    print(f"device_address={resolved}")
    print(f"writes_count={guard.writes_count}")
    print(f"blocked_writes_count={guard.blocked_writes_count}")
    print(f"notifications_count={notifications_count}")
    print(f"observation_id={observation_id}")


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
        if hasattr(client, "get_services"):
            services = await client.get_services()
        else:
            services = client.services
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
