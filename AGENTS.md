# Repository contract

## Scope and authority

- GitHub `main` is the canonical development base. Resolve and record its exact current SHA before implementation.
- Use one issue, one `codex/...` branch, one isolated worktree, and one Draft PR. Never edit, reset, stash, clean, or otherwise reuse the user's dirty worktree.
- Change only files authorized by the issue. Preserve unrelated work and stop when a required change would exceed the approved scope.
- Read-only tasks may inspect repository files, logs, captures, and public documentation. They do not authorize code changes, GitHub mutations, device connections, or external writes.
- For implementation, the parent/Goal agent is the sole writer unless the issue explicitly authorizes another writer. Subagents are read-only and used only for bounded independent work that materially reduces risk.

## Delivery lifecycle

1. Read the complete issue and PM addenda; record scope, non-goals, exact base, done criteria, risks, and focused checks.
2. Fetch GitHub `main`, confirm the approved exact SHA, and create the isolated branch/worktree from it.
3. Implement the smallest in-scope change and run focused checks plus every applicable safe repository check.
4. Inspect the complete base-to-head diff for correctness, scope, safety, secrets, artifacts, and missing tests.
5. For substantial work, run one fresh independent read-only final reviewer. Fix in-scope material findings and repeat with a fresh reviewer, with at most two correction cycles before stopping for PM direction.
6. Push only the feature branch, open one Draft PR into `main`, re-check the live base and exact-head CI, and stop for PM review.

Implementation delivery stops at a Draft PR and must not mark it Ready or merge it. A later PM GitHub review may use the standing merge authorization below, but a Draft PR, reviewer result, or green local check alone is not authorization. Do not force-push, deploy, install, launch on a device, run hardware/BLE experiments, or make custom GitHub labels a delivery dependency.

Use [`walkingpad-pr-lifecycle`](.agents/skills/walkingpad-pr-lifecycle/SKILL.md) for normal implementation delivery. Report agent role, bounded task, effective model, reasoning effort, outcome, and any fallback. Default routing is Luna/medium for repository mapping or narrow documentation research and Terra/high for scope challenge or independent review; spawn only roles the task needs.

For substantial autonomous work, select `gpt-5.6-sol` with `high` reasoning for the parent/Goal agent when the client exposes parent model and effort choice. Use cheaper effort only for genuinely simple scoped work. If the client does not expose the selection or the preferred model is unavailable, do not claim it was selected; report the effective parent model, effort, and fallback in the handoff.

## Token and context efficiency

- Use these soft planning ranges unless a task supplies its own budget: about `200k-300k` tokens for small scoped maintenance or correction, `300k-500k` for a substantial feature, and `400k-600k` for large safety-critical work. For substantial tasks, checkpoint near `500k`; treat about `700k` as a soft ceiling, not a hard cutoff.
- A task-specific token budget or checkpoint supersedes these generic targets, but never weakens safety, review, build, or exact-head CI gates.
- At a checkpoint or soft ceiling, report usage when the client exposes it, state the concrete reason for any continuation, stop optional exploration, avoid new low-value agents, and choose a bounded completion path or escalate to PM. Never ship unsafe or knowingly incomplete work merely to save tokens.
- Use a subagent only when it materially reduces risk or review cost. Do not repeat accepted repository archaeology without a new reason; start correction work from the finding and relevant diff. Summarize long successful logs instead of reproducing them.
- Prefer focused tests while implementing and one full applicable suite after the change is coherent. Do not repeat a successful full suite or build unless a relevant change or failure justifies it.
- Give reviewers the contract, exact base-to-head diff, and concise evidence rather than a full transcript. Consult historical commits or files selectively and cite exact references.
- In the handoff, report final token and elapsed-time usage when available. Mark model, effort, token, or timing details as unverifiable when the client does not expose them.

## PM review and standing merge authorization

When a user hands a completed Codex Draft PR back to PM with a completion report and asks PM to review it on GitHub, that request is standing authorization for the same PM review turn to complete the merge only if PM's final verdict is explicitly `GO` or `APPROVED`. It does not let the implementation agent merge during delivery.

