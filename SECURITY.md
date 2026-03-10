# Security Policy

WalkingPad Remote controls physical hardware and can handle health-related workout data, so safety-sensitive reports matter even though this is a small personal OSS project.

## Reporting a vulnerability or safety issue

- Prefer GitHub private vulnerability reporting if it is enabled for the repository.
- If private reporting is not available, open a minimal public issue without exploit details and state that you want to coordinate disclosure.
- Do not publish pairing material, device identifiers, private certificates, workout exports with personal data, or anything that could help reproduce an unsafe setup on someone else's hardware.

## Scope

Relevant reports include:

- BLE command and control paths
- unsafe state transitions in treadmill control logic
- privacy leaks in workout telemetry export
- local tooling that could expose secrets or unsafe defaults

## Supported version

- `main`

## Project-specific notes

- This repository does not run a hosted backend or store user accounts.
- Most security and safety risk is in local device control, data export, and protocol handling.
- Please include enough detail to reproduce the problem safely, but redact anything sensitive.
