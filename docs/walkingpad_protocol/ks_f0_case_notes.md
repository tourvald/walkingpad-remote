# KS-F0 Case Notes

These notes are specific to the locally affected treadmill and must not be generalized to all WalkingPad /
KingSmith models.

## Source Boundary

`docs/ks-f0-incident.md` was requested as an input, but that file is not present in the current working tree as of
2026-06-28. This page is based on:

- `STATUS.md`
- raw research under `docs/research/`
- current telemetry/analyzer behavior
- local operator observations from the affected treadmill

## Confirmed for the Affected Treadmill

| Observation | Status | Source |
| --- | --- | --- |
| Controller reports `queryParams.unit=1`. | local observation, product-smoke accepted | `STATUS.md`, device smoke report |
| App detects `imperial` and shows warning/gates dangerous modes. | confirmed product behavior | `STATUS.md`, current app code |
| HR-control is blocked on imperial. | confirmed product behavior | `STATUS.md`, current app policy |
| Imperial diagnostic profile uses `rawTenths=30` for 60 seconds with no-load confirmation. | confirmed product behavior | `STATUS.md`, current app code |
| Operator visual evidence can confirm physical semantics for this treadmill. | local observation | owner/operator evidence |
| Operator confirmation is stored per treadmill fingerprint, not globally. | confirmed product behavior | `STATUS.md`, current app code |
| Confirmed physical semantics do not unlock HR-control. | confirmed product behavior | `STATUS.md`, current app policy |
| Stop confirmation has failed in local logs (`stop_confirmed_ever=false`). | local observation | exported telemetry / runtime snapshot |
| Native physical remote can also fail to stop the affected treadmill. | local observation | owner report |

## What Is Not Proven

| Claim | Status | Product Rule |
| --- | --- | --- |
| All KS-F0 devices have imperial command semantics when `unit=1`. | unknown | Do not generalize. |
| Device-reported `distance=30` means 30 meters or 30 miles. | unknown | Treat as raw evidence unless externally measured. |
| `setUnit` is safe on this specific treadmill. | unknown / unsafe | Do not write `setUnit`. |
| Stop issue is caused by imperial units. | unknown | Keep stop-forensics separate. |
| Firmware update would fix stop or units. | unknown / unsafe | Firmware flashing forbidden. |

## Current Product Behavior for This Case

| Behavior | Status | Reason |
| --- | --- | --- |
| Show imperial warning from valid params | `allowed` | Read-only safety signal. |
| Block HR-control | `allowed` / required | Safety gate until explicit imperial support design is approved. |
| Allow no-load imperial diagnostic after explicit confirmation | `diagnostic-only` | Needed to collect physical evidence safely. |
| Store operator visual confirmation | `allowed` | Per-device evidence only. |
| Apply confirmation to other treadmills | `forbidden` | Fingerprint mismatch must block automatic reuse. |
| Loaded treadmill experiments | `forbidden` | Safety risk while semantics/stop behavior are unresolved. |

## Fingerprint Rule

Operator confirmation applies only when current device evidence matches the stored treadmill fingerprint:

- `peripheralId`
- `peripheralName`
- protocol `walkingPad`
- `controllerParamsRawHex`
- `controllerUnitPref`
- `controllerParamsChecksumOk=true`

If params changed or checksum fails, the confirmation is not automatically applied.

## Open Questions

1. Why stop is not reliably confirmed on the affected treadmill.
2. Whether stop issue is firmware, controller state, hardware, remote/app command semantics, or another condition.
3. Whether imperial physical semantics are a preference state, a controller-region state, or model-specific behavior.
4. Whether read-only Device Information can help identify affected firmware versions.