Under that authorization, PM may refresh the PR and live `main`, verify the exact base and head with no base drift, confirm required exact-head CI and any contract-required real app build, confirm there are no unresolved P0/P1 or material P2 findings, perform metadata-only PR cleanup, mark Draft as Ready, squash-merge with the exact expected head SHA, verify the new `main`, and verify linked issue closure (closing a completed linked issue if needed).

The standing authorization is cancelled when any of these conditions applies:

- the final PM verdict is not explicit `GO` or `APPROVED`;
- the PR head moved, the base drifted, or the merge is conflicted or non-clean;
- required CI is missing, queued, stale, cancelled, failed, or tests the wrong head;
- a required build is missing or failed;
- a P0, P1, material P2, reviewer finding, or scope finding remains unresolved;
- scope or safety was violated, or safety uncertainty requires an explicit decision;
- a more specific repository or task policy requires a separate `GO`.

Standing merge authorization never covers hardware/BLE/treadmill experiments or physical commands; installation or device launch unless explicitly in task scope; deployment or release; firmware, OTA, or service-menu actions; controller preference or unit writes outside their own approved contract; branch/tag deletion or destructive cleanup; force-push; or automatic work on the next issue. Each remains a separate gate.

## Treadmill safety invariants

- Ordinary implementation and design work must not connect to a treadmill or send BLE/controller commands.
- Stop/start/speed behavior, command retries and confirmation, controller units/preferences, HR safety gates, persistent BLE writes, telemetry semantics, and persistence behavior are safety-critical. Change them only through [`walkingpad-safety-change`](.agents/skills/walkingpad-safety-change/SKILL.md) with an explicit PM-approved behavior contract.
- Real controller experiments require [`walkingpad-hardware-experiment`](.agents/skills/walkingpad-hardware-experiment/SKILL.md) and a separate PM-approved experiment contract. Never infer authorization from implementation scope.
- Do not use or promote arbitrary `raw`/`seq` commands, unknown packet replay, service-menu writes, unapproved or silent controller unit changes, firmware/OTA actions, or unlock attempts.
- A PM-approved controller unit/preference change is allowed only through `walkingpad-safety-change`. Any physical validation additionally requires its own PM-approved `walkingpad-hardware-experiment` contract with an exact fixed packet whitelist and read-back verification.
- Debug and simulator paths must not bypass production safety gates. Missing, stale, or ambiguous telemetry is not proof of a safe stopped state or valid unit semantics.
- Use [`walkingpad-evidence-analysis`](.agents/skills/walkingpad-evidence-analysis/SKILL.md) for read-only JSONL/CSV, capture, protocol, and stop-forensics analysis.

## Repository boundaries and verification

- Never commit secrets, pairing material, device identifiers, private health/workout exports, local captures, or generated diagnostic logs.
- Keep runtime changes out of governance/docs-only tasks. In particular, do not touch Swift runtime sources, Xcode project settings, BLE Python tools, or command shell helpers unless the issue explicitly names them.
- Run the narrowest applicable checks and report only commands actually run. Standard safe checks are:
  - `python3 -m compileall scan_ble.py run_live_stats.py run_menu.py run_workout.py tools/mcp_xcode_server.py`
  - `cd ios/WalkingPadRemote/WalkingPadRemote && swift test`
  - unsigned generic builds only when app/project changes require them; a build never authorizes install, launch, BLE, or hardware activity.
- Before handoff, run `git diff --check`, inspect `git diff --name-status <base>...HEAD`, verify the exact live base and exact PR head, and confirm required CI is successful. Failed, missing, cancelled, queued, or stale required CI blocks `READY FOR PM REVIEW`.

## Documentation map

- Swift/iOS extensions: [`ios/WalkingPadRemote/WalkingPadRemote/AGENTS.md`](ios/WalkingPadRemote/WalkingPadRemote/AGENTS.md)
- Contributor setup and checks: [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`ios/README.md`](ios/README.md)
- Security reporting: [`SECURITY.md`](SECURITY.md)
- Historical implementation notes moved from the active instruction chain: [`docs/archive/README.md`](docs/archive/README.md)
- Redesign state and decisions: [`docs/design/`](docs/design/)
