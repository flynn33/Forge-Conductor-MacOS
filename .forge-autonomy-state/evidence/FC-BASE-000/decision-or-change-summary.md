# FC-BASE-000 decision and change summary

The package input matches current `origin/main`, so implementation uses the isolated
`repair/autonomous-continuity` worktree. The original checkout's signing and release
handoff changes remain outside this branch.

The prior repair ledger remains authoritative for its completed telemetry, gauge,
lifecycle, memory, and continuity foundations. Its host-rollover gate was reopened
because live source hashes prove that release registration still selects a synthetic
transport, which the stricter continuity supplement rejects as successor evidence.
The package ledger records the additive work-package DAG and both ledgers retain a
SHA-256 event chain.

No product behavior changed in this package. Product-facing source additions are a
test-target-only LM Studio model/Responses fixture, deterministic URL protocol, and
three focused tests. The fixture is not referenced by any application, core, CLI, or
plugin target. The repository guard now classifies generated autonomy evidence and
the installed package validator as control artifacts, matching its existing treatment
of repair-state evidence and policy fixtures.

The live SwiftPM suite exposed an independent LM Studio process-snapshot failure and
was retained verbatim as E0 evidence. The deterministic suite passed all 272 tests;
the app build/run verifier, unsigned Xcode Debug build, executable MCP transcript,
and LM Studio fixture tests also passed.
