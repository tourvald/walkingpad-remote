---
name: walkingpad-evidence-analysis
description: Analyze WalkingPad JSONL/CSV telemetry, stop-forensics, BLE captures, or protocol research as read-only evidence. Never use it to connect to hardware, send commands, or authorize runtime behavior.
---

# WalkingPad evidence analysis

1. Confirm the task is analysis-only and identify exact evidence paths, hashes, time windows, device/profile scope, and the question being tested.
2. Keep source JSONL, CSV, captures, exports, and research dumps read-only. Store derived output only where the task explicitly permits it, with no unnecessary identifiers or health data.
3. Prefer existing parsers/analyzers in read-only modes. Do not invoke BLE scanning, connections, notifications, reads, writes, app launch, device tooling, or any `raw`, `seq`, workout, unlock, or controller command path.
4. Separate device-observed facts, app intent/state, derived metrics, historical research, hypotheses, and missing evidence. Stale or absent telemetry is not proof of stop, unit semantics, or command effect.
5. Preserve raw units and timestamps. State conversions, freshness thresholds, joins, filters, and data-loss limitations explicitly.
6. For stop evidence, require fresh device-reported zero speed plus a non-running state; app-side `stop_confirmed`, command dispatch, or missing speed is insufficient.
7. Treat packet meaning and controller behavior as unconfirmed until supported by the approved evidence contract. Never promote an observed packet into an allowed command.
8. Report reproducible read-only commands, evidence coverage, contradictions, confidence, and the next bounded evidence question. Return hardware or behavior proposals to PM without executing them.
