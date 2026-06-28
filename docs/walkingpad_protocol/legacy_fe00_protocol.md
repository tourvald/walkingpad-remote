# Legacy FE00 WalkingPad Protocol

This document covers the legacy WalkingPad / KingSmith protocol family used by controllers that expose the
`FE00` service. It is separate from FTMS devices; see [ftms_and_newer_devices.md](ftms_and_newer_devices.md).

## BLE Surface

| Item | UUID | Direction | Current Interpretation | Source |
| --- | --- | --- | --- | --- |
| Service | `FE00` | central discovers peripheral service | Legacy WalkingPad transport service. | raw research, current app code |
| Notify characteristic | `FE01` | treadmill -> app | Status / telemetry notifications. | raw research, current app code |
| Write characteristic | `FE02` | app -> treadmill | Commands and read-only param queries. | raw research, current app code |

Current app routing selects this protocol when `FE00` is discovered. Source: `BluetoothManager.swift`.

## Frame Format

### App-to-device command frames

Most legacy writes are framed as:

```text
F7 <op> <cmd/key> <value bytes...> <checksum> FD
```

Known examples:

```text
F7 A2 01 00 A3 FD              # speed raw zero / stop
F7 A6 00 00 00 00 00 A6 FD     # queryParams
```

### Device-to-app response frames

Controller parameter responses are parsed as:

```text
F8 A6 <payload...> <checksum> FD
```

Current parser requires the `F8 A6` prefix and validates checksum when the response is `FD`-terminated.
Source: `BLETransportCodec.swift`.

## Checksum

The legacy checksum used by the current codec is the byte sum modulo 256 over the command bytes after the
leading frame marker and before checksum.

Examples:

| Packet | Checksum Reasoning | Source |
| --- | --- | --- |
| `F7 A6 00 00 00 00 00 A6 FD` | `A6 + 00 + 00 + 00 + 00 + 00 = A6` | current app codec |
| `F7 A2 01 00 A3 FD` | `A2 + 01 + 00 = A3` | current app codec |
| `F7 A6 08 00 00 00 01 AF FD` | `A6 + 08 + 00 + 00 + 00 + 01 = AF` | raw research |

## `A2` Commands

`A2` is the legacy command operation family used by the app for start/stop/speed/mode style commands.

| Action | Packet / Encoding | Status | Notes | Source |
| --- | --- | --- | --- | --- |
| Set speed / stop | `F7 A2 01 <rawTenths> <checksum> FD` | `allowed` for metric; `diagnostic-only` for imperial no-load diagnostic | `rawTenths=0` is the standard stop packet. Non-zero speed writes are safety-gated by unit policy. | `BLETransportCodec.swift`, raw research |
| Stop | `F7 A2 01 00 A3 FD` | `allowed` | Write success is not stop success; verify with telemetry. | current app code, raw research |
| Start / toggle | `F7 A2 04 01 A7 FD` | `allowed` in existing controlled flows | Used by existing start sequence. | current app code |
| Manual mode | `F7 A2 02 01 A5 FD` | `allowed` in existing controlled flows | Sent before some start/speed sequences. | current app code |
| Standby / assist | `F7 A2 02 02 A6 FD` | `diagnostic-only` / assist inside stop sequence | Use after speed-zero stop attempt, not blindly as first or only stop. | raw research, current app code |

## `A6` Params / Preferences

`A6` is the legacy parameter/preference operation family. Read-only `queryParams` is supported by the current
app. Write-style preference packets exist in research but are not production-safe.

| Action | Packet / Encoding | Status | Notes | Source |
| --- | --- | --- | --- | --- |
| Query controller params | `F7 A6 00 00 00 00 00 A6 FD` | `allowed` | Read-only. Used to detect controller unit preference. | `BLETransportCodec.swift`, raw research |
| Set metric units | `F7 A6 08 00 00 00 00 AE FD` | `forbidden` | Packet confidence is medium-high; production safety is not proven. | raw research |
| Set imperial units | `F7 A6 08 00 00 00 01 AF FD` | `forbidden` | Packet confidence is medium-high; production safety is not proven. | raw research |
| Unknown service-menu writes | unknown | `forbidden` | No reliable public mapping for service-menu behavior. | raw research |

## `queryParams`

Current app behavior:

1. Send `F7 A6 00 00 00 00 00 A6 FD` after WalkingPad connect.
2. Parse `F8 A6 ... FD` response.
3. Validate checksum/parse status.
4. Normalize `unit`:
   - `0` -> `metric`
   - `1` -> `imperial`
   - other -> `unknown`
5. Store raw response hex and unit source in treadmill units state.
6. Gate HR-control from this state.

Known fields currently used by the product:

| Field | Current App Meaning | Status | Source |
| --- | --- | --- | --- |
| `unit` | Controller unit preference: metric/imperial/unknown. | `allowed` read-only | `BLETransportCodec.swift` |
| raw response hex | Forensic source-of-truth for controller params. | `allowed` | `BluetoothManager.swift`, telemetry |
| checksum status | Required for trusting unit preference. | `allowed` | `BLETransportCodec.swift`, `STATUS.md` |
| max/start speed values | Parsed/recorded when available, but not the center of current safety policy. | `allowed` read-only | current app code |

## Status Frames on `FE01`

Current app parses WalkingPad notifications into status telemetry, including state, speed, app/controller speed,
mode, time, distance, steps, button, and checksum status.

Important current semantics:

| Status Field | Product Interpretation | Source |
| --- | --- | --- |
| `speed` | Device-reported speed snapshot; may lag target writes. | current app telemetry |
| `appSpeed` / controller target | Controller/app-reported target-like speed. Used in diagnostics, not as sole physical truth. | current app telemetry |
| `distance` | In imperial diagnostics this is raw evidence, not factual meters. | `STATUS.md`, telemetry/analyzer |
| `state` | Used as one signal for stop/running state, not enough alone to prove stop. | current app telemetry |

## Product Rule

Legacy `FE00` protocol facts are model-specific until proven otherwise. Read-only discovery is allowed; writes that
change controller preferences, service menu state, or firmware state are forbidden unless a separate safety review
explicitly approves them.
