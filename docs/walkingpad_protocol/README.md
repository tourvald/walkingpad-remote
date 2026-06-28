# WalkingPad / KingSmith Protocol Knowledge Base

This directory is the working source of truth for protocol decisions. Raw research remains in
`docs/research/`; the files here normalize that research into product rules, risk status, and
implementation references.

## Current Working Conclusions

### Confirmed

| Topic | Conclusion | Source | Where to read |
| --- | --- | --- | --- |
| Legacy WalkingPad transport | Legacy controllers use service `FE00`, notify `FE01`, write `FE02`, and packet framing around `F7`/`F8` plus checksum. | Raw research, current app codec | [legacy_fe00_protocol.md](legacy_fe00_protocol.md) |
| Read-only controller params | `queryParams` write packet is `F7 A6 00 00 00 00 00 A6 FD`. | `BLETransportCodec.swift`, raw research | [legacy_fe00_protocol.md](legacy_fe00_protocol.md) |
| Unit preference byte | `queryParams.unit` maps `0=metric`, `1=imperial`; other values are unknown. | `BLETransportCodec.swift`, raw research | [units_and_setunit.md](units_and_setunit.md) |
| P0 units safety rule | HR-control is allowed only for metric units read from valid `queryParams` with checksum/parse OK. | `STATUS.md`, current app policy | [units_and_setunit.md](units_and_setunit.md) |
| Imperial diagnostic flow | Imperial Debug Test Run is diagnostic-only, no-load, explicit confirmation, `rawTenths=30`, `60s`. | `STATUS.md`, current app code | [units_and_setunit.md](units_and_setunit.md), [ks_f0_case_notes.md](ks_f0_case_notes.md) |
| Legacy stop command | Standard legacy stop writes speed raw zero: `F7 A2 01 00 A3 FD`. | Raw research, `BLETransportCodec.swift` | [stop_behavior.md](stop_behavior.md) |
| OTA surface exists | KingSmith / KS Fit reverse notes expose OTA-related code paths. | Raw research | [firmware_ota.md](firmware_ota.md) |
| FTMS support surface | Newer devices can expose FTMS `0x1826` with control point and treadmill data characteristics. | Raw research, current app codec | [ftms_and_newer_devices.md](ftms_and_newer_devices.md) |

### Probable

| Topic | Working Hypothesis | Confidence | Where to read |
| --- | --- | --- | --- |
| Legacy `setUnit` packets | `A6 key 8` packets likely set metric/imperial preference. | Medium-high packet confidence, low production-safety confidence | [units_and_setunit.md](units_and_setunit.md) |
| `setUnit` persistence | Unit preference probably persists on at least some controllers. | Medium-low; not proven across models | [units_and_setunit.md](units_and_setunit.md) |
| Protocol-level rollback | Sending the opposite `setUnit` packet probably changes preference back. | Medium-low; not a safe recovery plan | [units_and_setunit.md](units_and_setunit.md) |
| Standby after stop | Legacy standby can help stop/park some controllers after speed zero. | Medium; assist only | [stop_behavior.md](stop_behavior.md) |

### Unknown / Not Proven

| Topic | Unknown | Product Rule | Where to read |
| --- | --- | --- | --- |
| Physical command semantics globally | Whether legacy speed command raw tenths always mean km/h, mph, or native units across all controllers. | Do not auto-convert or unlock imperial HR-control. | [units_and_setunit.md](units_and_setunit.md) |
| KS-F0 stop root cause | Why the affected treadmill does not reliably confirm stop. | Keep in stop-forensics scope. | [ks_f0_case_notes.md](ks_f0_case_notes.md), [stop_behavior.md](stop_behavior.md) |
| Firmware recovery / rollback | Safe public firmware image, compatibility matrix, and rollback process. | Firmware flashing is forbidden. | [firmware_ota.md](firmware_ota.md) |
| Service menu writes | Public reliable mapping for F1/F2/F3/F4/F5 or similar service writes. | Service-menu writes are forbidden. | [forbidden_actions.md](forbidden_actions.md) |

## Risk Status Legend

| Status | Meaning |
| --- | --- |
| `allowed` | Safe for normal product use in the current app. |
| `diagnostic-only` | Allowed only in a controlled diagnostic flow with explicit operator confirmation and no person on the treadmill when applicable. |
| `forbidden` | Do not implement or execute in production or test builds without a separate safety review. |
| `unknown` | Not enough evidence; treat as blocked for automatic behavior. |

## File Index

| File | Purpose |
| --- | --- |
| [legacy_fe00_protocol.md](legacy_fe00_protocol.md) | Legacy `FE00` transport, frame format, checksum, commands, params, and status frames. |
| [units_and_setunit.md](units_and_setunit.md) | Units detection, `setUnit` packets, current safety gates, and command-semantics limits. |
| [stop_behavior.md](stop_behavior.md) | Stop command model, standby assist, telemetry-based verification, and KS-F0 stop boundaries. |
| [firmware_ota.md](firmware_ota.md) | Firmware / OTA evidence, safe read-only Device Information characteristics, forbidden actions. |
| [ftms_and_newer_devices.md](ftms_and_newer_devices.md) | FTMS and newer KingSmith device protocol surfaces. |
| [ks_f0_case_notes.md](ks_f0_case_notes.md) | Local affected treadmill notes and what must not be generalized. |
| [source_inventory.md](source_inventory.md) | Unified source table with confidence and related docs. |
| [forbidden_actions.md](forbidden_actions.md) | Central list of blocked protocol actions. |

## Raw Research Inputs

- [../research/walkingpad_protocol_research.md](../research/walkingpad_protocol_research.md)
- [../research/walkingpad_setunit_firmware_deep_research.md](../research/walkingpad_setunit_firmware_deep_research.md)
- `STATUS.md`
- Current code references: `BLETransportCodec.swift`, `BluetoothManager.swift`, `TrainingTelemetryWriter.swift`,
  `tools/analyze_training_log.py`

## Missing Input Note

`docs/ks-f0-incident.md` was requested as an input, but it is not present in the current working tree as of
2026-06-28. KS-F0-specific notes in this directory are therefore based on `STATUS.md`, raw research, current
telemetry/analyzer behavior, and local operator observations.
