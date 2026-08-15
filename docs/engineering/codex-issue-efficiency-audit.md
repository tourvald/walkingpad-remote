# Codex Issue efficiency audit

Status: Issue #45 governance audit against base
`de56b53de811af74a5b829212c64397aae0dd17f`.

## Finding

The base repeated the implementation lifecycle and numerical token-control
guidance in root instructions, the lifecycle skill, and child Issue bodies.
Telemetry V2 Issues #30-#36 also repeated the global invariant block, while
active task decisions lived only in later comments. The Epic checklist still
showed accepted Issues #26-#29 as open work.

That structure increased default context, made later decisions harder to find,
and risked treating token checkpoints as execution gates.

## Resolution

- Root `AGENTS.md` is the repository constitution and map.
- `walkingpad-pr-lifecycle` is the sole detailed implementation lifecycle.
- Token usage is observable after execution and does not control completion.
- Telemetry V2 cross-Issue rules live in canonical docs routed by
  [`docs/telemetry-v2/index.md`](../telemetry-v2/index.md).
- Child implementation Issues contain task-specific semantics, compact
  `Applicable contracts`, and linked `Current binding decisions`.
- Historical PM comments remain intact.
- Repository history is retrieved only for a concrete ambiguity.

## Durable acceptance checks

Run from the repository root:

```sh
python3 scripts/check_codex_governance.py
git diff --check
git diff --name-status <exact-base>...HEAD
```

For live Issues #30-#37, verify that each body contains `Applicable contracts`
and `Current binding decisions`, and that none contains the copied headings
`Global Telemetry V2 invariants` or `Binding execution contract`. Verify #22's
checklist and queue against current GitHub state.

The delivery audit must also confirm:

- no runtime Swift, Xcode project, BLE/control helper, or persistence-runtime
  file changed;
- local Markdown links in governance and Telemetry routing docs resolve;
- #30 says at most one observed frame per elapsed second, permits gaps, and
  prohibits backfill;
- #36 requires #37 `GO FOR LEGACY RETIREMENT` or a named PM waiver;
- #37 remains a read-only real-evidence gate;
- exact-head required CI is successful.

Live GitHub body identities and post-update verification belong in the PR
handoff because they can change independently of the repository.

## Issue #45 metadata update evidence

Each authorized body was updated only after its live pre-update SHA-256 matched,
then read back byte-for-byte and checked with the original PM comment count
unchanged. Hashes below use the UTF-8 body returned by GitHub without its trailing
newline.

| Issue | Pre-update SHA-256 | Post-update SHA-256 | Comments preserved |
| --- | --- | --- | ---: |
| #22 | `4f1d9eb00b02ba5c0540b79874103fd67ef959d337a53bb2a24a889c947c609a` | `364a0e9b46bb6360463d22613f581849388a001e338a284d8d324ec8f90c3416` | 5 |
| #30 | `c7aed6fe7634e61425683520c604c58d0105724be2ae7a727a88127fb80b2b85` | `ac9ff74f2e4e73b808686887710f4f16e42323c05aa03d155892aeb13016c517` | 6 |
| #31 | `ed1a836cc27b8cc1eba4bbdeed28a18ad1d1b64708591aaf6ac1992a007c4607` | `1da82e902bf997e1f9aa689a85834d1aef9dd445ea7fda0f178f69d692df4dff` | 1 |
| #32 | `c3639a339fef8ccdf116909ed6b7e054ff23f83ee3fbc0740954b580834d6d36` | `0e5f653420d01d15ec32623d7a0f86474504b887580d15c1029f995ed8f08eb8` | 1 |
| #33 | `7d42764ef6e284738e811a27f17dfb6aa6557b8b1fa1ca791d7593648c4abf52` | `2298018382042990ca9c31801000676a4f489be77c14cdeade33fe8294b84654` | 3 |
| #34 | `f976f287e5315dbe630a0a4097a63c7ed74e93bd02800b760838a331d64a838d` | `1d24ab8ffc8a67a144ec369bc50cc66cebb3e61d8c069faee6730059c8fd4d3d` | 3 |
| #35 | `38897b2a4947895d19e11eb9c232d440822efaea42c763a8800930408cd767c0` | `5e0b39a4e6a951c3e0008e25d46afa786c770239b6ea580cd17db4b7e6489f81` | 3 |
| #36 | `9a3fd30981094ac1333aa42d233f16dd3598cbe2e59d244a12a01e071c60a306` | `572d3b6b2fddd0ed4a6e3eae2b491403ddedb9833beac55de7d11da4463bfbde` | 3 |
| #37 | `5d4244aa8785407190e405e1e0d78f1af0d17589f105167fb45129584ab042c8` | `f5ff2efd6465b76b64026c4431c9f711c0cea50419a6e683fdcb8f78f606f8a3` | 2 |

Every linked `Current binding decisions` comment was resolved through the live
GitHub API after the update. The live queue was also checked: #23, #39, and
#26-#29 are closed; #45 and #30-#37 are open.
