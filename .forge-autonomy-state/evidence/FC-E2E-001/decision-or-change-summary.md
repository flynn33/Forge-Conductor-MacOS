# FC-E2E-001 decision and change summary

The real LM Studio managed-continuity scenario passed after the provider and requested
model were available. It created a fresh successor root, validated the exact handoff
checksum and acknowledgment, and automatically continued from the bootstrap response.
The durable transcript contains genuine `resp_` identifiers and provider-exact usage:
1,454 input tokens, 3,478 output tokens, and 4,932 total continuation tokens. No operator
action occurred between the rollover trigger and continued successor work inside the
executed scenario.

The first invocation failed closed with `providerUnavailable` while the local provider or
model was not available. Starting the provider/model was a test precondition before the
successful retry, not an automatic action performed by the rollover flow.

Current deterministic evidence also covers two-project threshold rollover, manager
restart recovery, transient outage reconciliation, provider configuration blocking, and
the managed crash-boundary matrix. These passing scenarios do not complete FC-E2E-001.
Its UI dependency is blocked, its performance dependency is incomplete, and GUI closure,
reset fencing, real multi-project model-plus-shell interleaving, full managed auth/outage
recovery, real emergency overflow recovery, profiling, and final feature parity remain.
The work package must stay partial until every hard scenario and both dependencies pass.
