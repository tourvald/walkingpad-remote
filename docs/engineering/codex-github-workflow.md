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
reproduces failures when practical, implements, and verifies. Outside an explicitly owner-activated autonomous Goal, an internal
`scope_challenger` or `reviewer` is only a critique. Under the autonomous exception below,
a frozen-diff reviewer may satisfy only the non-safety code-review gate. It never replaces
a safety challenge, physical evidence, or other external approval required by the Issue.
Independent review requirements belong to
[walkingpad-pr-review](../../.agents/skills/walkingpad-pr-review/SKILL.md).

## Decision authority and autonomy modes

Autonomy is defined by **authority, reversibility, and risk**, not by whether a
decision feels important. When the current Issue and repository contracts
already determine the required behavior, the root should make ordinary
engineering decisions itself. Human/PM involvement is required when continuing
correctly needs **new authority**, not merely because several technically valid
implementations exist.

The modes below describe the maximum autonomy available after all more-specific
repository/Issue rules are applied:

| Mode | Meaning | Terminal behavior |
| --- | --- | --- |
| **A0 — autonomous discovery / non-behavioral completion** | Read-only discovery, evidence work, or no-code disposition explicitly authorized by the Issue. | May complete/disposition autonomously when the Issue defines sufficient evidence. |
| **A1 — reviewed autonomous implementation** | `goal:ready` work inside an explicitly owner-activated autonomous Goal. | Implement, verify, obtain required frozen-diff review, correct in-contract findings, and self-merge only through every #170/#171 gate. |
| **A2 — human merge gate** | `goal:human-gate` work or any task downgraded by a more-specific human-stop rule. | Perform the full engineering/review/correction loop, then leave one verified Draft as `BLOCKED FOR PM REVIEW`; do not Mark Ready or merge. |
| **A3 — PM decision required** | Continuing would require authority that the current contract does not provide. | Stop at `BLOCKED FOR PM DECISION` with the smallest missing decision stated precisely. |

Classification does **not** activate a Goal or grant merge authority by itself.
A1 self-merge exists only under the explicit owner-activated Goal contract
below. Repository instructions, subsystem safety rules, the live Issue, active
PM decisions, #170 tripwires, or #171 human-stop categories may always downgrade
autonomy. The root may never upgrade a human-gated task on its own.

### Decisions Codex should make without PM relay

When behavior is already authorized, the root should decide and proceed on:

- implementation structure, naming, local abstractions, algorithms, and data structures;
- ordinary refactors required to satisfy the Issue while preserving contracts;
- deterministic tests, fixtures, and focused verification strategy;
- bounded performance/cache/buffering choices that do not change product/data semantics;
- reviewer-requested corrections whose required behavior is already determined;
- whether a bounded read-only mapper/researcher/challenger is useful;
- ordering of focused checks and documentation needed to describe the implemented contract.

Do **not** ask PM to choose between implementation A and B merely because both
are plausible. When evidence can decide, gather evidence and decide. When tests
can freeze an already specified behavior, write the tests and decide.

A reviewer `FIX` is normally another input to the same Goal: correct the
finding inside scope, rerun the invalidated checks, and obtain fresh review for
the corrected exact head when required. Escalate only when the finding itself
requires new authority or triggers an existing #170/#171 human stop. Difficulty,
unfamiliar code, multiple good designs, or an arbitrary number of correction
loops are not PM-stop reasons by themselves.

### Mandatory authority hard stops

In addition to every existing #170/#171 stop category, request a binding PM
decision when continuing requires any of the following:

1. **New product semantics** — the contract does not determine materially different user-visible behavior.
2. **Safety authority change** — expanding/weakening a safety envelope, changing fail-closed/fail-open behavior, motion/Stop authorization, device-truth requirements, or another safety invariant.
3. **Destructive or unreconstructable user-data action** — deletion, destructive migration/backfill, or rewrite whose truth cannot be recovered safely.
4. **Privacy/security/trust-boundary change** — new permissions, credential scope, secret handling, external data sharing, health/privacy semantics, authentication, or materially broader exposure.
5. **Production, hardware, or external irreversible action** not already explicitly authorized.
6. **Unauthorized scope expansion** into behavior owned by another Issue/subsystem or an adjacent problem not required for completion.
7. **Contradictory authoritative requirements** that cannot all be satisfied.
8. **Factual/causal ambiguity** that would require fabricated provenance, identity, measured truth, safety state, or certainty.
9. **Unavailable mandatory evidence** required by the acceptance/safety contract.
10. **Invalidating base drift** that changes task meaning and cannot be resolved mechanically inside the existing contract.

Git-backed code changes are usually reversible and therefore good candidates
for autonomous engineering judgment, but reversibility never grants authority
to change safety, privacy/security, destructive-data, production, or product
semantics.

## Implementation Issue shape

