# Codex and GitHub contract ownership

Status: canonical governance map for ChatGPT -> GitHub -> Codex development.

This document defines where project knowledge and workflow rules belong. It links to canonical owners instead of duplicating their procedures.

## Canonical owners

| Concern | Canonical owner | Keep out of |
| --- | --- | --- |
| Repository authority and treadmill safety boundaries | root [`AGENTS.md`](../../AGENTS.md) | Issue boilerplate and launch prompts |
| Normal exact-base implementation through one Draft PR | [`walkingpad-pr-lifecycle`](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md) | root instructions and Issue bodies |
| Minimal code discipline | [`walkingpad-minimal-code`](../../.agents/skills/walkingpad-minimal-code/SKILL.md) | docs-only work |
| Independent Draft PR / PM review and conditional merge | [`walkingpad-pr-review`](../../.agents/skills/walkingpad-pr-review/SKILL.md) | implementation context/transcripts |
| Evidence-based runtime optimization | [`walkingpad-performance`](../../.agents/skills/walkingpad-performance/SKILL.md) | ordinary changes without a measured/explicit performance goal |
| Native iOS redesign | [`walkingpad-ios-redesign`](../../.agents/skills/walkingpad-ios-redesign/SKILL.md) | non-UI work |
| Safety-critical runtime/control/data changes | [`walkingpad-safety-change`](../../.agents/skills/walkingpad-safety-change/SKILL.md) | ordinary UI/logic changes |
| Physical controller experiments | [`walkingpad-hardware-experiment`](../../.agents/skills/walkingpad-hardware-experiment/SKILL.md) | normal implementation/review |
| Read-only captures/evidence | [`walkingpad-evidence-analysis`](../../.agents/skills/walkingpad-evidence-analysis/SKILL.md) | code-writing tasks |
| Cross-Issue Telemetry V2 semantics | [`docs/telemetry-v2/`](../telemetry-v2/index.md) | repeated Issue boilerplate |
| Task behavior/tests/non-goals/hard stops | current Issue/task | global docs unless durable across tasks |
| Later task-specific decisions | linked PM/user comments plus integrated current body | rewritten/deleted comment history |
| Historical context | Git/Issue/PR history and archive | default launch context |

When authoritative current sources materially conflict, stop and surface the conflict rather than silently choosing one.

## Progressive disclosure

Start with the current Issue/task, active decisions, root/nested instructions, current code/tests, and only the skills/domain docs required by the current role.

Read predecessor Issues, PRs, commits, archived notes, broad docs, or long logs only when a named ambiguity cannot be resolved from current authoritative sources. Successful logs are evidence to summarize, not context to reproduce.

A review packet contains the task contract, exact base/head, complete base-to-head diff, changed-file scope, and concise verification evidence. A correction starts from the exact finding and changed delta rather than replaying repository archaeology or the implementation transcript.

## Task-to-skill routing

- code `implement`: `walkingpad-pr-lifecycle` + `walkingpad-minimal-code`;
- docs/governance-only `implement`: `walkingpad-pr-lifecycle` only;
- visual/interaction `implement`: add `walkingpad-ios-redesign`;
- explicit/measured runtime optimization: add `walkingpad-performance`;
- safety-critical implementation/review: add `walkingpad-safety-change`;
- physical experiment: `walkingpad-hardware-experiment` under its own authorization;
- evidence/capture investigation: `walkingpad-evidence-analysis`;
- `review`: `walkingpad-pr-review`; code diffs also use `walkingpad-minimal-code`.

Do not load all skills preemptively. A skill is conditional context, not a repository handbook.

## Implementation Issue shape

Implementation Issues contain task-specific material plus:

- goal and accepted behavior;
- required changes/tests;
- non-goals and definition of done;
- `Applicable contracts` linking only directly relevant owners;
- `Current binding decisions` linking later active decisions;
- task-specific hard stops.

Do not paste standard lifecycle, global safety/Telemetry invariants, or unrelated domain rules into each Issue. Use [`.github/ISSUE_TEMPLATE/codex-implementation.md`](../../.github/ISSUE_TEMPLATE/codex-implementation.md).

## Thin launch prompts

A launch prompt identifies repository, task, role, base policy, and terminal outcome. It points to the Issue and repository routing instead of copying them.

Normal implementation:

```text
Repository: tourvald/walkingpad-remote
Issue: #<N>
Role: implement
Base: live main  # or exact SHA when fixed
Follow Issue + AGENTS routing. Stop at one verified Draft PR.
```

PM review:

```text
Repository: tourvald/walkingpad-remote
PR: #<N>
Role: review
Review exact base/head via walkingpad-pr-review.
```

Only add an unusual task-specific hard stop when omission would be risky. Do not repeat the Issue body, global invariants, standard checks, or lifecycle steps.

## Review, correction, and handoff

Review uses exact base/head and the complete diff, not implementation transcripts. Findings identify priority, exact location/metadata, consequence, evidence, and smallest safe correction. After a correction, inspect the new delta and rerun only checks invalidated by the delta plus mandatory gates.

Implementation handoff is concise: Issue/PR, exact base/head, changed files, checks/CI, and remaining risks. Required full checks and exact-head CI remain mandatory regardless of context size or token use.

## GitHub metadata discipline

For an authorized Issue-body update, read the complete current body and relevant active comments, update only the authorized Issue, preserve comment history, and read the result back. One task should normally map to one Issue, one `codex/...` branch, and one Draft PR.
