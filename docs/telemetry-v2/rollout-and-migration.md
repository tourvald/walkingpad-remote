# Telemetry V2 rollout and migration

Status: normative sequential delivery, cutover, rollback, and deletion contract.

## Sequential queue

Implementation issues MUST run in this order. Each starts from the then-current
exact GitHub `main` only after its predecessor has been PM-reviewed, merged, and
closed. No implementation issue runs in parallel.

| Stage | Issue | Required exit |
| --- | --- | --- |
| Contract | #23 | This repository-owned specification is accepted |
| Foundation | #39 | Phase A checkpoint proves the persistence-independent typed domain; Phase B then adds the unwired versioned local SwiftData V1 store in the same Draft PR |
| Architecture gate | #26 | After #39, automated scale/recovery/protection evidence is accepted and device-only items are named |
| Recorder | #27 | Constant-time ingress, bounded buffering, batching, and loss accounting |
| HR truth | #28 | Native HR evidence normalized without changing controller arrival behavior |
| Treadmill/command truth | #29 | Factual observations, estimates, desired values, and command lifecycle separated |
| Session/dual-write | #30 | Session lifecycle and observed frames integrated; legacy remains product source |
| Instrumentation | #31 | Privacy-safe metrics and soak harness |
| Parity/replay | #32 | Deterministic V2/legacy comparison and control-output replay gate |
| Analysis | #33 | Versioned timestamp-weighted analyzer and quality grading |
| Import | #34 | Idempotent conservative import and reconciliation |
| Read cutover | #35 | V2 is the only product read source; legacy writer remains shadow-only |
| Physical evidence | #37 | PM/user-supplied real evidence yields `GO FOR LEGACY RETIREMENT` or named blockers |
| Retirement | #36 | Legacy writers/reads/pruning are deleted only after #37 GO or explicit PM waiver |

Issue #36 MUST NOT start merely because #35 merged or automated parity passed.

## Write and read authority by phase

| Phase | Canonical new evidence | Product reads | Legacy role |
| --- | --- | --- | --- |
| Before #30 | legacy paths | legacy paths | current source of truth |
| #30 through #34 | V2 evidence is written and evaluated alongside legacy | legacy paths | compatibility/parity source while V2 is shadow-evaluated |
| After #35, before #37/#36 | V2 | V2 only | isolated temporary shadow-write for real parity/rollback evidence; never a read fallback |
| After #36 | V2 only | V2 only | no production writer/read/pruning/export-delete path; importer only for the documented compatibility window |

Dual-write is a temporary migration mechanism, not two sources of truth. Both
writes MUST consume the same immutable typed ingress record where architecture
allows. Legacy conversion failure MUST NOT mutate V2 evidence. V2 failure MUST
be recorded and MUST NOT block control or cause the legacy result to be labeled
successful V2 persistence.

The #30 V2 session MUST begin only after the existing production start gates
authorize the current workout session. Telemetry session creation is an
observation of that result, never an input to the authorization.

## Parity and replay gate

Before read cutover, issue #32 MUST prove with deterministic fixtures/replays:

- native observations and exact events retain timestamps, provenance, units,
  arrival order, and causal IDs;
- no frame is backfilled across a gap;
- factual speed is never replaced by desired, commanded, or estimated speed;
- duplicate/out-of-order HR is preserved and quality-flagged;
- timestamp-derived durations/integrals use explicit freshness/gap rules;
- telemetry enabled/disabled produces identical control outputs for identical
  replay inputs;
- recorder loss, incomplete sessions, and unsupported legacy ambiguity are
  visible rather than silently normalized.

Automated parity is necessary but not sufficient authority to retire the legacy
writer. Real-device facts remain for #37.

## Deterministic legacy import and reconciliation

Issue #34 owns import of legacy JSONL evidence and `workout_history_v1` summaries.
The importer MUST be versioned, idempotent, non-destructive, and auditable.

### Source identity

Each source item MUST receive an import identity derived from an immutable source
namespace plus a stable source identifier when one exists. Suitable identifiers
include an explicit session ID, HealthKit workout UUID, or a content fingerprint
used to identify the exact source item. The importer MUST record source kind,
locator/fingerprint, importer version, and result.

Repeating the same importer version on the same exact source item MUST NOT create
another V2 record. A content fingerprint proves identity of that source artifact;
it does not by itself prove that a JSONL session and a `workout_history_v1` row
describe the same real workout.

### Cross-source reconciliation

JSONL and `workout_history_v1` reconciliation MUST attempt exact stable identity
in this order:

