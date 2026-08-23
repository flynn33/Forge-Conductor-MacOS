# Continuity State Machine Specification

## States

| State | Durable meaning |
|---|---|
| `active` | predecessor session is active |
| `checkpointPreparing` | checkpoint build operation recorded |
| `checkpointPersisted` | checkpoint committed and verified |
| `successorRequested` | host create intent committed |
| `successorCreated` | successor identifier reconciled and committed |
| `successorBootstrapping` | handoff delivery intent committed |
| `successorAcknowledged` | successor acknowledged exact handoff |
| `predecessorSealed` | rollover complete |
| `retryScheduled` | recoverable operation failed with next attempt |
| `failedRecoverable` | bounded retry exhausted; alternate adapter/recovery required |
| `failedFatal` | integrity invariant prevents continuation |

`retryScheduled` and failure metadata supplement the last successful transition; they do not erase it.

## Transition record

Each transition contains:

- operation ID;
- project ID;
- predecessor session ID;
- successor session ID when known;
- handoff ID;
- from/to state;
- attempt;
- timestamp;
- host adapter ID/version;
- idempotency key;
- evidence/error;
- state checksum.

## Preconditions

### active → checkpointPreparing

- context policy requests checkpoint;
- no terminal rollover exists;
- project identity is available.

### checkpointPreparing → checkpointPersisted

- handoff payload validates;
- memory references exist;
- repository and run state were captured;
- atomic commit succeeds.

### checkpointPersisted → successorRequested

- selected adapter advertises creation/bootstrap capability;
- create intent and idempotency key are durable.

### successorRequested → successorCreated

- adapter result validates or existing idempotent result is reconciled.

### successorCreated → successorBootstrapping

- handoff ID and successor ID are durable;
- bootstrap intent recorded.

### successorBootstrapping → successorAcknowledged

- acknowledgment names exact handoff ID and successor session;
- deadline and adapter identity validate.

### successorAcknowledged → predecessorSealed

- successor resume state committed;
- predecessor checkpoint is immutable;
- active-session pointer changes atomically.

## Recovery algorithm

On startup, inspect the latest operation:

- if checkpoint preparation lacks a committed handoff, rebuild idempotently;
- if create intent exists without successor ID, query adapter by idempotency key or retry;
- if successor exists without bootstrap, bootstrap;
- if bootstrap exists without ack, query/wait/retry;
- if ack exists without seal, seal;
- if sealed, ensure active pointer selects successor.

When the adapter cannot query by idempotency key, use a local operation registry and provider metadata to reconcile before creating another session.

## Concurrency

One active rollover per project. Different projects may roll over concurrently within a bounded global limit. Compare-and-set protects project active-session pointers.

## Context overflow recovery

If a provider rejects a request for context length:

1. persist an emergency minimal checkpoint from already durable state;
2. create a successor using the last successful checkpoint plus recent bounded deltas;
3. record the overflow as evidence;
4. adjust the model/provider policy reserve;
5. continue automatically.

Never discard unsaved repository/run-state changes.

## Test model

Use a deterministic fake host with injectable failures after each side effect and before each state commit. Enumerate all transition crash points and assert eventual single-successor completion.
