# Continuity, Handoffs, and Autonomous Session Rollover

## Product requirement

When a model session approaches its usable context limit, Forge Conductor must create a durable project handoff, start a successor session through a supported host capability, load the handoff, acknowledge it, and continue work without operator intervention.

Memory MCP alone cannot force an unrelated external host UI to create a chat. Automatic rollover therefore belongs to a session-host adapter. Forge must provide a native autonomous host mode when an external host exposes no supported creation API.

## Components

- `ContextBudgetMonitor`
- `CheckpointBuilder`
- `HandoffRepository`
- `ContinuityCoordinator` actor
- `SessionHostAdapter` protocol
- `HostAdapterRegistry`
- `RolloverRecoveryService`
- continuity MCP tools/resources
- built-in Forge host plugin when required

## Context budget

Prefer exact provider usage metadata and the selected model's declared context capacity. Do not hardcode one universal model limit.

When exact usage is unavailable, estimate conservatively using:

- serialized conversation/tool payload size;
- recent tokenization data for the provider when available;
- reserved completion/tool budget;
- accumulated artifact and memory references;
- a safety margin.

Persist the estimate source and confidence.

Default lifecycle thresholds are policy bands, not assumed provider limits:

- normal operation below the checkpoint band;
- checkpoint preparation when remaining usable budget reaches the configured reserve;
- rollover before the hard reserve is consumed;
- emergency checkpoint if a provider reports context overflow.

Tests inject exact fake budgets; production values come from provider capabilities/configuration.

## Handoff contents

A handoff is compact and reference-oriented:

- handoff and predecessor session IDs;
- project identity;
- mission and non-negotiable constraints;
- current phase/work item;
- repository path, branch, commit, and dirty-file summary;
- completed changes;
- commands and test outcomes;
- open findings and blockers;
- decisions and rejected alternatives;
- active files, symbols, and artifacts;
- feature-preservation status;
- next deterministic actions;
- relevant memory record IDs;
- evidence index references;
- provider/host capability state;
- idempotency key and schema version.

Do not dump an unbounded transcript. Store detailed context in project memory and reference it.

## Durable state machine

```text
active
  -> checkpointPreparing
  -> checkpointPersisted
  -> successorRequested
  -> successorCreated
  -> successorBootstrapping
  -> successorAcknowledged
  -> predecessorSealed
```

Failure transitions remain on the last durably committed state and record retry metadata. Every transition is transactional or journaled before external side effects.

### Idempotency

- one rollover operation ID;
- host session creation receives an idempotency key when supported;
- duplicate successor discovery is reconciled;
- handoff acknowledgment is compare-and-set;
- sealing is idempotent;
- recovery can replay any step.

## Host adapter contract

```swift
protocol SessionHostAdapter: Sendable {
    var identifier: String { get }
    func capabilities() async throws -> HostCapabilities
    func createSession(_ request: SessionCreationRequest) async throws -> HostSession
    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws
    func awaitAcknowledgement(
        session: HostSession,
        handoffID: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> HandoffAcknowledgement
    func cancel(_ operationID: UUID) async
}
```

All methods are deadline- and cancellation-aware. Capabilities explicitly state whether create, bootstrap, usage reporting, resume, and idempotency are supported.

## Native host fallback

When the currently integrated external GUI cannot create sessions through a public supported API:

1. preserve that client's MCP memory and handoff compatibility;
2. implement a compile-time registered `ForgeNativeSessionHostPlugin`;
3. let Forge own provider requests and logical session boundaries;
4. create the successor logical session within Forge;
5. bootstrap from the durable handoff;
6. surface session history and status in the existing UI without removing external-client support.

Do not use AppleScript, Accessibility, keystroke injection, screen scraping, or private host endpoints as the success path.

## Continuity MCP

Expose tools/resources that allow clients to checkpoint, inspect, and resume. The MCP is useful even when the client owns session creation, but it must not claim that a new external chat was created unless the host adapter confirms it.

## Crash recovery

On launch:

1. scan nonterminal rollover journal entries;
2. verify predecessor and successor identifiers;
3. query host adapter where supported;
4. resume the next idempotent transition;
5. prevent duplicate active successors;
6. make the latest pending handoff discoverable;
7. record recovery evidence.

Test process termination after every transition and during database/file writes.

## Completion proof

A deterministic integration harness must simulate:

- normal rollover;
- usage metadata unavailable;
- provider context-overflow response;
- crash at every transition;
- duplicate create response;
- host timeout and retry;
- bootstrap failure;
- acknowledgment timeout;
- predecessor crash after successor creation;
- database lock/disk pressure;
- two projects rolling over concurrently;
- external MCP-only host capability;
- Forge-native plugin capability.

Success requires no lost phase state, no duplicate accepted successor, and automatic continuation from the acknowledged handoff.
