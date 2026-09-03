# Operator console completion

## Typed command pattern

Every button calls a typed `OperatorManagerClientProtocol` method. The manager validates authentication, project/generation, expected revision, and capability, then returns an operation/receipt ID. View models stream or poll bounded authoritative state until terminal.

## Required controls

- Projects: relink, memory reset, continuity reset, combined reset, history cleanup, backup/restore visibility.
- Work Queue: import, reorder, pause/resume, retry, cancel, inspect gates/artifacts/events.
- Runtimes: cancel job, capability refresh, profile selection, isolation policy, concurrency and limits.
- Continuity: checkpoint now, early rollover, inspect exact operation and context budget.
- Provider: test connection, run contract probe, credential status, model/context/lifecycle health.

## UX requirements

- no empty button actions;
- no blanket disabled group when a capability exists;
- precise disabled reason when unsupported or unauthorized;
- stable accessibility identifiers;
- confirmation only for destructive reset/cancel actions, with automated test support;
- redaction of credentials and sensitive payloads;
- no execution engine in a view model.
