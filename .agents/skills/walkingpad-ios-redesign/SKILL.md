---
name: walkingpad-ios-redesign
description: Scope and verify a PM-approved native SwiftUI screen or flow redesign. Use for iOS visual/interaction changes; never change BLE, stop, speed, HR, units, telemetry, or persistence behavior.
---

# WalkingPad iOS redesign

Read only the reference needed for the current task.

## Scope and direction

Establish the screen/flow, exact writable paths, simulator/mock inputs, and acceptance evidence using [the safety boundary](references/safety-boundary.md). Run `scripts/check-ui-scope.sh` against the exact base.

- **Frozen direction:** proceed directly to scoped implementation, verification, and correction. Do not repeat audit/ideation or create concept documents to restate the accepted direction.
- **Open direction:** audit or compare alternatives only as needed to resolve the user problem. Use [the design brief](references/design-brief.md) for decisions worth retaining; obtain PM selection before implementing a new direction. Finding, concept, and correction counts come from the task, not universal quotas.

Verify against [the QA contract](references/qa-contract.md); summarize build failures with `scripts/summarize-build-log.sh`. After changing the scope checker, run `scripts/test-check-ui-scope.sh`. Keep corrections inside the approved write set; stop for PM when material findings cannot be resolved there.

## Conditional external specialists

Use only available capabilities that answer a concrete question; no specialist is a prerequisite:

- [OpenAI Product Design](https://github.com/openai/plugins/tree/main/plugins/product-design) for genuinely open UX/design direction or visual QA.
- [OpenAI `build-ios-apps`](https://github.com/openai/plugins/tree/main/plugins/build-ios-apps) for specific SwiftUI implementation, simulator debugging, or measured performance needs. View extraction needs an ownership/readability/testability benefit; Liquid Glass needs an explicit PM design choice.

Do not install, vendor, or copy external skills/plugins for redesign. Local [minimal-code](../walkingpad-minimal-code/SKILL.md), safety, and write-scope contracts win on conflict. Performance work also routes through [walkingpad-performance](../walkingpad-performance/SKILL.md).

Store only stable decisions and useful QA evidence in `docs/design/`. Use simulator/previews only; ordinary redesign never authorizes physical-device install/launch, BLE, or treadmill activity.
