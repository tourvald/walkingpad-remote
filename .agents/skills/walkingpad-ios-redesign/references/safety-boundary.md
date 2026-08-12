# Redesign safety boundary

## Required task contract

Before audit or edits, record:

- one named screen or flow;
- exact base SHA and exact writable files;
- user problem, states, supported form factors, and acceptance evidence;
- simulator/mock data source;
- explicit non-goals and PM decision gates.

## Default writable scope

- PM-named SwiftUI view/component files;
- visual tokens/assets used only by the approved screen;
- previews and mock fixture data with no production transport;
- UI-focused tests;
- `docs/design/**`.

## Read-only without separate approval

- `BluetoothManager.swift` and behavioral orchestration;
- BLE protocol, codec, transport, Python tools, and command helpers;
- stop/start/speed paths and command queue behavior;
- HR decisions, cooldown, freshness, safety gates, and speed bounds;
- controller units/preferences and conversion semantics;
- telemetry schemas/events, retention, persistence, and profile ownership;
- Xcode project settings, signing, entitlements, and deployment helpers.

No real BLE writes, physical treadmill experiments, install/device launch, adjacent cleanup, or behavioral changes are permitted. If presentation work requires any read-only path to change, stop for PM scope expansion.