Use the [implementation template](../../.github/ISSUE_TEMPLATE/codex-implementation.md) for task behavior, checks, non-goals, and active decisions. Link canonical contracts instead of copying lifecycle, safety, or review procedures.

### Goal eligibility

The Issue's `Goal eligibility` block is the single readiness source. Use the values below; the `goal:` names identify the classes, not a second label-based authority. Labels would duplicate the required metadata without adding an execution gate, so no label management is needed. Missing or unsettled classification stays in ordinary manual PM/specification work. Classification never activates a Goal or grants merge authority.

| Class | Issue value | Eligibility |
| --- | --- | --- |
| `goal:needs-spec` | `needs-spec` | **A3.** Resolve product, UX, architecture, safety, evidence interpretation, or schema decisions manually before unattended execution. |
| `goal:ready` | `ready` | **A1 when an owner-activated Goal grants authority.** Explicit behavior, objective acceptance checks, known dependencies, programmatically available evidence, bounded allowed/forbidden scope, no unresolved product decision or physical/device/user interaction, and eligibility for self-merge under the autonomous contract below. |
| `goal:human-gate` | `human-gate` | **A2.** Deterministic authorized investigation/implementation, review corrections, and verification may proceed, but a mandatory human-stop category requires final PM review. Leave a verified Draft as `BLOCKED FOR PM REVIEW`. |
| `goal:blocked` | `blocked` | **A3 / externally blocked.** A named unmet prerequisite prevents useful progress: predecessor, physical/field evidence, external source/permission, or owner decision. Exclude it from the active batch. |

Use `needs-spec` for contract definition; use `blocked` when a concrete prerequisite prevents progress. A human-gated task with unavailable evidence is blocked until that evidence is available; classification cannot waive a gate. Keep dependencies in the same block, name the verification surface, explicitly allow or forbid no-code completion, and record task-specific human stops. Product semantics and acceptance evidence remain in the existing Issue sections.

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

## Owner-activated autonomous Goal mode

The ordinary lifecycle still ends at a verified Draft PR. A Goal may continue through review, merge, Issue disposition, and the next Issue only when the repository owner explicitly launches it under this section.

Activation must record the exact Goal-start `main` SHA, a fixed Issue completion-set, autonomous merge authority, and any human-gated Issues. One root owns writes, works one Issue at a time from fresh live `main`, and does not recursively add newly discovered follow-up Issues to the active completion-set. A new P0/P1 may block the affected task but does not silently broaden scope. A P0/P1 that invalidates safety, data integrity, or the correctness of already merged Goal work stops the entire Goal for PM; it cannot be deferred as routine backlog.

Before an autonomous merge, implementation and review are distinct phases. Freeze exact base/head and worktree state; stop writes during the review; review the complete diff and live Issue decisions rather than the implementation transcript; use a separate bounded read-only reviewer when available; verify exact-head CI and the code-growth report independently; and obtain a fresh `GO`. In this explicitly activated mode only, that frozen-diff reviewer may satisfy the ordinary independent **code-review** gate for non-safety, non-human-gated work. It never substitutes for a safety challenge, physical evidence, or an external approval required by the Issue.

A Goal may self-merge only a fixed-set Issue with explicit product semantics when live base/head, mergeability, exact-head CI, review, and #170 anti-bloat evidence are all clean. Use an expected-head merge guard and verify the resulting `main`.

Stop that Issue for human/PM review instead of self-merging if it touches treadmill safety/control (including Start, Stop, speed, cooldown, controller units or BLE command semantics), triggers `walkingpad-safety-change`, requires physical evidence, changes persistence schema/migration/destructive user-data or rollback behavior, adds an external dependency, changes signing/entitlements/project-wide configuration/deployment, creates a production framework/subsystem/architecture boundary, crosses an unresolved #170 tripwire, has ambiguous product semantics, lacks independent `GO`/green exact-head CI, or needs unavailable external authority/evidence. A human-gated Issue may still reach a verified Draft PR and then the Goal may continue to another independent eligible Issue.

Eligible no-code investigations may be dispositioned and closed when their live Issue explicitly defines that outcome. Externally blocked Issues remain open. New audit findings may create focused follow-up Issues, but those are outside the current Goal unless a later owner launch includes them.

Every autonomous code PR uses #170 evidence. Preserve the Goal-start SHA; after every three autonomous merges and at final completion, review Goal-start -> current-`main` growth for stranded intermediate code, duplicate owners, one-consumer abstractions, dormant state, and unjustified growth. This review records follow-ups; it does not authorize opportunistic cleanup.

#170 and #171 are bootstrap changes and are never merged using this exception; both require the ordinary human-reviewed lifecycle first.

## Nightly Goal Batch

