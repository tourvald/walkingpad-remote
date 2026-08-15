# Codex and GitHub contract ownership

Status: canonical governance map for repository work.

This document explains where project knowledge belongs. It intentionally does
not duplicate the implementation sequence owned by
[`walkingpad-pr-lifecycle`](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md).

## Canonical owners

| Concern | Canonical owner | Keep out of |
| --- | --- | --- |
| Repository authority, safety boundaries, documentation map | root [`AGENTS.md`](../../AGENTS.md) | child Issues and launch prompts |
| Detailed branch/worktree/review/Draft PR/CI/correction workflow | [`walkingpad-pr-lifecycle`](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md) | root instructions and Issue bodies |
| Subtree-specific engineering rules | nearest nested `AGENTS.md` | unrelated subtrees and root history |
| Cross-Issue Telemetry V2 semantics | [`docs/telemetry-v2/`](../telemetry-v2/index.md) | repeated Issue boilerplate |
| Task goal, accepted behavior, tests, non-goals, hard stops | current Issue body | global docs unless the decision is durable across Issues |
| Later task-specific PM decisions | linked owner comments and integrated current body | rewritten or deleted comment history |
| Historical implementation context | Git/Issue/PR history and archived docs | default launch context |

When two sources differ, apply the precedence rules in the root constitution and
the relevant domain index. Escalate instead of guessing when the difference
changes safety, scope, or accepted behavior.

## Progressive disclosure

Start with the current Issue, its `Current binding decisions`, the applicable
contract links, and current code/tests. Read a predecessor Issue, PR, commit, or
archived document only when a named ambiguity cannot be resolved from those
sources. Record the ambiguity that justified the historical lookup.

Successful logs are evidence to summarize, not context to reproduce. A review
packet should contain the contract, exact base/head, complete diff, changed-file
scope, and concise check results. A correction should start from the exact
finding and inspect the resulting delta; accepted repository archaeology is not
repeated without a new reason.

## Issue body shape

Implementation Issues should contain only task-specific material plus:

- `Applicable contracts`: links to root/subsystem instructions, the lifecycle
  skill, and relevant canonical domain docs;
- `Current binding decisions`: links to active comments whose decisions remain
  relevant, with settled requirements integrated into the body;
- explicit predecessor/dependency state, behavior contract, tests, non-goals,
  done criteria, and hard stops where the task needs them.

Do not paste repository-global Telemetry invariants or the standard lifecycle
into each Issue. Comments remain audit history; integrating a decision into the
body does not delete or rewrite the original comment.

The template at
[`codex-implementation.md`](../../.github/ISSUE_TEMPLATE/codex-implementation.md)
implements this shape.

## Thin launch prompt

A launch prompt identifies the repository, Issue number, execution role, and
required terminal verdict. It directs Codex to the current Issue, active
decisions, root/nested instructions, and applicable skill. It may restate a
task-specific hard boundary when omission would be risky, but does not copy the
Issue body, global invariants, or detailed lifecycle.

## Review and correction evidence

Review findings use priority and exact file/line or GitHub metadata references.
The reviewer receives the base-to-head diff rather than a full transcript.
Corrections describe the finding, the bounded delta, and checks rerun because of
that delta. Required full checks and exact-head CI remain mandatory regardless
of context size or token use.

## GitHub metadata updates

For an authorized Issue-body change:

1. read the complete current body and comments;
2. record the pre-update body identity;
3. update only the authorized Issue;
4. read it back and verify the expected sections, links, and task semantics;
5. never delete PM comments to make the body appear cleaner.

GitHub does not provide one transaction spanning multiple Issues. A multi-Issue
governance edit is auditable when every Issue is verified individually and the
handoff enumerates the changed Issue numbers.
