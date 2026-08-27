# FC-CONT-001 decision and change summary

Continuity authority is now project-local and generation-fenced. SQLite stores the
canonical V2 handoff and rollover-operation records; atomic project-local projections are
recovery aids. Managed rollover selection requires the exact project, generation, run,
and handoff identity and never consults the legacy global latest pointer.

The coordinator exposes separate checkpoint, prepare-handoff, and request-rollover
operations. A rollover request durably enqueues manager work, and a successor is accepted
only after an exact V2 acknowledgment of the same handoff. Predecessor sealing is
idempotent. External hosts that cannot create sessions through a supported API remain
explicitly handoff-only.

Legacy continuity records migrate only when project evidence is unambiguous. Ambiguous or
stale records are quarantined with bounded diagnostic metadata rather than selected as
execution authority. Existing continuity tool names and legacy packet access remain
available for compatibility.

The first combined proof exposed nine legacy continuity fixtures that attempted
project-scoped filesystem or shell work without the exact durable binding introduced by
FC-CTX-001. The fixtures now establish that binding directly before exercising continuity
budgets. The former context-get workspace test now proves the security boundary: legacy
global continuity may restore narrative state, but it cannot authorize project execution;
an explicit durable project binding is required. The identical 72-test selection then
passed with one environment skip and zero failures.
