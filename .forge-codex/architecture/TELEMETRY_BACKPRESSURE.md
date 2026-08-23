# Telemetry Delivery and Backpressure

## Audited defect

The audited GUI telemetry path creates recurring unstructured `Task { @MainActor ... }` work. Each task can retain its captured snapshot until the main actor executes it. When producers outpace presentation, pending work and copied history/process data accumulate. The code path therefore lacks a true bounded delivery guarantee.

This is an E1 deterministic source defect. Runtime measurements must still quantify its impact and prove the release behavior after repair.

## Required invariant

For each presentation subscriber:

```text
maximum retained delivery state =
    one in-flight main-actor update
  + one replaceable latest snapshot
```

Older undelivered snapshots are replaced, not queued. The channel must expose delivered, replaced, dropped, stale, and maximum-depth counters.

## Preferred design

Implement a dedicated latest-value mailbox. Acceptable implementations include:

- an actor that stores `latest`, `deliveryScheduled`, and subscriber identity;
- an `AsyncStream` with `.bufferingNewest(1)` where cancellation and sequence semantics are explicit;
- an equivalent bounded channel with capacity one.

Do not create one unstructured main-actor task per producer event.

Illustrative state machine:

```text
idle + publish(Sn)
  -> latest=Sn, deliveryScheduled=true
  -> schedule exactly one UI delivery

scheduled + publish(Sn+1)
  -> replace latest with Sn+1
  -> replacedCount += 1
  -> do not schedule another UI task

delivery executes
  -> atomically take latest
  -> apply if subscriber generation matches
  -> if newer latest exists, schedule one next delivery
  -> else deliveryScheduled=false
```

Use monotonically increasing sequence numbers. A presentation bridge has a generation token so an old scene cannot receive data after stop/restart.

## Snapshot design

Avoid copying large histories for every delivery.

- Separate current scalar values from historical series.
- Store histories in bounded ring buffers in the aggregation service.
- Publish small immutable deltas or references to immutable value snapshots.
- Query history only for visible consumers and within a requested window.
- Do not publish process collections when the receiving view does not need them.
- Apply metric-specific sampling and coalescing.
- Use value types whose copy-on-write storage is not mutated after publication.

## Lifecycle

The bridge has explicit methods:

```swift
func start() async
func stop() async
```

`stop()`:

- invalidates the subscriber generation;
- cancels the subscription;
- clears `latest`;
- prevents new scheduling;
- waits for the in-flight delivery to observe invalidation;
- releases callbacks.

`deinit` may assert or log unexpected active state but is not the primary cleanup mechanism.

## Main-actor work

Only the minimal observable state assignment occurs on the main actor. Decoding, aggregation, sorting, history maintenance, and unit conversion occur off-main in their owning actors.

Batch related observable assignments so one telemetry cycle does not trigger a cascade of independent view invalidations.

## Correctness tests

- ordered sequence with no producer pressure;
- replacement under 10x and 100x producer pressure;
- maximum queue depth never exceeds the invariant;
- latest value eventually delivered;
- stale generation never applied;
- start/stop/restart is idempotent;
- bridge deallocates after scene removal;
- producer shutdown leaves no tasks;
- cancellation during delivery;
- malformed telemetry does not kill the stream;
- multiple subscribers have independent bounded mailboxes.

## Performance tests

Induce a controlled main-actor stall while producing representative large snapshots. Compare before and after:

- pending task count;
- retained snapshot count;
- resident-size trajectory;
- time to latest-value convergence;
- main-thread CPU;
- SwiftUI invalidations;
- telemetry drop/replacement counters.

The repaired path must remain bounded throughout the stall and recover to the newest value without replaying obsolete snapshots.
