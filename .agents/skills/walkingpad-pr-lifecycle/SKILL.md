---
name: walkingpad-pr-lifecycle
description: Implement one WalkingPad GitHub issue from an exact main SHA through an isolated worktree, verified feature branch, fresh independent review, and Draft PR. Delivery stops at Draft; a later PM review may merge only under the repository's conditional standing authorization.
---

# WalkingPad PR lifecycle

This skill is the canonical owner of the repository's implementation delivery
workflow. Root `AGENTS.md` owns global authority and safety boundaries; the
current Issue and active PM decisions own task-specific behavior.

## Context and contract

1. Read the complete current Issue and every active PM decision. Record scope,
   non-goals, done criteria, risks, safe checks, and hard stops before editing.
2. Use current code/tests and directly relevant canonical docs as the default
   context. Read predecessor Issues, PRs, commits, or historical notes only when
   a concrete ambiguity remains.
3. When a later PM decision supersedes body wording, follow the decision and
   preserve its link in the Issue's `Current binding decisions` index. Do not
   erase historical comments.
4. Before relying on non-trivial or unstable external behavior, consult the
   applicable primary official documentation and retain only the finding that
   affected the implementation.

## Implementation and verification

1. Fetch GitHub `main`, resolve its exact live SHA, and compare it with the
   approved contract before editing. Stop for PM on ambiguous or invalidating
   base drift.
2. Use exactly one `codex/...` branch in one isolated worktree created from that
   SHA. Never reset, stash, clean, or reuse the user's dirty worktree.
3. Keep the parent/Goal agent as sole writer. Mapper or research agents are
   conditional and read-only. Use a safety challenger and a fresh independent
   final reviewer whenever the Issue, risk class, or repository contract
   requires them.
   For substantial work, select `gpt-5.6-sol` with `high` reasoning for the
   parent when the client exposes that choice. Route repository mapping or
   narrow primary-source research to Luna/medium and safety challenge or final
   review to Terra/high by default. Report the effective model, effort, role,
   outcome, and any fallback; never claim an unexposed selection.
4. Make the smallest in-scope change. Run focused checks while iterating and the
   full applicable safe suite once the coherent change is ready. Repeat a
   successful full suite only after a relevant change or failure.
5. Inspect the complete base-to-head diff for correctness, scope, safety,
   secrets, private data, generated artifacts, and missing tests. Summarize long
   successful logs instead of carrying their full output forward.
6. Give the final reviewer the authoritative contract, exact base and head,
   complete base-to-head diff, and concise check evidence. Review the diff, not
   the implementation transcript.
7. Correct material in-scope findings from the finding and changed delta. Use a
   fresh reviewer after a correction. After two correction cycles with material
   findings still open, stop for PM direction.

## Draft PR and exact-head gate

1. Commit intentionally, push only the feature branch, and open exactly one
   Draft PR into `main` with the required closing reference.
2. Do not mark Ready, merge, force-push, deploy, install, launch on a device,
   perform hardware/BLE activity, or start another Issue during delivery.
   Custom GitHub labels are never a delivery dependency.
3. Fetch `main` again. Confirm that it still equals the approved base, the live
   PR head equals the reviewed local head, mergeability is acceptable, and every
   required CI result is successful for that exact head and base.
4. Missing, queued, cancelled, stale, failed, or wrong-head required CI blocks
   `READY FOR PM REVIEW`.
5. Report exact base/head, branch, changed files, preserved history, checks, CI,
   independent review, agent roles and effective model/effort when exposed,
   assumptions, and remaining risks.

## Token observability

Token usage is post-hoc observability. It is never by itself a reason to stop,
request continuation, skip required verification, or reduce safety assurance.
Report token and elapsed-time usage when the client exposes them; otherwise mark
those fields unverifiable.

## PM review and standing merge authorization

Implementation delivery always stops at a Draft PR. If the user later hands the
completed Draft PR to PM with a completion report and asks for GitHub review,
that request authorizes merge in the same PM review turn only after an explicit
final `GO` or `APPROVED` verdict.

PM may then refresh the PR and live `main`; verify exact base/head, no base
drift, exact-head required CI, any contract-required real app build, and no open
P0/P1/material P2; perform metadata-only PR cleanup; mark Ready; squash-merge
using the exact expected head SHA; verify new `main`; and verify or, when needed,
close the linked completed Issue.

The authorization is cancelled by any non-`GO`/non-`APPROVED` verdict, moved
head, base drift, conflict, non-clean merge, missing/queued/stale/cancelled/
failed/wrong-head required CI, missing required build, unresolved material
finding, scope or safety violation, unresolved safety uncertainty requiring an
explicit decision, or a more specific gate requiring separate approval.

It never covers hardware/BLE/treadmill experiments or physical commands;
install/device launch outside explicit scope; deploy/release; firmware, OTA, or
service-menu actions; controller preference or unit writes outside their own
contract; force-push; branch/tag deletion; destructive cleanup; or work on the
next Issue.
