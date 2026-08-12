---
name: walkingpad-safety-change
description: Implement PM-approved changes to stop behavior, controller units/preferences, HR safety gates, persistent BLE writes, or other safety-critical runtime behavior. Requires an explicit behavior contract and focused positive/negative regression coverage.
---

# WalkingPad safety change

1. Stop unless the issue contains an explicit PM-approved behavior contract defining the owning path, current and desired behavior, allowed commands/state mutations, positive cases, negative boundaries, failure behavior, telemetry, compatibility, and non-goals.
2. Trace the established owner before editing: view/presentation, orchestration, domain rule, codec/protocol, transport, persistence, or telemetry. Keep packet ownership in codec/protocol seams and pure decisions out of `BluetoothManager`.
3. Preserve fail-safe behavior for missing, stale, unknown, disconnected, or contradictory state. Debug/test paths must not bypass production gates.
4. Add focused positive coverage for every approved behavior and negative regression coverage for nearby actions that must remain blocked. For stop changes, prove confirmation cannot come from app intent or stale/missing device evidence. For units/HR changes, prove unconfirmed semantics and stale HR remain blocked.
5. Run focused tests and every applicable safe suite without connecting to hardware. A simulator or unsigned build is not physical validation.
6. Require independent Terra/high scope challenge and fresh final review. Report remaining uncertainty separately from verified behavior.
7. Do not infer permission for controller experiments. Any physical test requires a separate `walkingpad-hardware-experiment` contract and PM approval.
