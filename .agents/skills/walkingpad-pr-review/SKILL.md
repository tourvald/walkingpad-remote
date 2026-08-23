---
name: walkingpad-pr-review
description: Independently review one WalkingPad Draft PR against its current Issue using the exact base/head diff and concise verification evidence. Use for PM review; code diffs also use minimal-code, and conditional redesign/performance/safety skills only when the diff triggers them.
---

# WalkingPad Draft PR review

## Review

1. Read the current Issue, active binding decisions, root/nested `AGENTS.md`, and only directly applicable domain contracts.
2. Resolve exact PR base/head, live `main`, changed-file list, complete base-to-head diff, and checks/CI for that exact head. Review the diff, not the implementation transcript.
3. Check scope first: every changed file/behavior must be authorized and required behavior must not be missing. Treat unrelated cleanup, generated artifacts, secrets, private health/device data, or production data as findings.
4. Review correctness against architecture, safety boundaries, telemetry/persistence truth, runtime contracts, accessibility/UX contract when relevant, and tests.
5. For code diffs also apply [`walkingpad-minimal-code`](../walkingpad-minimal-code/SKILL.md). Add `walkingpad-performance` only for measured/explicit performance scope; add redesign/safety skills only when triggered by the Issue/diff.
6. Missing, stale, failed, cancelled, queued, or wrong-head required CI is not a pass. Do not infer verification from the implementation report.
7. Findings use P0/P1/P2/P3 with exact file/line or GitHub metadata, consequence, evidence, and the smallest safe correction.
8. After a material correction, review the new exact head and changed delta fresh.

Return `NO-GO` while any material scope/correctness/safety/data finding or required gate is unresolved. Return `GO` only when the exact reviewed head satisfies the contract and evidence.

## PM merge authorization

When the user hands a completed Draft PR to PM for review, the same review turn may mark Ready and merge only after an explicit final `GO`, provided all of the following remain true on a fresh check:

- live `main` still matches the accepted base or the Issue explicitly permits the resolved drift;
- PR head equals the reviewed head;
- mergeability is clean/acceptable;
- all required exact-head CI/build gates are green;
- no open P0/P1/material P2 or unresolved safety uncertainty remains.

Use an exact expected-head guard when merging, then verify the new `main` and linked Issue closure.

Any non-`GO` verdict, moved head, invalidating base drift, conflict, stale/missing CI, unresolved material finding, or more-specific gate cancels merge authorization.

This standing authorization never covers deploy/install/device launch, BLE/treadmill experiments, controller preference/unit writes outside their own contract, firmware/OTA/service-menu actions, force-push, destructive cleanup, or work on the next Issue.
