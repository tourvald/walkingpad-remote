---
name: walkingpad-pr-lifecycle
description: Implement one scoped WalkingPad Issue from live main through an isolated worktree, verification, and one exact-head Draft PR. Use for normal implementation; pair with minimal-code for code changes and only the conditional domain skills the Issue actually triggers.
---

# WalkingPad implementation lifecycle

Root `AGENTS.md` owns repository-wide boundaries. The current Issue and active PM decisions own task-specific behavior, tests, non-goals, and hard stops.

## 1. Establish the contract

- Read the current Issue, active decisions, root/nested `AGENTS.md`, and only directly relevant canonical docs/code/tests.
- Record goal, non-goals, done criteria, risk, safe checks, and accepted `main` SHA or permission to use live `main`.
- Read history only to resolve a concrete ambiguity.
- For code changes also use [`walkingpad-minimal-code`](../walkingpad-minimal-code/SKILL.md).
- Add redesign, performance, safety, hardware, or evidence skills only when the task triggers them.

## 2. Work from the exact base

1. Preserve the user's existing worktree and unrelated changes.
2. Fetch `main`, resolve its exact SHA, and stop on invalidating base drift.
3. Create one isolated worktree and one `codex/...` branch from that SHA.

Never clean, stash, reset, or reuse a dirty user worktree for task edits.

## 3. Implement narrowly

- Trace the existing owner and relevant callers/tests before editing.
- Make the smallest maintainable in-scope change; do not add adjacent cleanup.
- Finish authorized work without asking PM to reapprove routine choices. For a real blocker, name the conflicting rule or unresolved fact and the smallest missing decision; do not expand the contract.
- Preserve runtime, safety, API/data, telemetry, persistence, and device contracts unless the Issue explicitly changes them.
- Add focused regression coverage when existing tests do not prove the contract.
- Ordinary implementation never authorizes install, launch, deploy, BLE/hardware activity, or destructive cleanup.

## 4. Verify

Run focused checks while iterating, then `git diff --check` and the applicable full gates on the coherent head, using commands from root `AGENTS.md` and the relevant domain contract. Preserve required negative/safety regressions, independent review, safety challenge, and exact-head CI.

Repeat successful expensive checks only when a code/base/environment change or concrete finding invalidates their evidence, or a mandatory gate explicitly requires a rerun. Missing, failed, stale, or wrong-head checks are never passes. Docs-only changes do not by themselves require local Swift/Xcode/BLE suites; applicable UI, build, simulator, telemetry, and domain checks still run for their scopes. Summarize results with links instead of repeating successful logs.

## 5. Inspect and publish

- Re-fetch `main` and confirm the accepted base still holds.
- Inspect the complete base-to-head diff and changed-file list for scope, correctness, unnecessary complexity, secrets/private data, generated artifacts, and missing tests.
- Stage only scoped files, commit intentionally, push only the task branch, and open exactly one Draft PR into `main` with the required closing reference.
- Verify server-side changed files and exact PR head. Required CI must be green for that exact head before declaring the Draft ready for PM review.

## Handoff boundary

Use the [PR template](../../../.github/pull_request_template.md) as the single compact evidence packet; link to it at handoff instead of creating a second report or replaying transcripts.

Stop at the verified Draft PR. Mark-Ready, merge, deploy/install, device launch, BLE/hardware activity, force-push, destructive cleanup, or the next Issue require the applicable separate role/authorization.
