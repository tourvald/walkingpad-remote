# Roadmap

This project is intentionally narrow. The goal is not to become a generic fitness platform; the goal is to keep a readable, useful reference implementation for treadmill control, HR-guided sessions, and local telemetry.

## Near-term priorities

- Broader real-device validation for FTMS and FitShow treadmills
- More unit coverage for protocol parsing, HR decisions, and telemetry transforms
- Better contributor docs and safer bug-reporting flow
- UI polish and accessibility improvements for the main workout flows
- Better analysis tooling around exported training logs
- Implement the [Telemetry V2 specification](docs/telemetry-v2/architecture.md) through its sequential, evidence-gated rollout

## Nice-to-have improvements

- More screenshots and demo material for the public repository
- More export and visualization helpers for telemetry data
- Additional debug affordances that stay isolated from production paths

## Non-goals

- cloud accounts or hosted services
- multi-user backend infrastructure
- broad smart-home integrations outside the treadmill/watch scope

If you want to work on something large, open an issue first so the change can stay aligned with the project scope.
