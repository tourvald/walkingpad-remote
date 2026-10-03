---
name: walkingpad-pr-review
description: Independently review one WalkingPad Draft PR against its current Issue using the exact base/head diff and concise verification evidence. Use for PM review; code diffs also use minimal-code, and conditional redesign/performance/safety skills only when the diff triggers them.
---

# WalkingPad Draft PR review

## Review

1. Read the current Issue, active binding decisions, root/nested `AGENTS.md`, and only directly applicable domain contracts.
2. Resolve exact PR base/head, live `main`, changed-file list, complete base-to-head diff, and checks/CI for that exact head. Review the diff, not the implementation transcript.
3. Check scope first: every changed file/behavior must be authorized and required behavior must not be missing. Treat unrelated cleanup, generated artifacts, secrets, private health/device data, or production data as findings.
4. Review correctness against architecture, safety boundaries, telemetry/persistence truth, runtime contracts, accessibility/UX contract when relevant, and tests. Challenge added complexity and identify a concrete smaller safe alternative where one exists; stylistic preference or LOC reduction alone is not a blocker.
5. For code diffs also apply [`walkingpad-minimal-code`](../walkingpad-minimal-code/SKILL.md) and inspect `python3 scripts/code_growth_report.py <base> <head>` evidence. Treat detected state/timer/abstraction/config/dependency surfaces as review prompts, not automatic defects. For narrow bug fixes, unresolved >5 production files or >500 production LOC churn is a PM-stop tripwire unless the live Issue explicitly authorizes the broad mechanical scope. Add `walkingpad-performance` only for measured/explicit performance scope; add redesign/safety skills only when triggered by the Issue/diff.
6. Missing, stale, failed, cancelled, queued, or wrong-head required CI is not a pass. Verify evidence rather than inferring success from the implementation report; repeat successful expensive checks only under the [lifecycle's verification rule](../walkingpad-pr-lifecycle/SKILL.md#4-verify).
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


## Autonomous Goal merge exception

Ordinary PM merge authorization above remains the default. An **owner-activated autonomous Goal** may self-merge a non-safety, non-human-gated Issue only when its launch satisfies the fixed-completion-set contract in the [Codex/GitHub workflow](../../../docs/engineering/codex-github-workflow.md#owner-activated-autonomous-goal-mode).

The implementation phase must end before a frozen-diff review phase begins. Re-resolve live `main`, exact base/head, the complete diff, #170 code-growth evidence, mergeability, and exact-head CI from scratch. A separate bounded read-only reviewer may satisfy this code-review gate only for that explicitly activated low-risk mode. Return `NO-GO` on any unresolved material finding or anti-bloat tripwire.

Never self-merge through this exception when the task triggers `walkingpad-safety-change`, treadmill/BLE/control semantics, physical evidence, persistence schema/migration/destructive data or rollback behavior, a new dependency/framework/subsystem, signing/project-wide configuration/deployment, ambiguous product semantics, unavailable external authority/evidence, or stale/missing/failed CI. Such work may reach a verified Draft PR and `BLOCKED FOR PM REVIEW`, then the Goal may continue to another independent eligible Issue.

#170 and #171 themselves are bootstrap/manual-review changes and cannot use this exception.
