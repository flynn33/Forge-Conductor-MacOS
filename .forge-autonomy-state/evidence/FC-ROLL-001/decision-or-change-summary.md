# FC-ROLL-001 decision and change summary

`ManagedContinuityWorker` now drives the entire handoff-to-continuation transition from
durable state. It validates project, generation, run, operation, handoff, canonical payload
checksum, and bootstrap nonce before accepting a candidate. Successor creation is always a
fresh provider root and never carries the predecessor response as `previous_response_id`.

External intent is committed before each side effect. Candidate acceptance, active-run
session replacement, duplicate quarantine, and predecessor fencing are transactional.
Only one valid candidate becomes active; late candidates receive no project authority. The
predecessor is sealed idempotently and cannot execute bound tools after fencing.

Automatic continuation is a canonical persisted intent linked to the exact accepted
successor. `ManagedProjectRunStepExecutor` consumes it before ordinary work, verifies every
identity and the active source revision, and records one stable provider turn. Recovery
therefore handles a crash after the provider side effect or after turn persistence without
issuing a second continuation.

The crash injector covers twelve boundaries from checkpoint intent through continuation
side effect. Each case reopens the database and manager components, then proves one
validated handoff, one accepted active successor, one active run pointer, a fenced and
sealed predecessor, one continuation side effect, and no remaining pending continuation.
The focused proof also covers two concurrently managed projects and restart recovery from
transient provider and configuration failures.
