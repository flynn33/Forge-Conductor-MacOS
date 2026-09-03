# Durable Work Queue

## State machine

```text
discovered -> validating -> ready -> reserved -> running
running -> checkpointing -> running
running -> validatingCompletion -> completed
running -> paused | blocked | retryWaiting | failed | cancelled
reserved -> ready            (expired lease)
```

Transitions are revision-checked and evented. Terminal states are immutable except through a new retry attempt.

## Queue assignment

A provider run receives one immutable `QueueAssignment` with package digest, package/run IDs, project/generation, mission, allowed tools/roots, resource budget, declared gates, dependency status, artifact root, and lease epoch.

The provider does not scan directories or select the next package.

## Leases

- durable reservation before worker start;
- manager ID, lease epoch, heartbeat, expiration, and expected revision;
- one accepted active lease per package run;
- stale workers fenced by lease epoch and project generation;
- manager startup reconciles reserved/running records before scheduling new work.

## Model-facing tools

```text
queue.current
package.progress
package.blocked
package.complete_request
package.artifact.register
```

`package.complete_request` only requests manager validation. It accepts no proof hash.

## Scheduling

Default is deterministic FIFO within priority and dependency readiness. Limits are project-aware and pressure-adjusted. A package cannot starve indefinitely; age contributes to effective priority. Projects may define concurrency caps. The manager automatically advances after validated completion.

## UI

Add a `Work Queue` tab with import, ordering, state, package digest, project, attempt, lease, context/rollover, gates, artifacts, logs, pause/resume/retry/cancel, and authoritative event timeline. Drag ordering updates durable priority with revision checks.
