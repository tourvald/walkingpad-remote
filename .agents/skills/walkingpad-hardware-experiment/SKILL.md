---
name: walkingpad-hardware-experiment
description: Govern a separately PM-approved real WalkingPad/controller experiment with a fixed command whitelist and physical safety contract. Do not use for ordinary implementation, design, or evidence analysis.
---

# WalkingPad hardware experiment

Stop unless the current task contains a separate explicit PM approval and an experiment contract with all of:

- exact device/protocol scope and exact whitelisted command or named fixed variant, including packet bytes when applicable;
- test conditions, including no-load when relevant, operator present throughout, and physical power switch ready;
- preconditions and fresh baseline telemetry required before any command;
- exact logging/evidence fields and artifact destination;
- expected observations, maximum duration/repetitions, explicit abort conditions, and physical recovery procedure;
- confirmation that the experiment does not include arbitrary raw/sequence commands, unknown packet replay, service-menu or unit writes, unlock attempts, firmware/OTA actions, or unapproved loaded operation.

If any element is missing, stale, ambiguous, or contradicted by live state, perform no hardware action and return `BLOCKED FOR PM DECISION` with the missing contract item.

During an approved experiment, send only the whitelisted command through the approved fixed runner, fail closed on missing/freshness-invalid telemetry, keep the operator in control, stop immediately on unexpected motion/acceleration/state, and preserve the complete evidence. Approval covers only that experiment; it does not authorize code changes, another variant, Ready/merge, deploy/install, or future hardware work.
