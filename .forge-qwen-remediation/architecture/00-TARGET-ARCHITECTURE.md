# Target architecture

```text
ForgeConductorApp (SwiftUI, read/command client only)
    │ authenticated typed manager API + bounded event cursor
    ▼
Forge Conductor LaunchAgent Manager — sole durable owner
    ├── ProjectRegistryService
    ├── ProjectContextCoordinator
    ├── ProjectResetService
    ├── PackageIngestionService
    ├── PackageCatalogRepository
    ├── PackageQueueService
    ├── GateRegistry + GateExecutionService
    ├── AutonomySupervisor
    │     └── ProjectRunCoordinator
    │           ├── ManagedModelProvider / LM Studio adapter
    │           ├── ToolInvocationBroker
    │           ├── ContextBudgetSupervisor
    │           └── ContinuityCoordinator
    ├── ExecutionJobService
    │     ├── workspaceIsolated process profiles
    │     └── ForgeRuntimeXPC hardened profiles
    ├── ResourcePressureCoordinator
    ├── DashboardServer
    ├── SecureFilesystemBroker / CForgeSecureFS
    └── Per-project memory and control-plane repositories
```

## Ownership rules

- The GUI never runs a second scheduler, provider loop, queue, retention loop, or continuity engine.
- The manager owns project generation, queue leases, provider sessions, runtime jobs, gate executions, reset barriers, and recovery.
- Each project repository is opened through a repository registry and evicted during reset.
- Model and MCP calls receive an immutable `ToolInvocationContext` containing exact project, generation, run, package assignment, authorization scope, and predecessor/successor authority.
- A global dashboard may aggregate redacted status; it cannot supply bootstrap authority.

## Data stores

```text
~/.forge-conductor/
  Manager/control-plane.sqlite3
  Projects/<project-id>/
    memory.sqlite3
    continuity/
  Packages/
    Store/<content-sha256>/content/
    Quarantine/<candidate-id>/
    Artifacts/<package-run-id>/
  RuntimeJobs/<job-id>/
  FilesystemTransactions/<transaction-id>/
  Archives/<project-id>/
```

Paths are implementation defaults; migrations must preserve existing supported locations.

## Core invariants

- one accepted active queue lease per package run;
- one accepted successor per rollover operation;
- one current project generation per project;
- no completed gate without a registered validator receipt;
- no package execution before immutable ingestion acceptance;
- no destructive filesystem pathname verify-then-mutate sequence;
- no shell regression;
- no recurring offscreen gauge rendering;
- no unbounded history or connection registry.
