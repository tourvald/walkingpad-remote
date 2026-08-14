# Telemetry V2 persistence and retention

Status: normative storage, privacy, and retention contract.

## Provisional persistence decision

Telemetry V2 is SwiftData-first, using a versioned schema and explicit migration
plan. This is a provisional architecture decision, not a permanent technology
commitment. SwiftData MUST pass the automated scale, recovery, protection, and
migration gate in issue #26 before production integration proceeds.

The store MUST be local-only:

- no CloudKit, backend, synchronization, or network write;
- no persistence context exposed to control, provider, transport, view, or
  export code;
- injected in-memory and on-disk configurations for tests;
- one repository/store boundary and one isolated production writer.

Apple documents `ModelActor` as serializing work on its model context. An
implementation SHOULD use `@ModelActor` or an equally official SwiftData
isolation primitive. It MUST NOT infer undocumented cross-context, sidecar, or
rollback guarantees; those behaviors require tests. See
[`ModelActor`](https://developer.apple.com/documentation/swiftdata/modelactor),
[`ModelContainer`](https://developer.apple.com/documentation/swiftdata/modelcontainer),
and [`SchemaMigrationPlan`](https://developer.apple.com/documentation/swiftdata/schemamigrationplan).

## Schema and transaction rules

- Every schema version and migration stage MUST be explicit and testable.
- Query paths for session chronology, session elapsed time, event kind/time,
  source/sample identity, and analysis version MUST have measured index support.
- Uniqueness MUST use real stable identity. Missing identity MUST NOT be replaced
  by fuzzy matching or lossy deduplication.
- The schema MUST use separate conceptual records from the
  [data contract](data-contract.md), not a universal nullable table.
- Static configuration MUST be stored once per immutable snapshot and referenced,
  not repeated in every frame.
- The background writer's incidental autosave MUST be disabled. Batches MUST use
  explicit save/transaction boundaries and expose success/failure accounting.
- Previously committed batches MUST survive an interrupted session. Recovery
  MUST mark an incomplete tail honestly; it MUST NOT invent completion.

Apple's `ModelContext.transaction(block:)` performs the block and saves pending
changes, but this specification does not assume undocumented ACID rollback
semantics. Failure and reopen behavior MUST be verified with the concrete schema
and store. See
[`transaction(block:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)).

## Store location, protection, and backup

The production store MUST live in an application-owned support directory, not a
temporary/export location. The selected policy is:

- `completeUntilFirstUserAuthentication` file protection for the SQLite store
  and every discovered WAL/SHM/sidecar file;
- exclusion from device/cloud backup for the store and every discovered sidecar,
  preserving the product's local-only boundary;
- reapplication and verification after create, write, close, reopen, migration,
  replacement, and other file operations that can change resource attributes.

`completeUntilFirstUserAuthentication` keeps a protected file unavailable until
the first unlock after boot and available after subsequent locks. Backup
exclusion and protection are per-resource properties; coverage of SQLite
sidecars MUST be measured rather than assumed. See
[`URLFileProtection.completeUntilFirstUserAuthentication`](https://developer.apple.com/documentation/foundation/urlfileprotection/completeuntilfirstuserauthentication)
and [`isExcludedFromBackupKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey).

Automated environments MAY report device-only lifecycle/protection checks as
`UNVERIFIED_ON_DEVICE`. Each such item MUST be carried by name to gate #37 and
MUST NOT be reported as passed.

## Retention classes

| Class | Examples | Retention rule |
| --- | --- | --- |
| training evidence | sessions, sources, native HR/treadmill samples, causal/lifecycle/safety events, frames, immutable configuration | MUST NOT be automatically deleted, sampled away for storage targets, or deleted by export |
| derived analysis | versioned analyses and quality grades | MAY be recomputed or superseded only when evidence remains intact and analyzer/version provenance remains auditable |
| diagnostic chatter | optional raw BLE traces, verbose debug payloads, benchmark detail | MUST be a separate explicitly bounded store/class; it MUST NOT share training-evidence retention semantics |
| recorder health | pressure/loss/recovery counters and events without private payloads | MUST remain with the affected session when needed to interpret completeness |
| transient ingress | bounded in-memory records awaiting persistence | MAY be discarded only under the explicit pressure policy, with loss accounting; it is not a durable store |
| export artifacts | user-created CSV/archive/manifest projections | Are user-managed copies; creating or sharing one MUST NOT mutate the source store |

There is no time-, count-, or size-based automatic deletion of training evidence.
Deletion requires an explicit user action scoped to identified sessions/data, or
a separately approved migration/retirement step that has proved the replacement
contains the evidence. Destructive UI and debug actions MUST identify their
scope, require confirmation where appropriate, and remain outside control paths.

Diagnostic chatter MUST have a documented byte/count/age bound before it is
enabled. Oldest-first deletion is permitted only inside that class. Raw BLE
payloads MUST NOT be copied into training events, unified logging, MetricKit, or
repository fixtures containing private data.

## Failure behavior

- Store construction, migration, save, protection, or reopen failure MUST fail
  telemetry closed: record/report degraded telemetry health when possible,
  preserve committed evidence, and keep control running independently.
- Persistence MUST NOT block control, authorize motion, trigger a command, or
  weaken start/stale-HR/speed/units/disconnect/cooldown/manual-stop/stop gates.
- The buffer MUST remain bounded. Unavoidable loss MUST be classified and make
  the session incomplete when critical evidence may be missing.
- Read or export failure MUST surface an explicit error and MUST NOT silently
  substitute legacy data after V2 read cutover.
- Corrupt or unknown records MUST be quarantined/preserved for diagnosis when
  safe; they MUST NOT be silently rewritten as valid facts.

## SwiftData gate and Core Data fallback trigger

Issue #26 MUST exercise the concrete schema at CI scale and at a configurable
full profile of roughly 1,000 workout-hours/several million records. Results are
classified `PASS`, `FAIL`, or `UNVERIFIED_ON_DEVICE` using the methodology in
[performance-budget.md](performance-budget.md).

A material failure in any of the following blocks later runtime integration:

- isolation from the main/control path;
- bounded insert/query/memory/storage behavior at the measured workload;
- reopen after interruption and preservation of committed batches;
- schema migration viability;
- protection or backup-exclusion policy for the store and sidecars;
- deterministic uniqueness, relationship, or deletion behavior.

On a material failure, #26 MUST stop for PM decision with measured evidence and
a narrow SwiftData-versus-Core Data recommendation. It MUST NOT silently
downsample native evidence, add hidden stores, switch persistence technology, or
weaken the contract. A Core Data fallback requires explicit PM approval and MUST
still satisfy every semantic, isolation, privacy, retention, migration, and
safety requirement in this specification.
