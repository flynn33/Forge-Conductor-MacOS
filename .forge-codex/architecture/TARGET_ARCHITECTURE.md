# Target Architecture

## Design goals

Forge Conductor is a native macOS orchestration application whose reliability depends on explicit ownership, bounded work, protocol compatibility, and durable continuity.

The target architecture has six principal layers:

```text
App scenes and feature views
        │
        ▼
Application coordinators / observable presentation models
        │
        ├── Telemetry presentation bridge
        ├── Gauge rendering service
        ├── Project/session coordinator
        └── Commands and window routing
        │
        ▼
Domain services (actors or otherwise explicitly serialized)
        ├── Project registry
        ├── Project memory service
        ├── Continuity coordinator
        ├── Session orchestration
        ├── Telemetry aggregation
        ├── Process supervision
        └── Migration and maintenance
        │
        ▼
Adapters
        ├── MCP transport
        ├── Model/provider clients
        ├── Host session adapter plugins
        ├── SQLite repository
        ├── File system / Keychain
        └── Metal renderer backend
```

UI types do not own subprocesses, database connections, long-lived notification tokens, or process-wide render resources. Services expose explicit `start`, `stop`, cancellation, and shutdown behavior.

## Ownership domains

Every reference resource belongs to one of these lifetimes:

| Lifetime | Examples | Owner |
|---|---|---|
| Process | shared Metal library, immutable configuration | application service container |
| App session | telemetry source, MCP server process | app session coordinator |
| Project | memory database, project watcher | project context |
| Model session | continuity state, provider stream | session coordinator |
| Window/scene | selection, local presentation bridge | scene root |
| Request | child task, query statement, temporary buffer | structured task scope |
| Frame | command buffer, encoder | renderer draw invocation |

Objects may reference shorter-lived objects only through ownership rules that do not extend the shorter lifetime unintentionally.

## Concurrency model

- UI and observation mutation: `@MainActor`.
- Mutable service state: dedicated actors.
- Database: one repository actor per open project database, with short transactions.
- Telemetry aggregation: actor with bounded latest-value subscribers.
- Process supervision: actor with structured reader tasks.
- Rendering resource creation: renderer service; draw encoding follows Metal thread-safety requirements and does not mutate SwiftUI state.
- Session orchestration: actor with persisted state-machine transitions.
- No `Task.detached` unless the payload is immutable/sendable and result delivery is explicit.
- Long-lived tasks are stored by the owner and cancelled in `stop`/`deinit` as a safety net; structured child tasks are preferred.

## Dependency direction

Feature views depend on protocols or presentation models. Domain services do not import SwiftUI. Persistence and provider adapters conform to domain protocols. The MCP executable composes domain services without importing app UI targets.

## Required components

### Telemetry

- `TelemetryAggregator`
- `TelemetryLatestValueChannel`
- `TelemetryPresentationBridge`
- `TelemetryDiagnostics`
- bounded metric histories

### Gauges

- `GaugeRendererService`
- shared `MetalResourceSet`
- one or justified few render surfaces
- `GaugeRenderScheduler`
- visibility and animation state

### Project memory

- `ProjectIdentityResolver`
- `ProjectMemoryRepository`
- `ProjectMemoryService`
- `MemorySearchIndex`
- `MemoryMaintenanceService`
- `ForgeMemoryMCPServer`

### Continuity

- `ContextBudgetMonitor`
- `CheckpointBuilder`
- `HandoffRepository`
- `ContinuityCoordinator`
- `SessionHostAdapter`
- `HostAdapterRegistry`
- one built-in Forge host plugin when needed

### Operations

- `RunEvidenceRecorder`
- unified logging categories
- signpost intervals
- health and diagnostics snapshots

## Resource adaptation

`ResourcePolicy` derives conservative limits from:

- physical memory;
- thermal state;
- low-power mode;
- app visibility;
- active project count;
- active gauge count;
- current model/session workload.

Dynamic adaptation changes cache/history/render limits only within documented floors and ceilings. It never creates an unbounded mode.

## Shutdown order

1. reject new session/project work;
2. checkpoint active continuity state;
3. stop producer subscriptions;
4. cancel request tasks and wait with a deadline;
5. stop process readers and terminate children with escalation;
6. flush and close memory repositories;
7. detach gauge surfaces and release project/scene resources;
8. flush bounded diagnostics;
9. mark shutdown complete.

Every step is idempotent and individually testable.
