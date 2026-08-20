# Telemetry V2 documentation index

Status: canonical reading routes and precedence map.

Use this index to load only the documents relevant to the current question. It
is not a second architecture summary.

## Precedence

1. The current Issue and linked active PM decisions own task-specific scope and
   accepted behavior. A later active decision supersedes stale Issue wording.
2. [`safety-boundary.md`](safety-boundary.md) owns cross-Issue safety and
   one-way-authority invariants.
3. [`data-contract.md`](data-contract.md) owns evidence, provenance, time,
   identity, general causal-proof, frame, and analysis semantics. Protocol- and
   runtime-specific association rules belong to their topic document.
4. Topic documents below refine those canonical contracts for their named seam.
5. Current code and executable regressions provide exact implemented names and
   evidence. They do not override a PM-approved behavior contract.

If these sources leave a safety- or scope-relevant ambiguity, stop for PM rather
than infer a rule from history. Read predecessor Issues/PRs/commits only to
resolve a concrete remaining ambiguity.

## Read when

| Question | Read |
| --- | --- |
| System components, dependency direction, or queue ownership | [`architecture.md`](architecture.md) |
| Motion/control isolation, Start HR Control availability, stop truth, or device-evidence limits | [`safety-boundary.md`](safety-boundary.md) |
| Evidence vocabulary, timestamps, provenance, causal identity, frames, or analyzer semantics | [`data-contract.md`](data-contract.md) |
| HR provider normalization, delivery identity, or control-use evidence | [`heart-rate-normalization.md`](heart-rate-normalization.md) |
| Treadmill factual truth, command/attempt IDs, legacy ACK/timeout/write-result uncertainty, or response association | [`treadmill-truth-and-command-lifecycle.md`](treadmill-truth-and-command-lifecycle.md) |
| Producer ingress, pressure classes, buffering, loss, drain, or recovery | [`recorder-ingress.md`](recorder-ingress.md) |
| SwiftData ownership, transactions, retention, protection, backup, or store failure | [`persistence-and-retention.md`](persistence-and-retention.md) |
| Hosted SwiftData scale/crash evidence and device-only carry-over | [`swiftdata-gate.md`](swiftdata-gate.md) |
| Performance targets, soak measurements, privacy-safe instrumentation, or tuning evidence | [`performance-budget.md`](performance-budget.md) |
| Issue #31 host measurements, A/B recorder decision, signpost catalog, or soak commands | [`issue-31-performance-report.md`](issue-31-performance-report.md) |
| Dual-write, parity, migration, cutover, physical gate, rollback, or retirement | [`rollout-and-migration.md`](rollout-and-migration.md) |
| Issue #32 parity categories, read-only inputs, report schema, or deterministic replay scenarios | [`issue-32-parity-validator.md`](issue-32-parity-validator.md) |
| Issue #33 Analyzer V1 inputs, timestamp holds, metrics, quality grading, causal coverage, or recompute lifecycle | [`issue-33-post-workout-analysis.md`](issue-33-post-workout-analysis.md) |

## Durable cross-Issue decisions

- Start HR Control UI availability remains based on the existing connected
  treadmill plus current/fresh visible HR rule. Telemetry health, readiness,
  persistence, analysis, migration, and evidence completeness never add an
  affordance gate. Existing non-telemetry runtime checks after a tap remain
  fail-closed. Canonical owner: [`safety-boundary.md`](safety-boundary.md).
- Canonical frames are observed materialized views, with at most one frame per
  elapsed second. Missing seconds remain gaps and are never backfilled.
  Canonical owner: [`data-contract.md`](data-contract.md).
- The accepted legacy runtime does not deterministically associate ACK, timeout,
  write-result, or a later factual response with a command attempt unless an
  independent proof exists. Unknown association remains explicit with nil IDs;
  proximity, queue order, targets, estimates, and frame state are not proof.
  Canonical owner:
  [`treadmill-truth-and-command-lifecycle.md`](treadmill-truth-and-command-lifecycle.md).
