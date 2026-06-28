# Stop Behavior

This document defines what is known about stopping legacy WalkingPad controllers and what remains unresolved for
the affected KS-F0 treadmill.

## Current Product Principle

Stop success is judged by telemetry, not by BLE write success.

Sending a stop packet only proves that the app attempted to stop. The belt is considered stopped only when
post-command observation confirms safe stopped state through treadmill notifications / telemetry.

Source: `STATUS.md`, current `BluetoothManager.swift` stop verification flow.

## Legacy Stop Command

Standard legacy stop is speed raw zero:

```text
F7 A2 01 00 A3 FD
```

| Action | Status | Notes | Source |
| --- | --- | --- | --- |
| Send speed raw zero as stop | `allowed` | Standard legacy stop attempt. | raw research, current app code |
| Treat write success as stop success | `forbidden` | Must verify with telemetry. | `STATUS.md`, current app code |
| Continue observation after stop | `allowed` | Needed to detect failed stop / belt still moving. | current app code |

## Standby Assist

Known standby-like packet:

```text
F7 A2 02 02 A6 FD
```

Current interpretation:

- It can be used as an assist after a speed-zero stop attempt.
- It should not be blindly used as the first or only stop.
- It is not proof that the belt stopped.

| Action | Status | Reason | Source |
| --- | --- | --- | --- |
| Speed-zero stop first | `allowed` | Standard protocol-level stop. | raw research |
| Standby after stop attempt | `diagnostic-only` / controlled assist | Can help some controllers, but must be observed. | raw research, current app code |
| Standby as first/only stop | `forbidden` | Ambiguous side effects and not a verified stop. | product safety rule |

## Current Stop Verification Signals

The app records stop verification evidence such as:

| Signal | Meaning | Source |
| --- | --- | --- |
| `stop_confirmed_ever` | Whether any observation window confirmed stopped state. | telemetry |
| post-stop notify rows | State/speed/appSpeed after stop command. | telemetry |
| repeated stop/assist commands | Evidence that stop was not immediately confirmed. | telemetry |
| final observation window | Determines whether stop sequence succeeded or remained unresolved. | current app code |

## KS-F0 Stop Issue Boundary

The affected KS-F0 treadmill has local evidence of failed stop confirmation, including sessions where stop was
sent but `stop_confirmed_ever=false`. Owner report also indicates the native physical remote can show the same
non-stop behavior.

Status:

| Claim | Status | Source |
| --- | --- | --- |
| The affected treadmill can fail to stop after app stop sequence. | local observation | exported telemetry / runtime snapshot |
| The native remote can also fail to stop the affected treadmill. | local observation | owner report |
| Root cause is protocol-level and solved. | unknown | not proven |
| Root cause is app-only. | unlikely, but not fully disproven | owner report plus telemetry |
| Stop-forensics work is separate from units MVP. | confirmed product boundary | `STATUS.md` |

Do not generalize the KS-F0 stop issue to all WalkingPad controllers until more device evidence exists.

## FTMS Stop Note

FTMS stop uses the FTMS Control Point, currently represented in the app codec as:

```text
08 01
```

FTMS stop status can be exposed through machine status `0x2ADA` or treadmill data `0x2ACD`, depending on device.
This is a different protocol surface from legacy `FE00` and must not be mixed with legacy stop packets.
