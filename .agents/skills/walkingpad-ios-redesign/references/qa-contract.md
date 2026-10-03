# Visual QA contract

Evaluate the PM-selected direction using simulator or previews only.

- Compare the named states and form factors against the frozen direction/task contract.
- Check hierarchy, spacing, typography, contrast, Dynamic Type, VoiceOver labels/order, hit targets, reduced motion, localization resilience, and light/dark appearance when applicable.
- Confirm all interactions remain presentation-only and mocks cannot reach production transport.
- Record findings as P0–P3 with screenshot/state evidence, owner path, and pass/fail status in `docs/design/qa-ledger.md`.
- Correct within the approved write set; stop for PM if P0–P2 cannot be resolved there or a fix requires scope expansion.
- Run performance, accessibility, or animation/layout specialists only when evidence triggers them; do not run them by default.

Build success is necessary when applicable but does not prove visual acceptance and never authorizes install, BLE, or hardware work.
