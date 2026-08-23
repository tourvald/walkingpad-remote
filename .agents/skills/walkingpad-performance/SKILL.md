---
name: walkingpad-performance
description: Use only when a WalkingPad task explicitly targets or demonstrates runtime speed, latency, CPU, memory, persistence throughput, telemetry throughput, battery cost, or command/UI responsiveness. Measure first, fix the dominant bottleneck with the smallest safe change, and remeasure.
---

# WalkingPad performance optimization

Optimize evidence, not aesthetics. A smaller diff can be easier to maintain but does not prove faster runtime.

## Diagnose first

Use the narrowest trustworthy evidence available: existing timings/signposts, Instruments, XCTest metrics, a deterministic benchmark/soak, queue-depth/drop counters, persistence timings, or a reproducible workload. Identify the dominant class before rewriting code.

If no trustworthy measurement exists, add the smallest measurement needed first.

## Optimization order

Prefer, when supported by evidence:

1. remove unnecessary/repeated work;
2. fix bad asymptotics or redundant passes;
3. reduce excessive timers/events/serialization and transport or persistence round trips;
4. batch work only where latency/safety semantics permit;
5. reduce unnecessary allocations, copies, parsing, formatting, or view recomputation;
6. cache only when repeated reuse is measured and invalidation is explicit;
7. add concurrency only when the measured bottleneck benefits and ordering/safety remain correct;
8. micro-optimize only after higher-leverage options are exhausted.

Do not change BLE pacing, command ordering, stop confirmation, telemetry truth, HR safety gates, or persistence semantics merely for speed without the appropriate safety/data contract.

## Evidence gate

Measure the same representative workload before and after. Report metric, workload, result, and complexity cost. If speed cannot be measured, say so; never claim a speedup from LOC reduction or subjective smoothness alone.