During the day, PM resolves `needs-spec` contracts and names blockers. Before an unattended run, read the fresh live backlog and binding decisions; select a small dependency-ordered set of explicitly classified `ready` / `human-gate` Issues, including bounded audit/disposition tasks with explicit completion evidence. Exclude blocked work and dependants whose prerequisites cannot be completed within the batch. Do not sweep the entire backlog.

The owner's launch records:

```text
Repository: tourvald/walkingpad-remote
Mode: Nightly Goal Batch under owner-activated autonomous Goal mode
GOAL_START_SHA: <exact live main SHA>
Completion-set: #<N>, #<M>  # fixed, dependency ordered
Autonomous merge authority: only eligible ready Issues under #170/#171
Human-gated Issues: #<M>  # or none
Follow Issue eligibility + repository contracts. Report the cumulative result.
```

This is a standard launch format for the activation contract above, not a scheduler or an implicit activation. The owner must explicitly grant that authority. Recheck eligibility and prerequisites against the live Issue before each task; changed classifications do not expand the fixed completion-set or authority.

Execute one Issue at a time from fresh `main`: investigate/implement -> focused and applicable full checks -> #170 growth evidence -> Draft PR -> frozen-diff review -> bounded corrections and fresh review/CI for the corrected head -> exact-head CI -> self-merge only through #171 -> verify resulting `main` -> linked Issue disposition -> next eligible Issue. The lifecycle and review skills own the detailed gates; no-code completion requires the Issue's explicit acceptance contract.

For `human-gate`, stop at a verified Draft and frozen review with `BLOCKED FOR PM REVIEW`, then continue only to an independent eligible Issue. Do not treat that Draft as a merged prerequisite. Record blocked dependants rather than forcing progress. Leave unavailable-evidence and externally blocked Issues open. Audit findings may become focused follow-up Issues, but never enter this active completion-set recursively. Preserve the P0/P1 whole-Goal stop above and #170 per-PR/cumulative checks.

### Reconciliation pass

Keep an incomplete/blocked ledger containing only Issues from the fixed completion-set. After each Issue reaches its current terminal outcome, and once again before the final Morning PM handoff, re-read fresh live state for ledger entries whose blocker or prerequisite could have changed during the run.

Resume an Issue automatically when its blocker is now removed and every required dependency is satisfied by fresh live state. A human-gated Draft does not satisfy a merged prerequisite; if PM merges or otherwise resolves that gate during the run, re-read fresh `main` and the live Issue before resuming dependants.

Use the Issue's current explicit classification and binding PM decisions when resuming. If it remains A2/`human-gate`, perform the authorized engineering/review/correction loop and leave the verified Draft at its human gate. If a later explicit binding PM decision reclassifies it to A1/`ready`, and the original Goal launch grants autonomous merge authority for eligible ready Issues, the normal A1 review/CI/self-merge gates apply. Root may not infer or self-grant that upgrade.

Reconciliation never expands the fixed completion-set, never recursively executes follow-up Issues, never treats silence as PM approval, and never bypasses A3 hard stops, unavailable mandatory evidence, or the P0/P1 whole-Goal stop.

## Morning PM Pass

Review the overnight result as a system using one compact final handoff linked to the existing PR/Issue evidence:

- Exact `GOAL_START_SHA` and verified final live `main` SHA.
- Fixed completion-set outcomes: merged/closed/dispositioned Issues, no-code evidence, incomplete or blocked tasks and reasons.
- Human-gated Draft PRs awaiting PM, with exact heads and review/CI evidence.
- Follow-up Issues created by audits/findings, outside the batch.
- Cumulative #170 report from Goal-start to final `main`, including stranded intermediate code, duplicate owners, one-consumer abstractions, dormant state, and unjustified growth.
- P0/P1 findings, Goal stop conditions, and any missing evidence.
- Whether remaining backlog eligibility/dependencies are still accurate.

The owner/PM may accept a clean batch without replaying every successful PR review or full test suite while exact-head evidence remains valid. Apply the lifecycle verification rule when changes or findings invalidate that evidence. Waiting human-gated Drafts still require their own PM decision under the review skill; accepting the batch does not merge them. Cumulative findings authorize follow-up planning, not opportunistic cleanup or another Goal.

## Review, correction, and handoff

The [lifecycle](../../.agents/skills/walkingpad-pr-lifecycle/SKILL.md) owns implementation, verification, publication, and handoff; the [review skill](../../.agents/skills/walkingpad-pr-review/SKILL.md) owns independent review and PM merge gates. Use the [PR template](../../.github/pull_request_template.md) as the evidence packet. Keep one active executor assignment; only the root claims it and publishes a `## Codex result` linking that assignment.

Token usage is post-hoc evidence, not an arbitrary execution cutoff. Actual client limits are environment blockers to report, never permission to omit mandatory verification.

## GitHub metadata discipline

For an authorized Issue-body update, read the complete current body and relevant active comments, update only the authorized Issue, preserve comment history, and read the result back.
