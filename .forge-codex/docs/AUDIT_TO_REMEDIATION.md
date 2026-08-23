# Audit-to-Remediation Matrix

This matrix preserves the supplied audit as the starting evidence set. The raw report and evidence remain authoritative. Assignments define the default repair phase; Codex may add cross-phase dependencies without erasing the original finding.

| ID | Severity | Evidence | Phase | Finding | Source |
|---|---|---|---|---|---|
| `FC-MEM-001` | Critical | E1 | `P03` | Telemetry delivery can accumulate unbounded pending MainActor tasks | `Sources/ForgeConductorApp/AppTelemetryBinding.swift:48` |
| `FC-PERF-001` | Critical | E1 | `P04` | Each gauge MTKView owns an independent command queue/pipeline and recurring render cadence | `Sources/ForgeConductorApp/Metal/MetalGaugeKit.swift:80` |
| `FC-PERF-001` | Critical | E1 | `P04` | Each gauge MTKView owns an independent command queue/pipeline and recurring render cadence | `Sources/ForgeConductorApp/Metal/MultiSeriesLoadRenderer.swift:40` |
| `FC-PERF-002` | High | E1 | `P03` | Gauge update path allocates replacement Metal buffers | `Sources/ForgeConductorApp/Metal/MultiSeriesLoadRenderer.swift:141` |
| `FC-PERF-003` | High | E1 | `P03` | Gauge hierarchy has an animation clock independent of telemetry and MTKView drawing | `Sources/ForgeConductorApp/Views/Rig/RigDashboardView.swift:17` |
| `FC-TELEM-DUPLICATE` | Medium | E1 | `P03` | Distinct telemetry cases return the same source expression | `Sources/ForgeConductorApp/AppModel.swift:73` |
| `FC-LIFE-GAP` | High | E3 | `P03` | AppTelemetryBinding owns/uses Task without an owner-local cleanup marker | `Sources/ForgeConductorApp/AppTelemetryBinding.swift:48` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ForgeConductorMain owns/uses DispatchSource without an owner-local cleanup marker | `Sources/ForgeConductorCLI/ForgeConductorMain.swift:224` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ForgeConductorMain owns/uses Process without an owner-local cleanup marker | `Sources/ForgeConductorCLI/ForgeConductorMain.swift:401` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ForgeConductorMain owns/uses Pipe/FileHandle without an owner-local cleanup marker | `Sources/ForgeConductorCLI/ForgeConductorMain.swift:416` |
| `FC-MEM-COLLECTION` | High | E3 | `P05` | Long-lived collection `missing` appends without an owner-local bound | `Sources/ForgeConductorCore/Application/AgentSessionService.swift:198` |
| `FC-MEM-COLLECTION` | High | E3 | `P08` | Long-lived collection `snaps` appends without an owner-local bound | `Sources/ForgeConductorCore/Application/ContextContinuityService.swift:436` |
| `FC-MEM-COLLECTION` | High | E3 | `P08` | Long-lived collection `merged` appends without an owner-local bound | `Sources/ForgeConductorCore/Application/ContextContinuityService.swift:469` |
| `FC-LIFE-GAP` | High | E3 | `P08` | ContextContinuityService owns/uses Task without an owner-local cleanup marker | `Sources/ForgeConductorCore/Application/ContextContinuityService.swift:609` |
| `FC-MEM-COLLECTION` | High | E3 | `P05` | Long-lived collection `suffix` appends without an owner-local bound | `Sources/ForgeConductorCore/Application/ToolAuthorizationService.swift:218` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ToolRouter owns/uses AsyncStream without an owner-local cleanup marker | `Sources/ForgeConductorCore/Application/ToolRouter.swift:94` |
| `FC-LIFE-GAP` | High | E3 | `P08` | HandoffPacket owns/uses Task without an owner-local cleanup marker | `Sources/ForgeConductorCore/Domain/HandoffPacket.swift:92` |
| `FC-LIFE-GAP` | High | E3 | `P05` | DashboardPortGuard owns/uses Process without an owner-local cleanup marker | `Sources/ForgeConductorCore/Infrastructure/DashboardPortGuard.swift:103` |
| `FC-LIFE-GAP` | High | E3 | `P05` | DashboardPortGuard owns/uses Pipe/FileHandle without an owner-local cleanup marker | `Sources/ForgeConductorCore/Infrastructure/DashboardPortGuard.swift:107` |
| `FC-MEM-COLLECTION` | High | E3 | `P07` | Long-lived collection `predicates` appends without an owner-local bound | `Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift:279` |
| `FC-MEM-COLLECTION` | High | E3 | `P07` | Long-lived collection `out` appends without an owner-local bound | `Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift:317` |
| `FC-MEM-COLLECTION` | High | E3 | `P07` | Long-lived collection `closed` appends without an owner-local bound | `Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift:551` |
| `FC-LIFE-GAP` | High | E3 | `P07` | MCPServer owns/uses Pipe/FileHandle without an owner-local cleanup marker | `Sources/ForgeConductorCore/MCP/MCPServer.swift:33` |
| `FC-LIFE-GAP` | High | E3 | `P07` | MCPStreamReader owns/uses Pipe/FileHandle without an owner-local cleanup marker | `Sources/ForgeConductorCore/MCP/MCPServer.swift:482` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ManagerRuntime owns/uses Timer without an owner-local cleanup marker | `Sources/ForgeConductorCore/Manager/ManagerRuntime.swift:18` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ManagerRuntime owns/uses DispatchSource without an owner-local cleanup marker | `Sources/ForgeConductorCore/Manager/ManagerRuntime.swift:18` |
| `FC-LIFE-GAP` | High | E3 | `P07` | MCPProcessFixture owns/uses Process without an owner-local cleanup marker | `Tests/ForgeConductorTests/ContinuityTests.swift:1800` |
| `FC-LIFE-GAP` | High | E3 | `P07` | MCPProcessFixture owns/uses Pipe/FileHandle without an owner-local cleanup marker | `Tests/ForgeConductorTests/ContinuityTests.swift:1801` |
| `FC-LIFE-GAP` | High | E3 | `P05` | ManagerTests owns/uses Task without an owner-local cleanup marker | `Tests/ForgeConductorTests/ManagerTests.swift:265` |

## Processing rule

Do not collapse all owner-local risks into confirmed leaks. Preserve each audit status, trace effective ownership, and attach the required runtime release-boundary proof. Critical and High findings block final completion until resolved.
