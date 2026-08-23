# Gauge and Metal Rendering Architecture

## Audited defect

The audited gauge implementation creates an independent `MTKView` resource graph for gauges, including command queues, pipeline resources, recurring native rendering, SwiftUI animation updates, and update-path buffer creation. Telemetry cadence, SwiftUI animation cadence, and Metal draw cadence can independently drive work.

This is an E1 resource-scaling and cadence defect. Runtime Metal and allocation traces must measure the exact cost before and after repair.

## Required invariants

1. Hidden, occluded, detached, or unchanged gauges perform no recurring draw work.
2. Metal device, command queue, libraries, pipeline states, samplers, depth states, and immutable geometry are shared at the narrowest safe app/session scope.
3. Mutable frame/value buffers are persistent and updated in place.
4. Render cadence has one owner.
5. Gauge count does not multiply command queues or pipeline compilation.
6. No rendering callback mutates SwiftUI observable state.
7. Drawable acquisition and command-buffer submission are skipped when a surface is not drawable.
8. All native delegates and surfaces have explicit attach/detach lifecycles.

## Preferred topology

First evaluate a single rig surface containing all gauges:

```text
GaugeRigView
    └── one MTKView
          └── GaugeRenderer
                ├── shared MetalResourceSet
                ├── persistent instance/value buffers
                └── draw all visible gauge instances
```

This minimizes surfaces, queues, display callbacks, and state transitions.

If separate surfaces are required by existing layout or accessibility behavior, they must share a `GaugeRendererService` and remain paused until invalidation:

```text
N MTKViews
    └── one shared device/queue/pipeline resource set
```

Document why multiple surfaces are necessary and measure the difference.

## Scheduling

Use one scheduler policy:

- render immediately when a displayed value changes materially;
- continue at a bounded frame cadence only while an explicit animation is active;
- stop after convergence;
- pause when hidden, occluded, minimized, or outside the active scene;
- lower cadence under thermal pressure or low-power mode.

For `MTKView`, prefer paused/on-demand operation where it satisfies animation requirements:

```text
isPaused = true
enableSetNeedsDisplay = true
```

For active animation, set a justified preferred frame rate and stop it when complete. Do not pair an always-running MTKView with an independent SwiftUI timeline animation for the same visual state.

## Data flow

Telemetry produces normalized gauge values and freshness metadata. A presentation model computes display semantics outside the draw callback. The renderer receives a compact immutable frame description:

- gauge identifier;
- normalized value;
- target and current animated values;
- status flags;
- label/unit lookup identifier;
- timestamp/sequence.

Text and accessibility remain in SwiftUI/AppKit when practical; Metal renders geometry.

## Buffer policy

- Preallocate geometry and per-instance buffers to the maximum supported visible gauge count or grow geometrically within a cap.
- Reuse buffers across frames.
- Use a small bounded in-flight buffer ring only when needed.
- Wait on semaphores with deadlines or use command-buffer completion safely; never deadlock the main actor.
- Do not allocate `MTLBuffer` objects in a high-frequency SwiftUI update callback.
- Purge optional caches on memory pressure.

## Resource policy

The renderer responds to:

- `NSApplication.didResignActiveNotification`;
- window occlusion/minimization;
- scene visibility;
- process thermal state;
- low-power mode;
- memory-pressure dispatch source.

Notification tokens belong to the renderer owner and are removed at shutdown.

## Tests

### Unit

- metric-to-gauge mapping, units, ranges, thresholds;
- animation convergence and clamping;
- scheduler transitions;
- visibility/occlusion policy;
- resource cache keying;
- buffer growth caps.

### Integration

- one renderer resource set for all expected gauges;
- no draw callbacks after hide/detach;
- repeated open/close releases scene and surface graphs;
- resize and scale changes;
- appearance/accessibility behavior;
- device unavailability fallback.

### Performance

Capture Release traces for:

- idle app with gauge screen hidden;
- visible static gauges;
- active telemetry;
- repeated navigation/open-close;
- low-memory and thermal policy simulations.

Measure CPU, GPU, wakeups, draw count, command queue count, pipeline creation count, allocation rate, resident-size trajectory, and frame pacing.

## Fallback

If Metal is unavailable or fails initialization, preserve the feature through a tested native SwiftUI/Core Graphics fallback that is visually and semantically compatible, bounded, and not continuously animated while static.
