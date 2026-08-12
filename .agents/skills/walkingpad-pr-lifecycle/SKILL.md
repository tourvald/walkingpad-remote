---
name: walkingpad-pr-lifecycle
description: Implement one WalkingPad GitHub issue from an exact main SHA through an isolated worktree, verified feature branch, fresh independent review, and Draft PR. Never use it to mark Ready, merge, deploy, install, or operate hardware.
---

# WalkingPad PR lifecycle

1. Read the complete issue and PM addenda. Record explicit scope, non-goals, exact base, done criteria, risks, safe checks, and stop conditions.
2. Fetch GitHub `main`, resolve its exact SHA, and compare it with the approved base before editing. Stop for PM if the base is ambiguous or has drifted.
3. Create one `codex/...` branch in one isolated worktree. Never edit, stash, reset, or clean the user's dirty worktree.
4. Keep the parent/Goal agent as sole writer. Use read-only subagents only for non-overlapping bounded work that materially reduces risk; do not fill capacity.
5. Route mapping or narrow primary-source research to Luna/medium and safety challenge or final review to Terra/high by default. Disclose effective model, effort, outcome, and fallback.
6. Make the smallest in-scope implementation. Run focused checks and every applicable safe repository check without install, launch, BLE, or hardware activity.
7. Inspect the complete base-to-head diff for correctness, scope, safety, secrets, generated artifacts, and missing tests.
8. For substantial work, assign the completed diff to one fresh read-only reviewer. Fix in-scope material findings and use a fresh reviewer again; allow at most two correction cycles, then stop for PM if material findings remain.
9. Push only the feature branch and open one Draft PR into `main`. Never mark Ready, merge, force-push, deploy, install, or perform unrelated GitHub administration.
10. Fetch `main` again. Confirm it still matches the approved base and required pull-request CI tests the exact current head against that base. Missing, queued, cancelled, stale, or failed required CI blocks handoff readiness.
11. Report exact base/head, branch, changed files, preserved history, checks, CI, independent review, agent usage, and unresolved risks. End with `READY FOR PM REVIEW` only when every gate is satisfied.
