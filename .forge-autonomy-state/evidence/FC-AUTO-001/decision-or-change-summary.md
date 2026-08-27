# FC-AUTO-001 decision and change summary

Autonomous execution is owned by the manager process. `ManagerNode` starts the durable
runtime before its dashboard surface, while `AutonomySupervisor` restores nonterminal runs,
enforces a memory-tier concurrency limit, and owns one coordinator task per active run.
Closing or stopping the dashboard therefore does not stop project work.

The control-plane database persists run state, lease owner and epoch, events, provider-turn
intent, tool-invocation intent, retry state, and completion receipts. `ProjectRunCoordinator`
advances runs through compare-and-set transitions only while its lease is current. Lease
renewal covers long provider or tool operations, expired leases are released on manager
startup, and stale owners cannot commit later work.

`ManagedProjectRunStepExecutor` and `ToolInvocationBroker` persist external side-effect
intent before dispatch and classify replay behavior. Idempotent completed results may be
reused under the same identity; interrupted non-replayable work is recorded as ambiguous
rather than repeated. Provider configuration, temporary, context-overflow, terminal, and
cancellation outcomes map to distinct durable run states.

A model completion request enters deterministic validation; the model cannot set a run to
completed directly. Pause, resume, cancel, and retry are manager-owned controls. Shutdown
stops new activation, cancels in-flight provider work, releases run-owned jobs, waits for
bounded coordinator cleanup, and leaves unfinished state recoverable.

The first full strict suite identified legacy tests that called project-scoped tools without
the durable binding now required by FC-CTX-001, plus a live process test that compared two
different point-in-time LM Studio scans. The fixtures now establish exact project context,
and the live assertion evaluates only process identities stable across the sampled interval.
The repeated strict suite passed all 395 tests with two documented environment skips.
