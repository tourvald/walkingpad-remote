# Forbidden and Restricted Actions

This is the central risk register for WalkingPad / KingSmith protocol work. If an action is not listed as
`allowed`, treat it as blocked until a separate design/safety review changes the status.

## Central Action Table

| Action | Status | Reason | Related Docs |
| --- | --- | --- | --- |
| Read legacy `queryParams` | `allowed` | Read-only controller state needed for safety gating. | [legacy_fe00_protocol.md](legacy_fe00_protocol.md), [units_and_setunit.md](units_and_setunit.md) |
| Read standard Device Information characteristics | `allowed` | Read-only model/firmware evidence. | [firmware_ota.md](firmware_ota.md) |
| HR-control on metric with valid `queryParams` checksum/parse OK | `allowed` | Current product safety rule. | [units_and_setunit.md](units_and_setunit.md) |
| Imperial no-load diagnostic profile | `diagnostic-only` | Requires explicit no-load confirmation; evidence collection only. | [units_and_setunit.md](units_and_setunit.md), [ks_f0_case_notes.md](ks_f0_case_notes.md) |
| Store operator visual physical-semantics confirmation | `allowed` | Per-device fingerprint; required before any imperial training path. | [ks_f0_case_notes.md](ks_f0_case_notes.md) |
| HR-control on confirmedImperial with session manual-stop acknowledgement | `restricted allowed` | Only for the matching treadmill fingerprint; first build caps physical speed at `6.0 km/h`; app STOP remains best-effort. | [units_and_setunit.md](units_and_setunit.md), [ks_f0_case_notes.md](ks_f0_case_notes.md) |
| Production `setUnit` write | `forbidden` | Persistence, side effects, and recovery are not proven. | [units_and_setunit.md](units_and_setunit.md) |
| Auto-switch units through `0xA6 key 8` | `forbidden` | Same as `setUnit`; not production-safe. | [units_and_setunit.md](units_and_setunit.md) |
| Service-menu writes | `forbidden` | Reliable mapping and safety effects are unknown. | [legacy_fe00_protocol.md](legacy_fe00_protocol.md) |
| Firmware / OTA writes | `forbidden` | No safe public firmware path, rollback, or brick recovery. | [firmware_ota.md](firmware_ota.md) |
| Enter OTA mode | `forbidden` | Side effects and recovery unknown. | [firmware_ota.md](firmware_ota.md) |
| Replay unknown KS Fit writes | `forbidden` | Hidden model/firmware assumptions and side effects. | [ftms_and_newer_devices.md](ftms_and_newer_devices.md), [firmware_ota.md](firmware_ota.md) |
| HR-control on unconfirmed imperial | `forbidden` | Physical command semantics are not proven for that treadmill. | [units_and_setunit.md](units_and_setunit.md), [ks_f0_case_notes.md](ks_f0_case_notes.md) |
| Automatic mph/kmh command conversion for unconfirmed imperial | `forbidden` | Would create safety-critical speed changes without per-treadmill proof. | [units_and_setunit.md](units_and_setunit.md) |
| Manual override that bypasses imperial HR-control gate | `forbidden` | Converts unresolved safety state into user-facing control risk. | [units_and_setunit.md](units_and_setunit.md) |
| Loaded treadmill experiments while units/stop unresolved | `forbidden` | User safety risk. | [ks_f0_case_notes.md](ks_f0_case_notes.md), [stop_behavior.md](stop_behavior.md) |
| Infer physical mph/kmh from device raw distance alone | `forbidden` | Raw distance unit semantics are unknown. | [units_and_setunit.md](units_and_setunit.md) |
| Treat BLE write success as physical stop success | `forbidden` | Stop must be verified by telemetry/observation. | [stop_behavior.md](stop_behavior.md) |
| Generalize KS-F0 evidence to all models | `forbidden` | Local treadmill evidence is model/device-specific. | [ks_f0_case_notes.md](ks_f0_case_notes.md) |

## Exact Packets That Must Not Be Written in Production

```text
F7 A6 08 00 00 00 00 AE FD   # set metric units
F7 A6 08 00 00 00 01 AF FD   # set imperial units
```

These packets are useful protocol knowledge, not approved product behavior.

## Safe Default

When a controller state is unknown, invalid, or mismatched:

1. Show the user a clear warning.
2. Block automatic HR speed control.
3. Keep diagnostic actions no-load and explicit.
4. Preserve raw telemetry for analysis.
5. Do not mutate controller preferences, firmware, or service-menu state.
