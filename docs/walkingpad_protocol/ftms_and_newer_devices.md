# FTMS and Newer KingSmith Devices

This document covers newer WalkingPad / KingSmith protocol surfaces that differ from the legacy `FE00` protocol.

## FTMS Service

| Item | UUID | Direction | Meaning | Source |
| --- | --- | --- | --- | --- |
| FTMS service | `0x1826` | discovery | Standard Fitness Machine Service. | raw research, current app code |
| Fitness Machine Control Point | `0x2AD9` | app -> treadmill | Request control, start/resume, set target speed, stop. | raw research, current app code |
| Treadmill Data | `0x2ACD` | treadmill -> app | Instantaneous speed and treadmill telemetry. | raw research, current app code |
| Fitness Machine Status | `0x2ADA` | treadmill -> app | Machine status notifications such as stop/started depending on device. | raw research |
| Supported Speed Range | `0x2AD4` | treadmill -> app | Min/max/increment speed capability. | raw research, current app code |

## FTMS Commands

| Action | Encoding | Status | Notes | Source |
| --- | --- | --- | --- | --- |
| Request control | FTMS Control Point op | `allowed` in FTMS flow | Required by some devices before control. | current app code |
| Start/resume | FTMS Control Point op | `allowed` in FTMS flow | Device-specific response behavior can vary. | current app code |
| Set target speed | FTMS Control Point `0x02`, speed in `0.01 km/h` | `allowed` in FTMS flow | Current app treats speed as `0.01 km/h`, not `0.01 m/s`. | `BLETransportCodec.swift` |
| Stop | FTMS Control Point `08 01` | `allowed` in FTMS flow | Must still verify actual stopped state. | `BLETransportCodec.swift` |

## Telemetry / Status Caveats

FTMS devices may expose stop/running evidence through different characteristics:

- `0x2ACD` Treadmill Data
- `0x2ADA` Fitness Machine Status
- Control Point responses/indications, when supported

Product rule: FTMS write success is not physical success. Use telemetry and observation, same as legacy.

## KingSmith ODM / Supplement Services

Raw research found newer KingSmith devices can also expose KingSmith-specific services in addition to FTMS, for
example ODM/Supplement UUID families mentioned in third-party research.

Current status:

| Surface | Status | Rule |
| --- | --- | --- |
| Standard FTMS | `allowed` through current app implementation | Use standard characteristics first. |
| KingSmith ODM/Supplement reads | `unknown` | Research-only until mapped. |
| Unknown KingSmith-specific writes | `forbidden` | Do not replay or infer writes from KS Fit without a safety review. |
| OTA-related writes | `forbidden` | See [firmware_ota.md](firmware_ota.md). |

## Difference from Legacy `FE00`

Do not mix protocol assumptions:

| Legacy `FE00` | FTMS |
| --- | --- |
| Write characteristic `FE02` | Control Point `0x2AD9` |
| Notify characteristic `FE01` | Treadmill Data `0x2ACD`, status `0x2ADA` |
| Speed command raw tenths in legacy packet | FTMS speed encoded as `0.01 km/h` |
| Unit preference from legacy `queryParams` | Standard FTMS does not use the same `queryParams.unit` model |

## Device Information

For newer devices, read-only Device Information characteristics are useful for forensics:

| Characteristic | Name | Status |
| --- | --- | --- |
| `0x2A24` | Model Number String | `allowed` |
| `0x2A26` | Firmware Revision String | `allowed` |
| `0x2A28` | Software Revision String | `allowed` |
| `0x2A29` | Manufacturer Name String | `allowed` |
