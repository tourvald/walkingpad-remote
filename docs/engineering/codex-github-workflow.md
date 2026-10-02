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
| Compact PR evidence and execution observations | [PR template](../../.github/pull_request_template.md) | parallel audit forms and repeated handoff reports |
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

Read predecessor Issues, PRs, commits, archived notes, broad docs, or long logs only when a named ambiguity cannot be resolved from current authoritative sources. Use targeted file/log reads; summarize successful logs instead of reproducing them. Spawn a helper only for a distinct question or risk the parent is not already investigating; required independent review remains a distinct responsibility.

Use the linked PR evidence and complete base-to-head diff for review. Keep corrections in the existing Issue/chat/worktree/PR, starting from the exact finding and changed delta rather than replaying repository archaeology or implementation context.

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

## Model configuration and activation

The parent baseline lives in [`.codex/config.toml`](../../.codex/config.toml).
Required independent review and safety/scope challenge settings belong to
[`reviewer.toml`](../../.codex/agents/reviewer.toml) and
[`scope_challenger.toml`](../../.codex/agents/scope_challenger.toml).
[`repo_explorer.toml`](../../.codex/agents/repo_explorer.toml) and
[`docs_researcher.toml`](../../.codex/agents/docs_researcher.toml) retain their
lower-cost settings for concrete, bounded needs; do not spawn them by default.
This role allocation is a project decision, not an OpenAI requirement to use
one model everywhere. The parent remains the sole writer; helpers remain
read-only and non-recursive.

Checked on 2026-09-08 with the installed Codex CLI `0.153.4`:
[official model guidance](https://developers.openai.com/api/docs/guides/latest-model),
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference),
[configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence),
and [subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents).
Codex supports `model` and `model_reasoning_effort` in project config and
standalone custom-agent TOML. Responses request fields such as
`reasoning.effort`, `configuration_update`, and async tool declarations are
API features, not additional project config keys. No minimum client version
is asserted by this check.

CLI overrides take precedence over trusted project config (nearest directory
wins), then selected profile, user config, system config, and defaults.
Untrusted projects skip project config. For custom agents, the role file's
explicit model/effort overrides the values resolved from the spawn request,
`[agents]` defaults, and parent. No global subagent model default is added.
Start a fresh session in the intended trusted checkout and spawn fresh roles
after changing these files; an existing session or a ChatGPT model-picker
selection does not prove activation. Explicit client/session overrides must
be checked, not assumed to follow the project baseline.

Before rollout, record the client/version, exact checkout, effective
model/effort, selected role, and permission evidence from client metadata or
status in a bounded read-only check of the parent and required review roles.
Configured read-only defaults do not by themselves prove effective sandboxing:
the client can reapply live parent permission overrides when spawning.
Do not expand permissions or edit permission policy to make this check pass. Keep evidence concise and
exclude secrets and full transcripts. TOML parsing and governance/CI validation
prove static configuration only; record observed activation separately.

If required model/effort activation is unavailable, mismatched, or not exposed
by the client, mark it `UNVERIFIED`, identify the precise blocker, and request
a specific PM disposition: rerun in a supported client or explicitly approve
a named alternative model/effort and its limited scope. Never silently fall
back or count that required review as completed. Disclose helper fallback and
mark missing effective helper metadata `UNVERIFIED` as well. Rollout remains
blocked until required activation is observed or explicitly dispositioned by
PM; a statically valid Draft PR alone is insufficient.

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

The [review skill](../../.agents/skills/walkingpad-pr-review/SKILL.md) owns findings and simplicity review; the [lifecycle](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md#4-verify) owns verification and rerun conditions. Keep outcomes in the existing PR evidence packet.

Token usage is post-hoc evidence, not an arbitrary execution cutoff. Actual client limits are environment blockers to report, never permission to omit mandatory verification. Required full checks and exact-head CI remain mandatory regardless of context size or token use.

## GitHub metadata discipline

For an authorized Issue-body update, read the complete current body and relevant active comments, update only the authorized Issue, preserve comment history, and read the result back. One task should normally map to one Issue, one `codex/...` branch, and one Draft PR.
