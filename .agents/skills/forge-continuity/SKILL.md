---
name: forge-continuity
description: Build Forge Conductor's durable context checkpoint, handoff, crash recovery, host-adapter plugin, and autonomous session rollover.
---

# Forge Continuity

## State machine

Implement the durable transitions in `.forge-codex/specifications/CONTINUITY_STATE_MACHINE.md`. Persist intent before side effects. Use operation IDs and idempotency. Recover from every transition.

## Host boundary

MCP can persist/expose handoffs but cannot by itself create a chat in an unrelated host. Detect capabilities. Reuse only supported documented APIs. When none provides full creation/bootstrap/acknowledgment/recovery, build and register `ForgeNativeSessionHostPlugin`.

Do not use AppleScript, Accessibility UI driving, keystrokes, screen scraping, or private endpoints.

## Handoff

Build from structured run state and project memory. Keep it compact, redacted, and reference-oriented. The successor must acknowledge the exact handoff before the predecessor seals.

## Tests

Use a deterministic fake host and inject failure/crash before and after every transition. Prove eventual one-successor continuation, concurrent project isolation, overflow recovery, timeout/backoff, cancellation, and app relaunch.
