# Lifecycle, Concurrency, and Process Supervision

## Scope

The audit identified numerous owner-local risks involving tasks, timers, observers, Combine subscriptions, `Process`, `Pipe`, `FileHandle`, delegates, collections, and manual native allocations. These remain E2 until effective ownership and release boundaries are traced.

## Owner inventory

For every long-lived type, create a resource table:

| Resource | Creation | Owner | Intended lifetime | Stop/cancel/close | Proof |
|---|---|---|---|---|---|

Trace indirect cleanup through service containers and coordinators before declaring a leak.

## Task rules

- Prefer `async let`, task groups, or child tasks tied to an operation.
- Store genuinely long-lived tasks under the owner.
- Cancel and await them in `stop()`.
- Capture `self` weakly only when losing the owner should terminate work; weak capture is not a substitute for structured ownership.
- Avoid self-retaining loops where a stored task strongly captures its owner.
- Check cancellation in loops and before expensive work.
- Bound concurrent task groups.

## Timer rules

Prefer `Clock`-based cancellable loops in an actor when practical. If using `Timer`:

- owner stores the timer;
- invalidation occurs on stop;
- scheduled timer does not strongly retain a view/service beyond its lifetime;
- cadence pauses with feature visibility;
- tolerance is set for non-real-time work.

## Observer and subscription rules

- Store block observer tokens and remove them.
- Store Combine subscriptions in the owner and cancel on stop.
- Do not allow process-lifetime notification singletons to capture project or window services.
- Use explicit subscription handles in service protocols.
- Test repeated start/stop and owner release.

## Process and pipe rules

Create a `ProcessSupervisor` actor.

Responsibilities:

- launch child process;
- read stdout/stderr concurrently without blocking;
- bound retained output and line size;
- cancel reader tasks;
- close readability handlers and file descriptors;
- terminate gracefully, then escalate after a deadline;
- reap exit exactly once;
- deliver exit status independent of output completion;
- prevent `waitUntilExit()` on the main actor;
- redact secrets in command/log records.

Use a bounded ring buffer for diagnostic output and optionally stream durable logs to disk with rotation.

## File watchers and dispatch sources

- explicit activate/cancel state;
- cancellation handler closes descriptor exactly once;
- owner clears event handlers before release when required;
- no project watcher survives project close;
- coalesce high-frequency file events;
- bound recursive rescans.

## Delegates

Classify each delegate as owning or non-owning. Use `weak` where the framework and lifetime permit. If a strong delegate is intentional, document the ownership and break it on stop.

## Collections and caches

Every retained collection declares:

- maximum count or byte size;
- eviction policy;
- expiration;
- ownership lifetime;
- memory-pressure response;
- observability counters.

Histories use ring buffers. Caches use cost limits and explicit invalidation. Session/project collections are released at session/project close.

## Manual/native allocation

Wrap allocations in RAII-style Swift owners whose `deinit` releases exactly once, but provide explicit close when deterministic release matters. Test allocation failure and repeated close.

## Concurrency diagnostics

Run:

- strict Swift concurrency checking appropriate to the toolchain;
- Thread Sanitizer separately from Address Sanitizer;
- concurrency stress tests with repeated start/stop/project switching;
- hang detection with bounded test timeouts;
- actor-isolation assertions where useful.

Do not suppress sendability warnings globally.
