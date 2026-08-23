---
name: forge-telemetry-gauges
description: Repair and validate Forge Conductor telemetry delivery, metric mappings, SwiftUI invalidation, and Metal gauge rendering.
---

# Forge Telemetry and Gauges

## Telemetry

Enforce one in-flight UI delivery plus one replaceable latest snapshot per subscriber. No per-update unstructured MainActor tasks. Add sequence/generation checks, coalesce/drop counters, explicit start/stop, and pressure tests.

Separate current values from histories and large collections. Keep history bounded. Do expensive aggregation outside the main actor. Batch observable assignments.

## Gauges

Inventory every `MTKView`, command queue, pipeline, library, texture, buffer, delegate, and render clock. Prefer one rig surface. Otherwise share one resource service.

Render only on value change or during bounded active animation. Hidden/static gauges must become quiescent. Reuse buffers and prove no update-path allocation churn.

## Evidence

Use deterministic flows `FLOW-TELEMETRY-STALL`, `FLOW-GAUGE-HIDDEN`, and `FLOW-GAUGE-CYCLE`. Capture before/after queue counts, retain paths, allocations, SwiftUI invalidations, draw cadence, CPU/GPU, and resource counts.

Do not claim success from a smaller peak alone. Prove the invariant and release boundary.
