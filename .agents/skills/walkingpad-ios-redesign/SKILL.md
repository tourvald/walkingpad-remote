---
name: walkingpad-ios-redesign
description: Route one PM-scoped native SwiftUI screen or flow through a token-bounded presentation-only redesign process. Use for iOS visual/interaction redesign; never cross into BLE, stop, speed, HR, units, telemetry, or persistence behavior.
---

# WalkingPad iOS redesign

Read only the phase-specific reference needed for the active phase; do not load the whole pack or duplicate external specialist knowledge.

## Choose the path

**Narrow follow-up:** if the current Issue/active PM decision already freezes the visual direction and explicitly describes a bounded correction, skip audit, two-concept ideation, and freeze. Establish scope/safety, then run **Implement → Verify → Correct**. Do not create concept docs merely to restate an already-selected direction.

**New design direction:** otherwise use the full flow below and stop for PM selection after two concepts.

## Full design flow

1. **Scope and safety:** define one screen/flow, exact writable paths, read-only boundaries, simulator/mock fixtures, and done criteria using [`references/safety-boundary.md`](references/safety-boundary.md). Run `scripts/check-ui-scope.sh` against the exact base.
2. **Audit:** use Product Design `audit` alone by default and return at most 8 actionable findings. Freeze the problem before ideation.
3. **Ideate:** use Product Design `ideate` plus at most one relevant SwiftUI specialist. Produce exactly 2 concepts maximum, record them in `docs/design/redesign-brief.md`, and stop for PM selection.
4. **Freeze:** record one selected direction in `docs/design/selected-direction.md`. Do not implement without that PM choice.
5. **Implement:** activate only 1–2 focused specialists when they materially reduce risk. Prefer native SwiftUI and the existing presentation seams.
6. **Verify:** build/test safely, summarize failures with `scripts/summarize-build-log.sh`, and avoid re-feeding complete successful logs. Use [`references/qa-contract.md`](references/qa-contract.md) and design QA appropriate to the scope. After changing the scope checker, run `scripts/test-check-ui-scope.sh`.
7. **Correct:** allow at most 2 visual QA correction passes. If P0–P2 findings remain, stop for PM instead of extending the loop.

Run debugger/performance/accessibility/animation specialists only for a concrete question that needs them. Use Liquid Glass only after an explicit PM design decision. Add a second-opinion critic only for a deliberate red-team pass.

Store only stable decisions/QA evidence that future work actually needs in `docs/design/`; keep conversational context concise. Ordinary redesign never authorizes install, device launch, BLE, or treadmill activity.
