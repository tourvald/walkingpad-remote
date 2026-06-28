# Units, `queryParams.unit`, and `setUnit`

This document defines the current product rules for metric/imperial support and the known but forbidden `setUnit`
packets.

## Current Product Rule

| Situation | HR-control | Debug Test Run | Reason | Source |
| --- | --- | --- | --- | --- |
| `metric` from valid `queryParams` with checksum/parse OK | allowed | allowed | Controller unit preference matches current speed-command assumptions. | `STATUS.md`, current app policy |
| `imperial` from valid `queryParams` | blocked | diagnostic-only with explicit no-load confirmation | Physical speed command semantics are not globally proven. | `STATUS.md`, current app policy |
| `unknown` unit | blocked | blocked | Unit preference is not trustworthy. | `STATUS.md`, current app policy |
| parse/checksum failed | blocked | blocked | Source-of-truth params are invalid. | `STATUS.md`, current app policy |
| operator confirmed imperial physical semantics + matching fingerprint + session manual-stop acknowledgement | restricted allowed | diagnostic-only | Physical command semantics are known for this treadmill only; app STOP remains best-effort. | `STATUS.md`, current app policy |

## `queryParams.unit`

Read-only controller params are requested with:

```text
F7 A6 00 00 00 00 00 A6 FD
```

Normalized unit mapping:

| Raw Value | Normalized Unit | Status | Source |
| --- | --- | --- | --- |
| `0` | `metric` | `allowed` as source-of-truth when checksum/parse OK | `BLETransportCodec.swift`, raw research |
| `1` | `imperial` | `allowed` for warning/gating; HR-control blocked | `BLETransportCodec.swift`, raw research |
| other | `unknown` | `unknown`; block automatic speed control | `BLETransportCodec.swift`, `STATUS.md` |

The app stores raw params and checksum status because unit preference is a safety input, not a cosmetic label.

## Known `setUnit` Packets

Raw research found likely legacy unit-write packets:

```text
metric:   F7 A6 08 00 00 00 00 AE FD
imperial: F7 A6 08 00 00 00 01 AF FD
```

Interpretation:

| Packet | Meaning | Confidence | Status | Source |
| --- | --- | --- | --- | --- |
| `F7 A6 08 00 00 00 00 AE FD` | Set metric unit preference. | Medium-high packet confidence | `forbidden` | raw research from ph4/QWalkingPad-derived protocol notes |
| `F7 A6 08 00 00 00 01 AF FD` | Set imperial unit preference. | Medium-high packet confidence | `forbidden` | raw research from ph4/QWalkingPad-derived protocol notes |

Production-safety confidence is low because persistence, model coverage, side effects, and recovery behavior are
not proven across controllers.

## Persistence and Rollback

| Claim | Status | Confidence | Product Rule | Source |
| --- | --- | --- | --- | --- |
| `setUnit` probably persists controller preference | probable | medium-low | Do not rely on it in production. | raw research |
| Sending the opposite packet probably rolls back unit preference | probable | medium-low | Not a safe recovery plan. | raw research |
| No-brick recovery is known | unknown | low | Do not write unit preference. | raw research |

## Command Semantics

Speed command semantics are globally inconclusive.

Known facts:

- Legacy speed command uses `rawTenths`, for example `30` means native display value `3.0`.
- On metric controllers, current product assumptions treat this as `3.0 km/h`.
- On the affected KS-F0, local operator evidence supports that `rawTenths=30` behaves as native `3.0 mph`.
- This local evidence must not be generalized to all WalkingPad / KingSmith models.

Product rule:

| Action | Status | Reason |
| --- | --- | --- |
| Display `imperial` warning from valid `queryParams.unit=1` | `allowed` | Read-only and safety-positive. |
| Store operator-confirmed physical semantics per treadmill fingerprint | `allowed` | Evidence applies only to the matching treadmill fingerprint. |
| Imperial no-load discriminator profile `rawTenths=30`, 60s | `diagnostic-only` | Requires explicit no-load confirmation. |
| HR-control on unconfirmed imperial | `forbidden` | Physical command semantics are not proven for that treadmill. |
| HR-control on confirmedImperial | `restricted allowed` | Requires matching fingerprint, valid current params, session-only manual-stop acknowledgement, and first-build physical speed cap. |
| Automatic conversion for unconfirmed imperial | `forbidden` | Would create safety-critical speed changes without per-treadmill proof. |
| Physical km/h to native mph projection for confirmedImperial | `allowed` | Scoped to the confirmed treadmill only; preserves existing physical HR profiles. |
| Auto-switch units with `setUnit` | `forbidden` | Write side effects and recovery are not proven. |

## Imperial HR-Control Projection

For a matching `confirmedImperial` treadmill, HR-control keeps the calibrated
physical profile in `km/h` and projects commands into native imperial values:

```text
physicalKmh -> nativeMph -> rawTenths
```

Current safety constraints:

- valid current `queryParams` are required;
- stored fingerprint must match current peripheral/controller params;
- user must acknowledge manual-stop responsibility for the current session only;
- acknowledgement is not persisted in `UserDefaults`;
- initial requested physical speed cap is `6.0 km/h`;
- raw command resolution is `0.1 mph` (`~0.161 km/h`);
- if projection does not change `rawTenths`, no speed command should be sent;
- app STOP remains best-effort and must not be treated as solved stop safety.

## Telemetry Source-of-Truth Fields

Current telemetry should preserve raw and semantic unit evidence:

| Field | Meaning | Source |
| --- | --- | --- |
| `speed_unit_pref` | Controller unit preference from params, when available. | `TrainingTelemetryWriter.swift` |
| `units_source` | Source of units state, expected `queryParams` for trusted controller data. | current app telemetry |
| `controller_params_raw_hex` | Raw controller params response. | current app telemetry |
| `controller_params_checksum_ok` | Whether params checksum validated. | current app telemetry |
| `command_raw_tenths` | Raw speed command value, e.g. `30`. | current app telemetry |
| `command_native_units` | Native command unit context such as imperial/metric. | current app telemetry |
| `command_native_speed_mph` | Native imperial command speed when projected for confirmedImperial. | current app telemetry |
| `physical_speed_kmh_estimate` | Estimated physical speed for native imperial command/report. | current app telemetry |
| `requested_physical_delta_kmh` | Requested physical delta before raw-resolution projection. | current app telemetry |
| `command_physical_delta_kmh_estimate` | Effective physical delta after raw mph projection. | current app telemetry |
| `imperial_hr_control_enabled` | Whether confirmedImperial HR-control path is active. | current app telemetry |
| `manual_stop_acknowledged` | Session-scoped manual-stop acknowledgement state. | current app telemetry |
| `physical_speed_confidence` | Unknown / operator-confirmed physical semantics state. | current app telemetry |
| `physical_semantics_source` | Evidence source such as operator visual confirmation. | current app telemetry |

## Analyzer Rule

Analyzer verdict must not infer physical mph/kmh from device-reported raw distance alone. Without external measured
distance or operator-confirmed evidence, the physical verdict remains inconclusive.
