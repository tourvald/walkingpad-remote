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

Keep corrections in the existing Issue/chat/worktree/PR; load the finding and changed delta rather than replaying history. The [review skill](../../.agents/skills/walkingpad-pr-review/SKILL.md) owns review inputs and gates.

Skill triggers live in [root AGENTS.md](../../AGENTS.md#skill-routing). Load only the role/domain contracts needed for the current task.

## Model configuration and activation

The trusted project default in [`.codex/config.toml`](../../.codex/config.toml)
is `gpt-6-luna / max`. The owner may select `gpt-6.1-sol / medium` for the
parent in a supported client. Client/session overrides take precedence over
project defaults; prompt text alone does not switch models. Never silently
substitute another pair. Report effective root model/effort from client metadata
or status when available; otherwise mark them `UNVERIFIED`, not inferred from
TOML. Static validation of this PR does not prove activation in a new session.
Check activation in a fresh session in the trusted checkout; the current
session may retain earlier client settings.

The four existing [custom roles](../../.codex/agents/) have no model or effort
pins, and the project has no `[agents]` model/effort defaults. They inherit the
effective parent pair when spawned without overrides: Luna/max or Sol 6.1/medium.
Do not supply child model/effort overrides or mix pairs under one parent. Check
effective child settings from client metadata when exposed; report mismatches
and mark unavailable settings `UNVERIFIED` rather than assuming inheritance.
The project config caps concurrently open
helpers at three; the root also limits each assignment to **three helper
launches total**, including failed launches. Simple tasks remain root-only.

Official [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference),
[precedence](https://learn.chatgpt.com/docs/developer-settings), and
[subagent inheritance/permissions](https://learn.chatgpt.com/docs/agent-configuration/subagents)
confirm these static keys and inheritance rules. The client can reapply live
parent permission overrides when spawning a child, including Full Access.
Thus `sandbox_mode = "read-only"` in a role is a default, **not proof of effective
isolation**. Helper read-only behavior is an instruction/workflow contract; do
not require a permission-mode change or add probes, wrappers, or launchers to
claim a sandbox guarantee.

## Bounded helper research and independent review

The root alone writes, executes task mutations, publishes, and makes final
decisions. Optional helpers may answer distinct in-scope repository questions
or research public/official documentation. No recursive delegation. Helpers
must not edit files, mutate Git/GitHub, use authenticated mutation APIs, access
production/SSH, change configuration/packages, perform BLE/controller/device
work, or make external writes, even when runtime permissions permit them.

Before a helper read phase, the root freezes the exact source or base-to-head
diff and records HEAD, index, worktree, and untracked state. The root performs
no writes while helpers run. It verifies material findings, joins/closes every
helper, and rechecks that state before resuming writes. Further research needs
another frozen read phase within the same three-launch budget; no helper stays
active during a write phase. Unexpected mutation is a hard stop.

Prefer ChatGPT/GitHub for preparation, caller mapping, bug investigation,
public documentation, scope/privacy/safety analysis, and fresh independent PR
review when tools suffice. Codex still reads affected current code/contracts,
reproduces failures when practical, implements, and verifies. An internal
`scope_challenger` or `reviewer` is only a critique, never the independent
safety challenge, independent ChatGPT review, PM acceptance, or physical
evidence. Independent review requirements belong to
[walkingpad-pr-review](../../.agents/skills/walkingpad-pr-review/SKILL.md).

## Implementation Issue shape

Use the [implementation template](../../.github/ISSUE_TEMPLATE/codex-implementation.md) for task behavior, checks, non-goals, and active decisions. Link canonical contracts instead of copying lifecycle, safety, or review procedures.

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

## Anti-bloat evidence

For every code PR, use `python3 scripts/code_growth_report.py <base> <head>` as compact exact-diff evidence alongside `walkingpad-minimal-code`. Use `--narrow-bugfix` for narrow bug-fix Issues. The report separates production, tests, docs/governance, and tooling/config changes; lists new production files; and conservatively surfaces added durable state, timers/polling, abstraction declarations, and dependency/configuration paths.

The report is not a LOC score. Candidate matches require reviewer judgment. A narrow bug fix crossing >5 production files or >500 production LOC churn stops for PM unless the live Issue explicitly authorizes broad mechanical scope. New dependencies, persistence/schema/migration surfaces, production subsystems, or broad signing/project/configuration changes remain explicit PM-stop categories.

An authorized multi-Issue autonomous Goal records its Goal-start SHA and repeats the report from that SHA to current `main` after every three merged software Issues and at final completion. Inspect cumulative evidence for stranded intermediate code, duplicate owners, one-consumer abstractions, dormant state, and unjustified growth. Record findings in the relevant audit/follow-up Issue; cumulative review does not authorize opportunistic cleanup.

## Review, correction, and handoff

The [lifecycle](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md) owns implementation, verification, publication, and handoff; the [review skill](../../.agents/skills/walkingpad-pr-review/SKILL.md) owns independent review and PM merge gates. Use the [PR template](../../.github/pull_request_template.md) as the evidence packet. Keep one active executor assignment; only the root claims it and publishes a `## Codex result` linking that assignment.

Token usage is post-hoc evidence, not an arbitrary execution cutoff. Actual client limits are environment blockers to report, never permission to omit mandatory verification.

## GitHub metadata discipline

For an authorized Issue-body update, read the complete current body and relevant active comments, update only the authorized Issue, preserve comment history, and read the result back.
