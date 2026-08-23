---
name: walkingpad-minimal-code
description: Use for any WalkingPad code-writing, bug-fix, or refactor task and for code review when simplicity matters. Prefer reuse, Apple/Swift platform capabilities, deletion, and the smallest maintainable diff without weakening safety, telemetry truth, persistence, or required tests.
---

# WalkingPad minimal-code discipline

Goal: the smallest maintainable change that satisfies the contract. This is not code golf; correctness, clarity, and treadmill safety win ties.

Before adding code, stop at the first option that works:

1. No change needed.
2. Existing owner/helper/component/pattern.
3. Swift, SwiftUI, Foundation, HealthKit, CoreBluetooth, or another already-used Apple/platform capability.
4. An already-installed dependency that cleanly owns the need.
5. Otherwise the smallest local implementation.

Rules:

- Prefer deletion and consolidation over addition.
- Fix the root cause at the established owner rather than patching each caller.
- No speculative abstraction: avoid one-implementation protocols, factories, coordinators, pass-through wrappers, parallel state machines, or scaffolding for hypothetical modes.
- Do not add a dependency when the existing stack or a few clear lines suffice.
- Prefer fewer files, branches, state transitions, timers, passes, allocations, persistence operations, and transport round trips when behavior remains equally clear and correct.
- Keep SwiftUI presentation-focused; deterministic reusable rules belong in an existing focused seam, not in a new layer by default and not in `BluetoothManager` merely for convenience.
- Do not split a file solely to reduce line count. Extract only when ownership, reuse, testability, or readability materially improves.
- Keep comments for non-obvious constraints/invariants/reasons, not narration.
- Preserve fail-safe behavior, factual telemetry semantics, stop evidence, HR gates, unit semantics, persistence compatibility, privacy, and useful regression coverage.

Before handoff, inspect every added file, dependency, abstraction, state variable, branch, and meaningful block. If removing it still satisfies the Issue and tests, remove it.

Report base-to-head production LOC delta and any new file/dependency when practical. Fewer LOC alone is never evidence of faster runtime.
