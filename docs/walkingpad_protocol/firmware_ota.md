# Firmware and OTA

Firmware / OTA information is intentionally read-only in this project. Public evidence confirms an OTA surface
exists, but no safe public firmware path has been found.

## Current Conclusion

| Topic | Conclusion | Status | Source |
| --- | --- | --- | --- |
| OTA surface | Exists in KS Fit / reverse notes. | `unknown` for safe use | raw research |
| Safe public firmware images | Not found. | `unknown` | raw research |
| Compatibility matrix | Not found. | `unknown` | raw research |
| Rollback / brick recovery | Not found. | `unknown` | raw research |
| Firmware flashing from this app | Not allowed. | `forbidden` | product safety rule |

## Evidence Found

Raw research found OTA-related references in reverse-engineered KS Fit material, including names such as
`ftms_ota.dart`, `FTMSOta`, `enterOTAMode`, chunked writes, CRC verification, and reboot behavior.

Research also found OTA-like UUIDs in third-party FTMS notes:

| Purpose | UUID | Status | Source |
| --- | --- | --- | --- |
| OTA notify | `32e2314c-0000-0000-0000-00000000fdf1` | `unknown` / do not use | raw research |
| OTA write | `32e2314c-0000-0000-0000-00000000fdf2` | `forbidden` | raw research |

These are not sufficient to flash firmware safely.

## Allowed Read-Only Device Information

The only firmware-related action allowed in this scope is reading standard Device Information characteristics:

| Characteristic | Name | Status | Notes |
| --- | --- | --- | --- |
| `0x2A24` | Model Number String | `allowed` | Read-only identity/debug evidence. |
| `0x2A26` | Firmware Revision String | `allowed` | Read-only firmware version evidence. |
| `0x2A28` | Software Revision String | `allowed` | Read-only software version evidence; used in some third-party FTMS code. |
| `0x2A29` | Manufacturer Name String | `allowed` | Read-only manufacturer evidence. |

## Forbidden Firmware Actions

| Action | Status | Reason |
| --- | --- | --- |
| Enter OTA mode | `forbidden` | Side effects and recovery unknown. |
| Write OTA chunks | `forbidden` | Firmware format, compatibility, and rollback unknown. |
| Reboot controller through OTA flow | `forbidden` | Device safety and recovery unknown. |
| Replay KS Fit firmware writes | `forbidden` | Unknown model/version assumptions. |
| Recommend firmware flashing as stop/units fix | `forbidden` | No safe public path. |

## Product Rule

Firmware version can be recorded for forensics. Firmware modification is out of scope and forbidden.
