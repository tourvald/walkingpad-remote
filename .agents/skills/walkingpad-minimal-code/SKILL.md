---
name: walkingpad-minimal-code
description: Use for any WalkingPad code-writing, bug-fix, or refactor task and for code review when simplicity matters. Prefer reuse, Apple/Swift platform capabilities, deletion, and the smallest maintainable diff without weakening safety, telemetry truth, persistence, or required tests.
---

# WalkingPad minimal-code discipline

Goal: the smallest maintainable implementation that satisfies the contract. When alternatives are equally clear, correct, and safe, choose the smaller one; compressed syntax, hidden complexity, or fewer required tests do not qualify.

Before adding an abstraction, state, file, dependency, or wrapper, check existing owners and platform capabilities in this order:

1. No change needed.
2. Existing owner/helper/component/pattern.
3. Swift, SwiftUI, Foundation, HealthKit, CoreBluetooth, or another already-used Apple/platform capability.
4. An already-installed dependency that cleanly owns the need.
5. Otherwise the smallest local implementation.

Rules:

- Prefer deletion and consolidation over addition.
- Fix the root cause at the established owner rather than patching each caller.
- Avoid speculative protocols, factories, coordinators, pass-through wrappers, parallel state machines, or scaffolding for hypothetical modes. An abstraction is justified when it demonstrably improves ownership or testability.
- Do not add a dependency when the existing stack or a few clear lines suffice.
- Prefer fewer files, branches, state transitions, timers, passes, allocations, persistence operations, and transport round trips when behavior remains equally clear and correct.
- Keep SwiftUI presentation-focused; deterministic reusable rules belong in an existing focused seam, not in a new layer by default and not in `BluetoothManager` merely for convenience.
- Do not split a file solely to reduce line count. Extract only when ownership, reuse, testability, or readability materially improves.
- Keep comments for non-obvious constraints/invariants/reasons, not narration.
- Preserve fail-safe behavior, factual telemetry semantics, stop evidence, HR gates, unit semantics, persistence compatibility, privacy, and useful regression coverage.

Before handoff, inspect every added file, dependency, abstraction, state variable, branch, and meaningful block. Remove additions unnecessary for the contract, clarity, safety, and required tests.

Fewer LOC alone is never evidence of better code or faster runtime.


## Code-growth evidence

For code diffs, run `python3 scripts/code_growth_report.py <base> <head>` before handoff. Add `--narrow-bugfix` for a narrow bug-fix Issue so the repository tripwires for production-file count and production churn are reported.

Treat the report as review evidence, not a quality score. New durable-state/timer/abstraction candidates require an explicit ownership/lifecycle justification or removal. A narrow bug fix crossing the report's >5 production files or >500 production LOC churn tripwire stops for PM unless the live Issue explicitly authorizes the broad mechanical scope. New dependencies, persistence/schema/migration surfaces, production subsystems, or broad project/signing/configuration changes remain PM-stop categories even when raw LOC is small.

For an authorized multi-Issue autonomous Goal, preserve the Goal-start SHA and run the same report cumulatively after every three merged software Issues and at final completion. Cumulative findings are review inputs; they do not authorize opportunistic cleanup.
