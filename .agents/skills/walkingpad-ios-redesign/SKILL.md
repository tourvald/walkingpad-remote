---
name: walkingpad-ios-redesign
description: Route one PM-scoped native SwiftUI screen or flow through a token-bounded, presentation-only redesign process. Use for iOS visual/interaction redesign; never cross into BLE, stop, speed, HR, units, telemetry, or persistence behavior.
---

# WalkingPad iOS redesign

Read only the phase-specific reference named below; do not load the whole pack or duplicate external specialist knowledge.

1. **Scope and safety:** define one screen/flow, exact writable paths, read-only boundaries, simulator/mock fixtures, and done criteria using [`references/safety-boundary.md`](references/safety-boundary.md). Run `scripts/check-ui-scope.sh` against the exact base; it checks committed, staged, unstaged, and untracked paths.
2. **Audit:** use Product Design `audit` alone by default and return at most 8 actionable findings. Freeze the problem before ideation.
3. **Ideate:** use Product Design `ideate` plus at most one relevant SwiftUI specialist. Produce exactly 2 concepts maximum, record them in `docs/design/redesign-brief.md`, and stop for PM selection.
4. **Freeze:** record one selected direction in `docs/design/selected-direction.md`. Do not implement without that PM choice.
5. **Implement:** activate only 1–2 focused specialists for the phase. Use Wholiver `swiftui-design-skill` for native composition and Paul Hudson/twostraws `swiftui-pro` only for relevant partial references. Do not use Product Design `image-to-code` in the default native SwiftUI path.
6. **Verify:** build/test safely, summarize failures with `scripts/summarize-build-log.sh`, and avoid re-feeding complete successful logs. Use [`references/qa-contract.md`](references/qa-contract.md) and Product Design `design-qa` for normal visual QA. After changing the scope checker, run `scripts/test-check-ui-scope.sh`.
7. **Correct:** allow at most 2 visual QA correction passes. If P0–P2 findings remain, stop for PM instead of extending the loop.

Run `ios-debugger-agent` only for an actual iOS build/runtime-debug question. Add performance, accessibility, or animation/layout specialists only when the screen/task triggers them. Use Liquid Glass only after an explicit PM design decision. Add a second-opinion critic only for a deliberate red-team pass.

Store stable brief, selected direction, tokens, and QA outcomes in `docs/design/`; keep conversational context concise. Ordinary redesign never authorizes install, device launch, BLE, or treadmill activity.
