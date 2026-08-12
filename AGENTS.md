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

Do not mark Ready, merge, force-push, deploy, install, launch on a device, or run hardware/BLE experiments without separate explicit PM authorization. A Draft PR, review result, or green local check is not that authorization. Do not make custom GitHub labels a delivery dependency.

Use [`walkingpad-pr-lifecycle`](.agents/skills/walkingpad-pr-lifecycle/SKILL.md) for normal implementation delivery. Report agent role, bounded task, effective model, reasoning effort, outcome, and any fallback. Default routing is Luna/medium for repository mapping or narrow documentation research and Terra/high for scope challenge or independent review; spawn only roles the task needs.

For substantial autonomous work, select `gpt-5.6-sol` with `high` reasoning for the parent/Goal agent when the client exposes parent model and effort choice. Use cheaper effort only for genuinely simple scoped work. If the client does not expose the selection or the preferred model is unavailable, do not claim it was selected; report the effective parent model, effort, and fallback in the handoff.

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
