# Repository constitution

## Scope and authority

- GitHub `main` is the canonical development base. Resolve its exact live SHA before implementation; planning-time SHAs are context, not authority.
- Change only files and external metadata authorized by the current Issue and active PM decisions. Preserve unrelated work and stop when a required change would exceed that scope.
- Read-only work does not authorize code changes, GitHub mutations, deployment, device access, BLE/controller commands, or other external writes.
- The parent/Goal agent is the sole writer unless the Issue explicitly says otherwise. Subagents are read-only and conditional on a concrete reduction in mapping, research, safety-review, or final-review risk.

## Skill routing

Load only the skills required by the current role and scope:

- normal implementation -> [`walkingpad-pr-lifecycle`](.agents/skills/walkingpad-pr-lifecycle/SKILL.md);
- any code writing/fix/refactor -> also [`walkingpad-minimal-code`](.agents/skills/walkingpad-minimal-code/SKILL.md);
- independent Draft PR / PM review -> [`walkingpad-pr-review`](.agents/skills/walkingpad-pr-review/SKILL.md); code diffs also use `walkingpad-minimal-code`;
- explicit or measured runtime-performance work -> also [`walkingpad-performance`](.agents/skills/walkingpad-performance/SKILL.md);
- native iOS visual/interaction redesign -> also [`walkingpad-ios-redesign`](.agents/skills/walkingpad-ios-redesign/SKILL.md);
- safety-critical runtime/control/telemetry/persistence change -> [`walkingpad-safety-change`](.agents/skills/walkingpad-safety-change/SKILL.md);
- physical treadmill/controller experiment -> [`walkingpad-hardware-experiment`](.agents/skills/walkingpad-hardware-experiment/SKILL.md);
- read-only capture/evidence analysis -> [`walkingpad-evidence-analysis`](.agents/skills/walkingpad-evidence-analysis/SKILL.md).

Do not preload unrelated skills. Detailed context ownership lives in [`docs/engineering/codex-github-workflow.md`](docs/engineering/codex-github-workflow.md).

## Context discipline

- Default working context is the current Issue/task, active PM decisions, directly relevant canonical docs, and current code/tests.
- Read predecessor Issues, PRs, commits, archived notes, broad docs, or long logs only to resolve a concrete ambiguity.
- Do not repeat repository rules, lifecycle steps, successful logs, or history in launch prompts and Issues. Link to canonical owners and summarize evidence.
- Review base-to-head diffs, not implementation transcripts. Corrections start from the exact finding and changed delta.

## Treadmill safety invariants

- Ordinary implementation and design work must not connect to a treadmill or send BLE/controller commands.
- Stop/start/speed behavior, command retries and confirmation, controller units/preferences, HR safety gates, persistent BLE writes, telemetry semantics, and persistence behavior are safety-critical. Change them only through `walkingpad-safety-change` with an explicit PM-approved behavior contract.
- Real controller experiments require `walkingpad-hardware-experiment` and a separate PM-approved experiment contract. Never infer hardware authority from implementation scope.
- A PM-approved controller unit/preference change is allowed only through the safety-change workflow. Any physical validation additionally requires a fixed packet whitelist and read-back verification in its own approved hardware-experiment contract.
- Do not use or promote arbitrary `raw`/`seq` commands, unknown packet replay, service-menu writes, silent controller-unit changes, firmware/OTA actions, or unlock attempts.
- Debug and simulator paths must not bypass production safety gates. Missing, stale, or ambiguous telemetry is not proof of a safe stopped state or valid unit semantics.

## Repository boundaries and verification

- Never commit secrets, pairing material, device identifiers, private health/workout exports, local captures, or generated diagnostic logs.
- Governance/docs-only work must not touch Swift runtime sources, Xcode project settings, BLE Python tools, command helpers, or runtime persistence code unless the Issue explicitly authorizes them.
- Run the narrowest applicable checks and report only commands actually run. Standard safe checks include:
  - `python3 -m compileall scan_ble.py run_live_stats.py run_menu.py run_workout.py tools/mcp_xcode_server.py`
  - `python3 scripts/check_codex_governance.py`
  - `cd ios/WalkingPadRemote/WalkingPadRemote && swift test`
  - unsigned generic builds only when app/project changes require them.
- A build never authorizes install, launch, BLE, or hardware activity.

## Documentation map

- Codex/GitHub ownership and thin-prompt contract: [`docs/engineering/codex-github-workflow.md`](docs/engineering/codex-github-workflow.md)
- Telemetry V2 reading routes and precedence: [`docs/telemetry-v2/index.md`](docs/telemetry-v2/index.md)
- Swift/iOS extensions: [`ios/WalkingPadRemote/WalkingPadRemote/AGENTS.md`](ios/WalkingPadRemote/WalkingPadRemote/AGENTS.md)
- Contributor setup and checks: [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`ios/README.md`](ios/README.md)
- Security reporting: [`SECURITY.md`](SECURITY.md)
- Historical implementation notes: [`docs/archive/README.md`](docs/archive/README.md)
- Redesign state and decisions: [`docs/design/`](docs/design/)
