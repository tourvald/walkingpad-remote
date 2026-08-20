# Telemetry V2 semantic parity and replay validator

Status: Issue #32 implementation note. The normative contracts in this directory
remain authoritative.

## Boundary

`TelemetryParity` is a read-only comparison layer above the legacy JSONL and
Telemetry V2 evidence stores. It never writes, repairs, reorders, backfills, or
deletes either source. It is not a controller, analyzer, migration tool, read
cutover, or physical-device qualification path.

The V2 reader consumes an already-open `TelemetryStore` through fetch-only APIs,
or immutable domain arrays supplied by a caller. The legacy reader consumes a
`Data` value or reads a JSONL URL without rewriting it. A caller validating an
offline production artifact must work from a copy rather than open the only
source artifact through a write-capable store factory.

## Semantic/asymmetric categories

The validator emits one deterministic result for each category:

- lifecycle;
- HR observations;
- phase and cooldown boundaries;
- configuration and versions;
- control decisions;
- factual treadmill observations;
- command lifecycle;
- timestamp-derived aggregates;
- stop and safety evidence;
- record integrity;
- causal association;
- physical-device truth.

Each category is `PASS`, `FAIL`, or `INCONCLUSIVE`. Findings retain one of these
separate classes rather than becoming a generic mismatch:

- `sourceLegacyLimitation`;
- `v2RecorderOrDataLoss`;
- `protocolRuntimeCausalAmbiguity`;
- `actualSemanticMismatch`;
- `unsupportedCausalEdge`;
- `deviceOnlyUnverified`.

Known legacy modelled speed, synthetic steps, sample-count-derived seconds, and
missing runtime version fields are not V2 targets. Comparable explicit facts are
still checked. When the legacy source cannot establish a category, that category
is `INCONCLUSIVE`; absence is not converted to zero, equality, or failure.
Invalid-checksum speed remains native evidence without being promoted to factual
speed. The legacy ACK-association limitation excludes only ACK/response ownership;
explicit timeout and write-result counts remain comparable.

The immutable-array V2 reader checks source event order before applying its
deterministic comparison sort, while typed HR/treadmill arrival order and frame
identity/gaps are checked independently.

Physical-device truth is always reported `INCONCLUSIVE` by this hosted gate and
does not downgrade an otherwise passing automated parity result. Issue #37 owns
physical evidence.

## Causal proof rule

ACK, timeout, write-result, and observed-response evidence remains factual even
when its command/attempt association is unknown. Honest unknown association has
nil command and attempt IDs and may pass factual integrity. Association coverage
is reported separately from factual outcome count.

The accepted runtime persists no independently verifiable proof token for a
specific outcome/command/attempt tuple. Therefore this validator accepts no
caller-supplied boolean or ID set as proof: every persisted specific ACK,
timeout, write-result, or observed-response edge currently fails as
`unsupportedCausalEdge`. A future protocol decoder would need its own reviewed,
independently verifiable proof representation before the validator could accept
such an edge. Timing, queue position, target or modelled speed, a frame, and
nearest/latest/oldest command are never proof.

## Timestamp-derived comparison

The Issue #32 gate recalculates only the bounded parity aggregates needed for the
comparison. It uses ordered HR evidence, explicit phase boundaries, configured
zone bounds, a five-second maximum freshness hold, and one-second default
rounding tolerance. It does not implement the Issue #33 analyzer or write an
analysis record.

## Deterministic replay

`DeterministicControlReplay.run(scenario:telemetryObserver:)` feeds the same
normalized harness observations through existing pure HR, speed-bound, and
cooldown helpers with the observer absent or present. The observer is write-only;
its state and disposition are never read by the replay decision. The harness has
no production transport and cannot reach BLE.

Required scenarios are:

- normal HR control;
- delayed HR;
- missing HR;
- overshoot/prediction;
- speed limits;
- disconnect;
- cooldown;
- stop;
- Start HR Control affordance versus post-tap runtime authorization.

Production formulas and branching remain inline in `BluetoothManager`. The
replay harness is test evidence assembled from the existing pure helpers, not a
new production controller authority. A source-contract regression anchors the
harness composition to the current inline prediction, deadband, adaptive-step,
inertia, speed-clamp, missing-HR, cooldown, and Start authorization branches; it
fails if those production branches drift away from the shared pure rules used by
the replay.

## Output API

`TelemetrySemanticParityValidator.validate(legacy:telemetryV2:tolerance:)`
returns `TelemetrySemanticParityReport`. Use `machineReadableJSON()` for sorted,
versioned JSON and `humanReadableText()` for the deterministic review summary.
Neither renderer includes raw BLE payloads or mutates source evidence.