1. exact JSONL `workout_saved.workout_id` to `workout_history_v1` entry ID;
2. exact HealthKit workout UUID when both sources carry it;
3. exact stable legacy session ID or explicit cross-reference.

Sources MAY be joined into one session only when an identity above matches and
does not conflict. Timestamp proximity, similar duration, BPM, distance, or speed
MUST NOT be used as a destructive fuzzy merge key.

JSONL native/event evidence is authoritative for observations and events it
explicitly contains. `workout_history_v1` MAY fill missing session-summary
metadata but MUST NOT overwrite more specific timestamped evidence. Conflicting
values MUST retain both provenance/conflict facts and prefer the more specific
factual source for applicable projections rather than silently choosing a
number.

When stable cross-source identity is unavailable or conflicting:

- preserve the raw evidence import and legacy summary as separately provenanced
  records/candidates;
- mark reconciliation `ambiguous` or `conflict` with the compared fields;
- do not overwrite factual values or delete either source;
- exclude unresolved duplicates from automatic aggregate double-counting using
  an explicit query/quality policy;
- require a deterministic later rule or explicit user/PM resolution before
  collapsing records.

Incomplete or malformed tails MUST retain all parseable evidence, record the
failure boundary, and mark the session incomplete. Import success MUST never
delete or modify the legacy source. Ambiguous legacy `speed_actual_kmh` MUST be
imported as legacy-estimated/unknown rather than factual, and random/synthetic
steps MUST be excluded from scientific evidence with an optional warning count.

## Read cutover (#35)

Read cutover requires accepted SwiftData, recorder, replay/parity, analyzer, and
import gates. At its completion:

- V2 is the only user-visible source for history, statistics, charts, and export;
- new training evidence is canonical in V2;
- raw CSV and summary CSV are V2 projections, not independent stores;
- product failure is explicit and MUST NOT silently fall back to legacy values;
- export is non-destructive;
- the existing legacy writer remains isolated as a temporary shadow only for
  real-session comparison through #37.

The shadow writer MUST NOT gain product fields or features, drive UI/analysis,
delete V2 evidence, or become a permanent fallback.

## Physical real-evidence gate (#37)

Gate #37 consumes ordinary real workout evidence supplied by the user/PM for
read-only analysis. Codex MUST NOT install or launch the app, connect to a
treadmill, or send BLE/controller commands under this rollout. Any non-ordinary
physical experiment requires its own explicit hardware-experiment contract.

The gate MUST report `PASS`, `FAIL`, or `UNVERIFIED` for HR fidelity, treadmill
facts, causal command correlation, phase/cooldown/stop fidelity, recorder
completeness, timestamp-derived analysis, and carried device-only persistence
and performance items. A failure affecting safety, provenance, causality,
control parity, or unexplained critical loss blocks retirement. Every
`UNVERIFIED` item requires an explicit PM decision.

Issue #36 requires `GO FOR LEGACY RETIREMENT`, or a separate PM waiver naming
each remaining `UNVERIFIED` item and why retirement is acceptable.

## Rollback contract

- Before read cutover, V2 integration MAY be disabled without changing control;
  collected V2 evidence MUST be preserved for diagnosis.
- After read cutover and before retirement, rollback MAY restore the last
  compatible release only through an explicit release/PM decision. It MUST
  preserve V2 evidence and document whether temporary legacy shadow data is
  complete. Runtime read errors MUST NOT trigger an automatic legacy fallback.
- Schema migration failure MUST stop the V2 read/write transition, preserve the
  original store, and expose recovery status. It MUST NOT create an empty store
  and present it as successful migration.
- After legacy retirement, rollback MUST use a build that reads the accepted V2
  schema or an explicitly approved forward/backward migration. It MUST NOT
  resurrect obsolete pruning, export deletion, or a hidden dual-write path.

Every migration/cutover PR MUST document the last compatible app/schema version,
backup/evidence preservation, observable failure state, and bounded recovery
procedure.

## Deletion plan

Only issue #36, after its dependency gate, may remove production legacy paths:

- JSONL canonical writes and count-based pruning;
- export-triggered deletion;
- wide nullable training snapshots/CSV as runtime architecture;
- whole-file production history parsers;
- capped `workout_history_v1` persistence after accepted import/cutover;
- synthetic factual metrics and sample-count-as-seconds summaries;
- obsolete legacy-only debug actions.

Deletion MUST be proven by a complete cumulative Epic diff and integrated checks.
The compatibility importer MAY remain only for a documented window and MUST be
separate from production writes. No private evidence is committed. A failed
gate, ambiguous destructive migration, base drift, or unresolved material
finding stops the rollout for PM decision.
