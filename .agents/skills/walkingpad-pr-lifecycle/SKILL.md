---
name: walkingpad-pr-lifecycle
description: Implement one WalkingPad GitHub issue from an exact main SHA through an isolated worktree, verified feature branch, fresh independent review, and Draft PR. Delivery stops at Draft; a later PM review may merge only under the repository's conditional standing authorization.
---

# WalkingPad PR lifecycle

1. Read the complete issue and PM addenda. Record explicit scope, non-goals, exact base, done criteria, risks, safe checks, and stop conditions.
2. Fetch GitHub `main`, resolve its exact SHA, and compare it with the approved base before editing. Stop for PM if the base is ambiguous or has drifted.
3. Create one `codex/...` branch in one isolated worktree. Never edit, stash, reset, or clean the user's dirty worktree.
4. Keep the parent/Goal agent as sole writer. Use read-only subagents only for non-overlapping bounded work that materially reduces risk; do not fill capacity.
5. For substantial autonomous work, select `gpt-5.6-sol` with `high` reasoning for the parent when the client supports parent model and effort choice. Use cheaper effort only for genuinely simple scoped work. If selection is unavailable or unexposed, do not claim it; disclose the effective parent model, effort, and fallback.
6. Route mapping or narrow primary-source research to Luna/medium and safety challenge or final review to Terra/high by default. Disclose effective model, effort, outcome, and fallback.
7. Make the smallest in-scope implementation. Run focused checks and every applicable safe repository check without install, launch, BLE, or hardware activity.
8. Inspect the complete base-to-head diff for correctness, scope, safety, secrets, generated artifacts, and missing tests.
9. For substantial work, assign the completed diff to one fresh read-only reviewer. Fix in-scope material findings and use a fresh reviewer again; allow at most two correction cycles, then stop for PM if material findings remain.
10. Push only the feature branch and open one Draft PR into `main`. Implementation delivery never marks Ready or merges. Do not force-push, deploy, install, or perform unrelated GitHub administration.
11. Fetch `main` again. Confirm it still matches the approved base and required pull-request CI tests the exact current head against that base. Missing, queued, cancelled, stale, or failed required CI blocks handoff readiness.
12. Report exact base/head, branch, changed files, preserved history, checks, CI, independent review, agent usage, and unresolved risks. End with `READY FOR PM REVIEW` only when every gate is satisfied.

## Token and context efficiency

- Unless the task overrides them, use soft planning ranges of about `200k-300k` tokens for small scoped maintenance or correction, `300k-500k` for a substantial feature, and `400k-600k` for large safety-critical work. Checkpoint substantial tasks near `500k`; about `700k` is a soft ceiling, never a hard cutoff.
- A task-specific budget or checkpoint supersedes generic targets without weakening safety, review, build, or exact-head CI gates.
- At a checkpoint or soft ceiling, report exposed usage, explain any concrete reason to continue, stop optional exploration, add no low-value agents, and choose a bounded completion path or PM escalation. Do not ship unsafe or knowingly incomplete work to save tokens.
- Use agents only when they materially reduce risk or review cost. Do not repeat accepted repository archaeology without a new reason. Start corrections from the finding and relevant diff; summarize long successful logs.
- Run focused tests during implementation, then one full applicable suite after the change is coherent. Repeat a successful full suite or build only after a relevant change or failure.
- Give reviewers the contract, exact base-to-head diff, and concise evidence. Use exact historical references selectively instead of sending the full transcript or re-reading broad history.
- Report final token/time usage when exposed, and explicitly mark unverifiable model, effort, token, or timing details.

## PM review and standing merge authorization

This skill's implementation run always stops at a Draft PR. If the user later hands the completed PR to PM with a completion report and asks for GitHub review, that request is standing authorization in the same PM review turn to merge only after PM gives an explicit final `GO` or `APPROVED` verdict.

PM may then refresh the PR and live `main`; verify exact base/head, no base drift, exact-head required CI, any contract-required real app build, and no unresolved P0/P1/material P2; perform metadata-only PR cleanup; mark Ready; squash-merge using the exact expected head SHA; verify the new `main`; and verify or, when needed, close the completed linked issue.

Do not use standing authorization if the verdict is not explicit `GO`/`APPROVED`; the head moved; the base drifted; CI is missing, queued, stale, cancelled, failed, or for the wrong head; a required build is absent or failed; any P0/P1/material P2, reviewer, or scope finding remains; scope or safety was violated; safety uncertainty needs an explicit decision; the merge is conflicted or non-clean; or a more specific policy requires separate `GO`.

Standing authorization never covers hardware/BLE/treadmill experiments or physical commands, install/device launch outside explicit task scope, deploy/release, firmware/OTA/service-menu actions, controller preference or unit writes outside their own contract, force-push, branch/tag deletion or destructive cleanup, or work on the next issue. Those remain separate gates.
