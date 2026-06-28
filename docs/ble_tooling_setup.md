# BLE Tooling Setup

This document is the operational entry point for Mac-based WalkingPad BLE diagnostics.

## Environment

Use the project-local BLE environment, not random system Python:

```bash
./scripts/setup_ble_env.sh
```

The setup script creates `.venv-ble/` and installs `requirements-ble.txt`.
The pinned BLE stack is:

```text
bleak==3.0.2
```

Run all BLE diagnostics through:

```bash
./scripts/run_ble_tool.sh <command>
```

Python virtual environments are intentionally disposable and not checked into Git.

## macOS Bluetooth Permissions

Bleak uses Apple's CoreBluetooth backend on macOS. CoreBluetooth uses per-Mac UUIDs
instead of stable public Bluetooth MAC addresses, and macOS requires the calling app
or terminal to have Bluetooth permission.

If BLE commands fail before scanning or connecting:

1. Open `System Settings -> Privacy & Security -> Bluetooth`.
2. Allow Bluetooth for the terminal app used by Codex / shell.
3. If permission state is unclear, restart the terminal app and rerun `doctor`.

## Preflight

Run:

```bash
./scripts/run_ble_tool.sh doctor --name KS-F0
```

The doctor report should show:

```text
mode=ble_doctor
python_executable=...
python_version=...
bleak_version=3.0.2
bluetooth_state=on
device_found=true
connected=true
has_fe00=true
has_fe01_notify=true
has_fe02_write=true
```

If `device_found=false`, check that the treadmill is powered on and advertising.
If `connected=false`, disconnect the iPhone app / KS Fit and retry.

## Service Dump

Run:

```bash
./scripts/run_ble_tool.sh dump-services --name KS-F0
```

Expected legacy WalkingPad capabilities:

```text
has_fe00=true
has_fe01_notify=true
has_fe02_write=true
```

This command is read-only. It connects and lists services/characteristics; it does
not send `A2`, `A6`, `raw`, `seq`, `setUnit`, service-menu, or firmware commands.

## Passive FE01 Observation

Before any stop experiment, prove that FE01 notifications are flowing:

```bash
./scripts/run_ble_tool.sh observe-fe01 \
  --name KS-F0 \
  --duration 30 \
  --csv /tmp/fe01.csv
```

The summary always includes:

```text
subscribed_char=FE01
notify_started=true
notification_handler_invoked=true|false
writes_count=0
blocked_writes_count=0
notifications_count=N
```

If `notifications_count=0`, do not run `stop-experiment` yet. Check:

- treadmill may be stopped and not sending status;
- FE01 may not be the notifying characteristic for this device state;
- another central may already hold the active status stream;
- macOS Bluetooth permission may be blocked or stale;
- CoreBluetooth / Bleak may be in a bad adapter state.

## Passive FE01 Read Poll Fallback

If `observe-fe01` / `observe-all-notify` can connect but notifications stay at
zero, use the read-only FE01 polling fallback:

```bash
./scripts/run_ble_tool.sh poll-fe01-read \
  --name KS-F0 \
  --duration 30 \
  --interval 1 \
  --csv /tmp/poll_fe01.csv
```

This mode only calls `read_gatt_char(FE01)`. It installs the same passive write
guard as the notification observers, so accidental BLE writes fail and increment
`blocked_writes_count`.

Expected summary:

```text
mode=passive_fe01_read_poll
polled_char=FE01
reads_count=N
non_empty_reads_count=N
writes_count=0
blocked_writes_count=0
```

If `non_empty_reads_count=0`, FE01 reads are not a usable timeline source for the
current device/session. Do not run `stop-experiment`; use the iOS app telemetry
path or another BLE host that can receive status updates.

## Stop Experiment

Only after FE01 notifications are stable and the treadmill is moving no-load at low speed:

```bash
./scripts/run_ble_tool.sh stop-experiment \
  --variant speed-zero-only \
  --name KS-F0 \
  --duration 60 \
  --csv /tmp/stop_experiment_A.csv \
  --confirm-no-load \
  --confirm-power-switch-ready \
  --confirm-operator-present
```

If A does not stop the belt and produces a fresh outcome such as
`DECELERATED_BUT_NOT_ZERO` or `STATE_STILL_RUNNING`, run B:

```bash
./scripts/run_ble_tool.sh stop-experiment \
  --variant toggle-only \
  --name KS-F0 \
  --duration 60 \
  --csv /tmp/stop_experiment_B.csv \
  --confirm-no-load \
  --confirm-power-switch-ready \
  --confirm-operator-present
```

The runner refuses to write without a fresh low moving FE01 baseline.

## Analyze

```bash
./scripts/run_ble_tool.sh doctor --name KS-F0
python3 tools/analyze_training_log.py /tmp/stop_experiment_A.csv
```

`NO_FRESH_FE01` means the safety gate worked: no write was sent because the runner
could not prove a fresh moving baseline.

## Forbidden

Do not use these for stop recovery unless a separate design explicitly approves it:

- `scan_ble.py raw`
- `scan_ble.py seq`
- `F7 A2 03 07 AC FD`
- `setUnit` / `F7 A6 08 ...`
- service-menu writes
- firmware/OTA actions
- loaded treadmill experiments
