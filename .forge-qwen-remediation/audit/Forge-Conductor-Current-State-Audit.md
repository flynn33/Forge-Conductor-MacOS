# Forge Conductor Current-State Full Audit

## Executive conclusion

The concern is substantiated: **the current repository does not implement or qualify all planned Forge Conductor features**. It contains several strong and difficult foundations, but the complete product contract is not met.

Against the twelve planned implementation packages:

- **3 are implemented** at source level: project context, durable direct-process jobs, and shell/Bash.
- **6 are partial or implemented with release-blocking gaps**: canonical continuity, Python/PowerShell/XPC, real host driver, autonomous supervisor, real rollover, and hardening.
- **3 are missing**: safe project reset, instruction-package ingestion, and the durable Work Queue/UI.

The repository’s own completion report independently says completion is false and retains four release-blocking High findings. This audit also identifies a previously unpromoted **Critical completion-integrity defect**: generic tool-result hashes can satisfy arbitrary completion gates without running a gate-specific deterministic validator.

The current source does **not** disable shell by default. That regression is repaired in code. Its signed native UI/manager release gate remains open.

## Audit basis and limits

- Authoritative source: `Forge-Conductor-MacOS-main.zip`
- Archive SHA-256: `8b38cd6bf86f0e90a4fa0567fcc8e7e7ead88285f64e03880efe894d19c6aeb7`
- Files: 1,765; source/test Swift files: 194; Swift lines: 116,126; XCTest methods: approximately 669.
- Compared against the supplied autonomy expansion plan and its twelve work packages.
- Static source, configuration, schemas, tests, embedded evidence, and state ledgers were reviewed.
- No project source was modified.
- macOS/Xcode/AppKit/Metal/LaunchAgent/Keychain/signing/LM Studio execution could not be independently run on the Linux audit host. Runtime claims are therefore labeled separately from deterministic source findings.

## Planned-feature coverage

| Package | Capability | State | Principal gap |
|---|---|---|---|
| `FC-CTX-001` | Durable project context and bindings | **Implemented** | Release-native integration still depends on open UI gate. |
| `FC-CONT-001` | Canonical continuity consolidation | **Partial** | Legacy global fallback/manual client blocker remains active and authoritative on routed tools. |
| `FC-RESET-001` | Safe project reset and Settings UI | **Missing** | No selectable memory/continuity/combined/history reset, verified backup/rotation, complete maintenance barrier, or reset UI contract. |
| `FC-RUNTIME-001` | Durable execution jobs and direct processes | **Implemented** | Native cancel UI disabled; pressure-adjusted admission incomplete. |
| `FC-RUNTIME-002` | Shell and Bash | **Implemented** | Signed native Settings/restart qualification remains open. |
| `FC-RUNTIME-003` | Python, PowerShell, and hardened XPC | **Partial** | No signed App Sandbox XPC helper, security-scoped bookmark lifecycle, or hardenedXPC qualification. |
| `FC-QUEUE-001` | Instruction-package ingestion/catalog | **Missing** | No immutable Store/Quarantine/Artifacts ingestion, manifest validation, or compatibility importer. |
| `FC-QUEUE-002` | Durable queue, leases, runs, and Work Queue UI | **Missing** | No queue state machine, QueueAssignment, reservation/lease scheduler, package tools, deterministic package validators, or Work Queue UI. |
| `FC-HOST-001` | Real LM Studio driver and tool broker | **Partial** | Manager-owned real-provider end-to-end authority remains unproven; provider operator UI is incomplete. |
| `FC-AUTO-001` | Autonomous package/run supervisor | **Partial** | No package queue; completion validator can accept unrelated hashes; pressure adaptation incomplete. |
| `FC-AUTO-002` | Autonomous real-session rollover | **Partial** | Legacy blocker conflicts; real threshold-forced manager E2E gate open. |
| `FC-HARDEN-001` | Security, recovery, performance, migration, release gates | **Partial** | E2 open; signed UI/shell/autonomy gates open; dashboard read/connection issues; gauge scale; retention and pressure integration gaps. |

## What is genuinely implemented

1. **Shell source behavior is repaired.** New configuration defaults to enabled, legacy implicit-disabled state is migrated, explicit user opt-out is retained, `shell_exec` remains available, and durable shell/Bash/Python/PowerShell jobs exist.
2. **Project-scoped memory and generation fencing are substantial.** Per-project repositories, exact contexts, authorization scopes, bindings, and stale-generation rejection are present.
3. **A real LM Studio host adapter exists.** Production registration rejects the synthetic logical transport and includes durable provider/tool records.
4. **The new continuity engine is substantial.** Context budgeting, canonical rollover operations, exact successor acknowledgment, predecessor fencing, automatic continuation, and recovery logic exist.
5. **The original telemetry backlog defect is repaired.** UI delivery uses a latest-value mailbox with `bufferingNewest(1)` and bounded logical slots.
6. **Metal resource ownership is materially improved.** Device/queue/pipeline resources are shared, buffers are persistent/grow-only, and MTKViews are paused/on-demand.
7. **Runtime jobs are bounded and durable.** Output, timeouts, process groups, cancellation, project binding, and artifact quotas are implemented.
8. **Mutation authentication exists.** The manager’s mutating loopback routes require an owner-only bearer token using a bounded comparison.

## Findings overview

| Severity | Count |
|---|---:|
| Critical | 3 |
| High | 13 |
| Medium | 12 |
| Low | 2 |

| ID | Severity | Finding | Status |
|---|---|---|---|
| `FCA-001` | **Critical** | Completion gates are satisfied by generic tool-result hashes rather than gate-specific validators | Source-proven defect |
| `FCA-002` | **Critical** | Instruction-package ingestion, immutable store, durable Work Queue, and package tools are absent | Missing planned feature |
| `FCA-003` | **Critical** | Legacy fixed-count continuity still blocks the manager-owned autonomous provider loop and instructs manual chat rollover | Source-proven conflicting implementation |
| `FCA-004` | **High** | Project reset only increments generation; it does not reset memory or continuity safely | Missing planned feature |
| `FCA-005` | **High** | Global latest-handoff and global continuity projections remain active | Source-proven legacy risk |
| `FCA-006` | **High** | Manager-owned real-provider forced rollover is not proven end to end | Release-blocking gate open |
| `FCA-007` | **High** | Descriptor-relative E2 filesystem race remains mitigated but not eliminated | Known unresolved finding |
| `FCA-008` | **High** | The hardened App Sandbox XPC runtime scaffold was not implemented | Missing planned feature |
| `FCA-009` | **High** | ResourcePolicy pressure-adjusted execution, gauge cadence, and event limits are largely unused | Source-proven integration gap |
| `FCA-010` | **High** | Provider operator status and controls are placeholders | Partial feature |
| `FCA-011` | **High** | Root instructions require design packages that are absent from the archive | Missing required package content |
| `FCA-012` | **High** | The bundled release state references multiple branches/commits and cannot be independently tied to the archive | Inconsistent evidence state |
| `FCA-013` | **High** | The signed native UI matrix has not run | Release-blocking gate open |
| `FCA-014` | **High** | Shell is enabled in source, but native Settings-to-manager compatibility remains unproven | Source implemented; native gate open |
| `FCA-015` | **High** | The Rig can instantiate roughly 288 native Metal gauge surfaces from bounded lists | Profiling target |
| `FCA-016` | **High** | Autonomy/control-plane event and provider history tables have no bounded archival policy | Source-proven retention gap |
| `FCA-017` | **Medium** | Project relink is displayed but disabled | Partial feature |
| `FCA-018` | **Medium** | Durable job cancellation exists in the backend but the native Cancel Job action is disabled | Partial feature |
| `FCA-019` | **Medium** | Checkpoint and early-rollover controls are disabled placeholders | Partial feature |
| `FCA-020` | **Medium** | Forge recompose appends an additional history point from the last host sample | Source-proven defect |
| `FCA-021` | **Medium** | Frequent telemetry publication repeatedly shifts and copies history arrays | Source-proven allocation churn |
| `FCA-022` | **Medium** | gauge.surfaces.visible measures attached surfaces, not actual visibility | Source-proven metric mismatch |
| `FCA-023` | **Medium** | Loopback HTTP connections have no explicit admission cap or idle read deadline | Source-proven gap |
| `FCA-024` | **Medium** | Sensitive manager status and operator snapshot reads are exempt from authorization | Source-proven policy gap |
| `FCA-025` | **Medium** | Two LM Studio contract fixture test files are absent from the Xcode test target | Source-proven build configuration gap |
| `FCA-026` | **Medium** | The source archive contains large build/evidence state and hundreds of absolute local paths | Source-proven packaging issue |
| `FCA-027` | **Medium** | Version and continuity documentation remain on 0.9.0/manual-new-chat semantics | Source-proven inconsistency |
| `FCA-028` | **Medium** | Runtime and provider version/health projections remain incomplete | Partial feature |
| `FCA-029` | **Low** | Very large core files and extensive @unchecked Sendable usage increase regression risk | Engineering risk |
| `FCA-030` | **Low** | The package cannot be built or tested in the current Linux audit environment | Qualification limitation |

## Detailed findings

### FCA-001 — Completion gates are satisfied by generic tool-result hashes rather than gate-specific validators

- **Severity:** Critical
- **Category:** Autonomy / completion integrity
- **Status:** Source-proven defect
- **Evidence class:** E1
- **Determination:** The managed step executor hashes every persisted tool result into a generic evidence list. Model-supplied gate_evidence is accepted when the hash merely appears in that list. The production EvidenceBoundCompletionValidator then marks the named gate passed without proving the result was successful, relevant to that gate, produced by an approved validator, or bound to a command/artifact specification.
- **Impact:** A run can be marked complete by reusing an unrelated or failed tool result. This defeats the planned rule that a completion claim starts deterministic validators and only passing gates complete a package.
- **Evidence:** `Sources/ForgeConductorCore/Application/ManagedProjectRunStepExecutor.swift:369-400; Sources/ForgeConductorCore/Application/ManagedAutonomyRuntime.swift:18-45,165; Sources/ForgeConductorCore/Application/ProjectRunCoordinator.swift:68-115`
- **Required correction:** Replace EvidenceBoundCompletionValidator in production with typed, gate-specific deterministic validators. Persist validator identity/version, command or test specification, exit status, artifact hashes, project generation, run ID, and replay policy. Never accept model-declared evidence as proof by itself.

### FCA-002 — Instruction-package ingestion, immutable store, durable Work Queue, and package tools are absent

- **Severity:** Critical
- **Category:** Instruction packages / queue
- **Status:** Missing planned feature
- **Evidence class:** E1
- **Determination:** The source, tests, and product documentation contain no PackageQueue, PackageIngestion, QueueAssignment, .forgepackage importer, queue.current, package.progress, package.blocked, package.complete_request, package.artifact.register, or Work Queue implementation.
- **Impact:** Forge cannot autonomously ingest, validate, schedule, resume, validate, and advance through instruction packages as planned. The existing manual run form is not a package queue.
- **Evidence:** `Repository-wide zero-match scan for required queue symbols; Sources/ForgeConductorApp/AppModel.swift:71-84 has no Work Queue tab`
- **Required correction:** Implement FC-QUEUE-001 and FC-QUEUE-002: immutable hash-addressed ingestion, quarantine, leases, durable queue/run records, deterministic completion validation, model-facing package tools, and native Work Queue UI.

### FCA-003 — Legacy fixed-count continuity still blocks the manager-owned autonomous provider loop and instructs manual chat rollover

- **Severity:** Critical
- **Category:** Continuity / autonomy
- **Status:** Source-proven conflicting implementation
- **Evidence class:** E1
- **Determination:** Every routed tool call still passes through ContinuityAutomation blocking and applyRuntimeContinuity. At its legacy threshold it writes a handoff, blocks project tools for the client, and tells the operator to start a new LM Studio chat and call context_get. Managed runs invoke the same ToolRouter, so the legacy client blocker can interrupt the newer manager-owned context-budget/rollover state machine.
- **Impact:** Autonomous long-running work can stop on a manual bootstrap contract even though a real session-host adapter and rollover worker exist. Two continuity authorities can make contradictory decisions.
- **Evidence:** `Sources/ForgeConductorCore/Application/ToolRouter.swift:397-407,693,934-985; Sources/ForgeConductorCore/Application/ContinuityAutomation.swift:307-327,430-487; Sources/ForgeConductorCore/Application/ContextContinuityService.swift:95-110`
- **Required correction:** Make canonical project-scoped ContinuityCoordinator/ContextBudgetSupervisor the sole authority for managed runs. Disable legacy blocking for managed invocation contexts; retain legacy external-MCP compatibility only as an explicitly labeled non-autonomous mode.

### FCA-004 — Project reset only increments generation; it does not reset memory or continuity safely

- **Severity:** High
- **Category:** Project lifecycle
- **Status:** Missing planned feature
- **Evidence class:** E1
- **Determination:** The manager exposes resetProjectGeneration and the UI exposes Reset Generation. The flow enters resetting state, closes the memory repository, increments generation, and invalidates bindings, but there is no ProjectResetService implementing selectable memory, continuity, combined, or run-history reset; no verified backup/rotation; and no full repository/control-plane cleanup.
- **Impact:** The required reset semantics are not available. Users cannot reliably clear one project’s memory/continuity while preserving others, and generation reset may leave the old durable content in place.
- **Evidence:** `Sources/ForgeConductorCore/Manager/ManagerNode.swift:418-442; Sources/ForgeConductorCore/Infrastructure/ProjectControlPlaneRepository.swift:511-575; Sources/ForgeConductorApp/OperatorConsole/Views/ProjectsOperatorView.swift:181-191`
- **Required correction:** Implement the planned maintenance barrier, repository eviction, hash-verifiable backup, selected table/database rotation, continuity projection rebuild, generation fencing, reset receipt, and mode-specific UI.

### FCA-005 — Global latest-handoff and global continuity projections remain active

- **Severity:** High
- **Category:** Project isolation / continuity
- **Status:** Source-proven legacy risk
- **Evidence class:** E1
- **Determination:** ContinuityAutomation first checks a client-specific packet and then falls back to a global packet. Legacy continuity still writes/uses global current-task, NEXT-CHAT, LATEST, and context_get bootstrap projections.
- **Impact:** The plan required exact project authority and no global latest fallback. Remaining global projections can reintroduce cross-project assumptions in external MCP/legacy paths.
- **Evidence:** `Sources/ForgeConductorCore/Application/ContinuityAutomation.swift:95-120; Sources/ForgeConductorCore/Application/ContextContinuityService.swift:95-110,609-620,770-795; USER-GUIDE.md:139-194`
- **Required correction:** Remove global latest as authority. Require exact ProjectID + ProjectGeneration + client/session binding or fail project_context_required. Keep any global dashboard summary strictly non-authoritative.

### FCA-006 — Manager-owned real-provider forced rollover is not proven end to end

- **Severity:** High
- **Category:** Autonomous continuity qualification
- **Status:** Release-blocking gate open
- **Evidence class:** E0 required
- **Determination:** The repository’s host capability report explicitly sets autonomous_rollover_proven=false. Direct adapter and synthetic/unit evidence exists, but one threshold-forced manager-owned real LM Studio scenario has not proven acknowledgment, predecessor fencing/sealing, automatic continuation, GUI-closed operation, and crash recovery together.
- **Impact:** Source code is substantial, but the central autonomous-continuity promise is not release-qualified.
- **Evidence:** `.forge-codex/state/host-capability-report.json; .forge-codex/state/completion-report.json; .forge-autonomy-state/current-handoff.json`
- **Required correction:** Run a low-threshold real-provider scenario through the LaunchAgent manager; inject termination at every nonterminal rollover state; prove exactly one accepted successor and automatic continuation with the GUI closed.

### FCA-007 — Descriptor-relative E2 filesystem race remains mitigated but not eliminated

- **Severity:** High
- **Category:** Filesystem security
- **Status:** Known unresolved finding
- **Evidence class:** E2
- **Determination:** The current state ledger explicitly retains FC-FILESYSTEM-PATH-TOCTOU-001. It records a verifier-to-final-mutation race, unbounded possible final-link data loss or subtree relocation for one winning race, repeated opportunities across a large recursive request, initial anchoring/destination hierarchy gaps, and hard-link ctime ambiguity.
- **Impact:** The current implementation must not be represented as having closed E2. Same-UID adversarial mutation remains within the documented threat surface.
- **Evidence:** `.forge-autonomy-state/current-handoff.json residual_risk/open_blockers; Sources/ForgeConductorCore/Application/Tools/FilesystemToolPack.swift; missing .forge-e2 directory`
- **Required correction:** Implement and qualify the atomic capture/transaction design from the E2 package or formally narrow the threat model. Preserve quarantine recovery and shell compatibility. Keep the finding open until adversarial macOS tests prove the closure argument.

### FCA-008 — The hardened App Sandbox XPC runtime scaffold was not implemented

- **Severity:** High
- **Category:** Runtime isolation
- **Status:** Missing planned feature
- **Evidence class:** E1
- **Determination:** Product sources and build definitions contain no NSXPCConnection, XPC service target, security-scoped bookmark lifecycle, or hardenedXPC execution profile. Runtime isolation relies on process-level profiles/sandbox-exec rather than a separately signed App Sandbox helper.
- **Impact:** The planned high-assurance execution mode and its signed boundary are absent. Workspace isolation must not be described as the planned hardened XPC security boundary.
- **Evidence:** `Repository-wide zero-match scan for NSXPCConnection/XPCService/security-scoped bookmark/hardenedXPC; Package.swift has no helper target`
- **Required correction:** Add the optional signed helper target with explicit entitlement profiles, bookmark ownership, descendant enforcement, network-denied profile, and signed macOS tests—or explicitly remove the feature from the product contract.

### FCA-009 — ResourcePolicy pressure-adjusted execution, gauge cadence, and event limits are largely unused

- **Severity:** High
- **Category:** Efficiency / memory pressure
- **Status:** Source-proven integration gap
- **Evidence class:** E1
- **Determination:** ResourcePolicy defines activeGaugeFPS, maximumInMemoryEvents, and executionLimits(for:), but production references are absent outside the policy definition. Managed concurrency and runtime defaults remain based primarily on nominal physical-memory tier; only telemetry history responds directly to pressure.
- **Impact:** The application does not yet meet the planned adaptive behavior for Macs with different and dynamically constrained memory. During pressure it can continue rendering and scheduling at nominal settings.
- **Evidence:** `Sources/ForgeConductorCore/Infrastructure/ResourcePolicy.swift:1-260; repository-wide usage scan finds no production consumers of activeGaugeFPS, maximumInMemoryEvents, or executionLimits(for:)`
- **Required correction:** Create one manager-owned ResourcePressureCoordinator and wire it to autonomy concurrency, runtime admission, telemetry cadence/history, gauge updates, event retention, provider payload limits, and package scheduling with hysteresis.

### FCA-010 — Provider operator status and controls are placeholders

- **Severity:** High
- **Category:** Provider operations / UI
- **Status:** Partial feature
- **Evidence class:** E1
- **Determination:** ProviderOperatorView renders Test Connection and Run Contract Probe buttons with empty actions. ManagerNode’s provider projection does not expose a live health/contract probe/configuration path and leaves critical fields unavailable.
- **Impact:** Operators cannot configure, verify, or diagnose the real provider path from the native product, undermining autonomous operation and recovery.
- **Evidence:** `Sources/ForgeConductorApp/OperatorConsole/Views/ProviderOperatorView.swift:1-90; Sources/ForgeConductorCore/Manager/ManagerNode.swift:843-900`
- **Required correction:** Add typed manager mutations for provider configuration/Keychain references, test connection, model/context discovery, contract probe, and bounded health history. Wire buttons and surface actionable errors.

### FCA-011 — Root instructions require design packages that are absent from the archive

- **Severity:** High
- **Category:** Implementation governance
- **Status:** Missing required package content
- **Evidence class:** E1
- **Determination:** AGENTS.md requires .forge-continuity-design/AGENTS.md and its work-packages file before continuity/provider/runtime work. Neither .forge-continuity-design nor .forge-e2 is present in this current-state archive.
- **Impact:** The repository’s own autonomous execution contract cannot be followed reproducibly from the delivered source. Future repair agents can drift from the authoritative design.
- **Evidence:** `AGENTS.md:1-5; directory inventory`
- **Required correction:** Commit the required compact design contracts/schemas or remove stale references and replace them with a complete, versioned in-repository specification. Do not rely on an external transient package.

### FCA-012 — The bundled release state references multiple branches/commits and cannot be independently tied to the archive

- **Severity:** High
- **Category:** Release provenance
- **Status:** Inconsistent evidence state
- **Evidence class:** E1
- **Determination:** The archive contains no .git metadata. Completion state references commit 628821..., run state uses an earlier active package set, and the latest handoff references baseline 628821... plus published source f721ce.../PR 12. Many evidence paths point to different local worktrees. The current source manifest matches selected evidence, but branch/commit provenance cannot be independently verified from the archive.
- **Impact:** A release decision based only on the embedded ledger could apply evidence to the wrong source lineage.
- **Evidence:** `.forge-codex/state/completion-report.json; .forge-autonomy-state/run.json; .forge-autonomy-state/current-handoff.json; no .git directory`
- **Required correction:** Produce one immutable release attestation binding archive SHA-256, source manifest, Git commit/tree, dependency/toolchain versions, gate results, and signatures. Reject mixed-lineage gate state.

### FCA-013 — The signed native UI matrix has not run

- **Severity:** High
- **Category:** Native UI qualification
- **Status:** Release-blocking gate open
- **Evidence class:** E0 required
- **Determination:** Embedded evidence compiles the XCUITest target but executes zero tests. A later ad-hoc launch verifies a process only. Developer Mode/signing prerequisites remained unavailable.
- **Impact:** Settings shell control, project reset UI, manager reconnect, operator views, navigation lifecycle, and real GUI-to-manager behavior remain unqualified.
- **Evidence:** `EVID-20260828T124634Z-c6c0c861da; EVID-20260828T131739Z-66596e8e37; .forge-autonomy-state/current-handoff.json`
- **Required correction:** Run the signed XCUITest and native stress matrix on a matching-team macOS host. Keep the gate DEFERRED_ENVIRONMENT—RELEASE BLOCKING until tests execute.

### FCA-014 — Shell is enabled in source, but native Settings-to-manager compatibility remains unproven

- **Severity:** High
- **Category:** Shell qualification
- **Status:** Source implemented; native gate open
- **Evidence class:** E0 required
- **Determination:** The current source defaults shell enabled, migrates legacy implicit-disabled state, preserves explicit opt-out, retains shell_exec, and implements runtime tools. However the repository itself keeps FC-SHELL-COMPAT-QUALIFICATION-001 open because native process relaunch and signed Settings execution were not performed.
- **Impact:** The prior disabled-shell regression appears repaired at source/test level, but release acceptance still requires the actual app/manager path.
- **Evidence:** `Sources/ForgeConductorCore/Domain/AppConfig.swift:25-50; Sources/ForgeConductorCore/Infrastructure/ConfigStore.swift:280-315,360-390; Sources/ForgeConductorCore/Application/Tools/ShellToolPack.swift:9-55; .forge-autonomy-state/current-handoff.json`
- **Required correction:** Execute clean install, migration, Settings toggle, MCP tools/list and command, app restart, manager restart, project switch, memory reset, and continuity reset through the signed native application.

### FCA-015 — The Rig can instantiate roughly 288 native Metal gauge surfaces from bounded lists

- **Severity:** High
- **Category:** Rendering performance
- **Status:** Profiling target
- **Evidence class:** E3
- **Determination:** Static list maxima yield about 192 tool bars, 12 pack bars, 24 MCP bars, 24 agent bars, 12 process bars, and 24 feed bars, before additional system/status surfaces. Resources are now shared and MTKViews are on-demand, but the native view count remains large.
- **Impact:** On low-memory Macs, hundreds of MTKViews can still produce allocation, layer, command-buffer, and SwiftUI bridging overhead. Static analysis cannot label this a leak without Instruments.
- **Evidence:** `Sources/ForgeConductorApp/Views/Rig/RigDashboardView.swift:365-600; Sources/ForgeConductorApp/Metal/MetalGaugeResources.swift:1-145`
- **Required correction:** Run Metal System Trace, Allocations, Time Profiler, and SwiftUI instruments with visible/hidden navigation cycles. Consider one batched Metal surface per section or per dashboard and viewport virtualization.

### FCA-016 — Autonomy/control-plane event and provider history tables have no bounded archival policy

- **Severity:** High
- **Category:** Durable storage efficiency
- **Status:** Source-proven retention gap
- **Evidence class:** E1
- **Determination:** Context-budget observations and runtime jobs have compaction, but autonomy_events, provider turns, tool invocations, provider sessions, continuity commands, autonomous runs, and legacy audit_events are append-only or query-limited without a production pruning/archive path.
- **Impact:** Long-running autonomous installations can grow durable SQLite storage indefinitely even when in-memory histories are bounded. This is disk retention, not a proven heap leak.
- **Evidence:** `Sources/ForgeConductorCore/Infrastructure/ProjectControlPlaneRepository.swift:4350-4665; Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift:1720-1785; absence of corresponding DELETE/prune paths`
- **Required correction:** Implement project-scoped retention classes, segmented/hash-checkpointed audit archives, bounded provider/tool payload retention, compaction receipts, and operator-configurable quotas that preserve required forensic integrity.

### FCA-017 — Project relink is displayed but disabled

- **Severity:** Medium
- **Category:** Project UI
- **Status:** Partial feature
- **Evidence class:** E1
- **Determination:** The Projects UI contains a Relink button with an empty action and disabled state. No corresponding manager mutation was located.
- **Impact:** Moved or reauthorized project roots cannot be repaired through the planned native project lifecycle.
- **Evidence:** `Sources/ForgeConductorApp/OperatorConsole/Views/ProjectsOperatorView.swift:175-186`
- **Required correction:** Implement relink with expected generation, bookmark/root identity validation, authorization re-evaluation, stale-binding fencing, and an auditable receipt.

### FCA-018 — Durable job cancellation exists in the backend but the native Cancel Job action is disabled

- **Severity:** Medium
- **Category:** Runtime UI
- **Status:** Partial feature
- **Evidence class:** E1
- **Determination:** The runtime service and MCP job.cancel tool exist, but RuntimesOperatorView’s Cancel Job button has no action.
- **Impact:** Operators cannot stop jobs from the native UI despite the planned Runtimes surface.
- **Evidence:** `Sources/ForgeConductorApp/OperatorConsole/Views/RuntimesOperatorView.swift:130-142; Sources/ForgeConductorCore/Application/Tools/RuntimeJobToolPack.swift`
- **Required correction:** Wire a typed cancel mutation with project/run/generation checks, terminal receipt display, and process-group termination state.

### FCA-019 — Checkpoint and early-rollover controls are disabled placeholders

- **Severity:** Medium
- **Category:** Continuity UI
- **Status:** Partial feature
- **Evidence class:** E1
- **Determination:** ContinuityOperatorView renders Checkpoint Now and Request Early Rollover with empty actions.
- **Impact:** The planned administrative continuity controls are unavailable for recovery and qualification.
- **Evidence:** `Sources/ForgeConductorApp/OperatorConsole/Views/ContinuityOperatorView.swift:155-166`
- **Required correction:** Add authenticated typed manager commands that enqueue canonical operations, return operation IDs, and stream durable state transitions.

### FCA-020 — Forge recompose appends an additional history point from the last host sample

- **Severity:** Medium
- **Category:** Telemetry correctness
- **Status:** Source-proven defect
- **Evidence class:** E1
- **Determination:** onSystemSample appends a history point, and recomposeForgeAndPublish also appends another point using currentSystem. When no new host sample has arrived, the same sample is represented again at a new timestamp.
- **Impact:** History cadence can be distorted and chart density no longer corresponds strictly to host samples.
- **Evidence:** `Sources/ForgeConductorCore/Telemetry/TelemetryService.swift:179-203,216-241`
- **Required correction:** Append host history only on host samples. Recompose Forge/MCP cards without adding a second system point, or explicitly label separate sample sources.

### FCA-021 — Frequent telemetry publication repeatedly shifts and copies history arrays

- **Severity:** Medium
- **Category:** Telemetry efficiency
- **Status:** Source-proven allocation churn
- **Evidence class:** E1
- **Determination:** Both host sampling and Forge recompose append, removeFirst on overflow, create Array(history.suffix(300)), copy listener state, and construct complete snapshots. The workload is bounded but allocation-heavy at high sample rates.
- **Impact:** This can raise CPU and transient memory pressure and look leak-like under sustained operation.
- **Evidence:** `Sources/ForgeConductorCore/Telemetry/TelemetryService.swift:179-265`
- **Required correction:** Use a fixed-capacity ring buffer with snapshot views/copy-on-publish at a lower UI cadence; separate raw host collection from UI frame composition and coalesce unchanged Forge cards.

### FCA-022 — gauge.surfaces.visible measures attached surfaces, not actual visibility

- **Severity:** Medium
- **Category:** Observability
- **Status:** Source-proven metric mismatch
- **Evidence class:** E1
- **Determination:** GaugeSurfaceLifetime increments active and visible together on attach and decrements both on detach. It does not observe window attachment, occlusion, tab selection, or hidden state.
- **Impact:** The telemetry cannot prove gauges are quiescent when off-screen, weakening the performance gate and misleading diagnostics.
- **Evidence:** `Sources/ForgeConductorApp/Metal/MetalGaugeResources.swift:118-142`
- **Required correction:** Track allocated, window-attached, actually-visible, and drawing surfaces separately using view/window lifecycle callbacks and dashboard visibility state.

### FCA-023 — Loopback HTTP connections have no explicit admission cap or idle read deadline

- **Severity:** Medium
- **Category:** Dashboard security / reliability
- **Status:** Source-proven gap
- **Evidence class:** E2
- **Determination:** Every accepted NWConnection is started and incomplete reads recurse. The server does not maintain a bounded accepted-connection registry, enforce a header/read deadline, or cancel all accepted connections on stop.
- **Impact:** A same-user process can hold many idle loopback connections and consume file descriptors/memory. Stop may leave peer-held connections alive until transport closure.
- **Evidence:** `Sources/ForgeConductorCore/Dashboard/DashboardServer.swift:100-210`
- **Required correction:** Add a bounded connection registry, per-connection monotonic deadline, maximum header/body bytes, cancellation on stop, and diagnostics for rejected/expired connections.

### FCA-024 — Sensitive manager status and operator snapshot reads are exempt from authorization

- **Severity:** Medium
- **Category:** Dashboard confidentiality
- **Status:** Source-proven policy gap
- **Evidence class:** E1
- **Determination:** Mutation authorization intentionally exempts manager status, settings, operator snapshot, autonomy status, and project/run status endpoints. Operator snapshots can expose canonical roots, run missions, provider/session identifiers, runtime command/cwd summaries, continuity state, and events.
- **Impact:** Any same-user process able to reach loopback can read detailed project operational metadata even though mutations require the bearer token.
- **Evidence:** `Sources/ForgeConductorCore/Dashboard/ManagerRoutes.swift:185-218,282-325; operator snapshot models`
- **Required correction:** Require owner token for sensitive reads or split a minimal non-sensitive health endpoint from authenticated operational data. Keep constant-time bounded token comparison.

### FCA-025 — Two LM Studio contract fixture test files are absent from the Xcode test target

- **Severity:** Medium
- **Category:** Test parity
- **Status:** Source-proven build configuration gap
- **Evidence class:** E1
- **Determination:** SwiftPM includes all tests, but the Xcode project file does not reference LMStudioContractFixtureServer.swift or LMStudioContractFixtureTests.swift.
- **Impact:** The native Xcode test matrix can omit provider protocol tests that are central to autonomous continuity.
- **Evidence:** `ForgeConductor.xcodeproj/project.pbxproj membership scan`
- **Required correction:** Add both files to the Xcode test target and add a parity test that fails whenever a SwiftPM test source is missing from Xcode membership.

### FCA-026 — The source archive contains large build/evidence state and hundreds of absolute local paths

- **Severity:** Medium
- **Category:** Repository hygiene / privacy
- **Status:** Source-proven packaging issue
- **Evidence class:** E1
- **Determination:** The archive includes .build, about 134 MiB of .forge-codex state/evidence, additional autonomy state, and hundreds of files containing /Users/jimdaley paths. .gitignore ignores .build but not the execution-state directories.
- **Impact:** Distribution size, review cost, clone performance, reproducibility, and local-path metadata exposure are unnecessarily increased.
- **Evidence:** `Archive inventory and byte counts; .gitignore; absolute-path scan`
- **Required correction:** Separate release source from local evidence. Publish a compact signed evidence bundle by content hash; normalize paths; ignore local run state; retain only schemas, scripts, and release attestations needed in source control.

### FCA-027 — Version and continuity documentation remain on 0.9.0/manual-new-chat semantics

- **Severity:** Medium
- **Category:** Documentation / product contract
- **Status:** Source-proven inconsistency
- **Evidence class:** E1
- **Determination:** README, architecture, telemetry, and user guide still identify 0.9.0. The guide explicitly says the tree is not release-qualified and repeatedly directs users to start a new chat and call context_get, conflicting with the manager-owned autonomous-continuity objective.
- **Impact:** Users and future implementers cannot tell which mode is authoritative, and the documented feature set lags the source.
- **Evidence:** `README.md:9,103-153; USER-GUIDE.md:3-7,127-194,272-324; docs/CONTEXT-AGENT-CONTINUITY.md:1-65`
- **Required correction:** Publish versioned mode-specific documentation: managed autonomous mode, external MCP compatibility mode, release qualification, shell defaults, runtime tools, project reset, and remaining limitations.

### FCA-028 — Runtime and provider version/health projections remain incomplete

- **Severity:** Medium
- **Category:** Operator projections
- **Status:** Partial feature
- **Evidence class:** E1
- **Determination:** Operator models leave executable versions and several provider health fields nil/unavailable even though capability discovery and provider adapters exist.
- **Impact:** Operators cannot reliably diagnose incompatible runtimes or provider model/context configuration.
- **Evidence:** `Sources/ForgeConductorCore/Manager/ManagerNode.swift operator projection methods; Sources/ForgeConductorApp/OperatorConsole`
- **Required correction:** Collect bounded version probes and provider model/context metadata in the manager, cache with TTL, and expose last-success/last-error timestamps.

### FCA-029 — Very large core files and extensive @unchecked Sendable usage increase regression risk

- **Severity:** Low
- **Category:** Maintainability / concurrency
- **Status:** Engineering risk
- **Evidence class:** E3
- **Determination:** Several core files exceed 2,000-5,000 lines, and the project contains many @unchecked Sendable declarations. Current strict compilation evidence passes, so this is not a proven data race.
- **Impact:** Ownership, cancellation, isolation, and testability become harder to reason about, especially in the manager/control-plane/runtime subsystems.
- **Evidence:** `Source line-count inventory; repository-wide @unchecked Sendable scan`
- **Required correction:** Incrementally split repositories/services by aggregate and transaction boundary; replace unchecked conformance with actors, immutable Sendable values, or narrowly documented locks; add concurrency stress tests.

### FCA-030 — The package cannot be built or tested in the current Linux audit environment

- **Severity:** Low
- **Category:** Environment / portability
- **Status:** Qualification limitation
- **Evidence class:** E0 required
- **Determination:** swift package describe succeeds, but swift test fails immediately because a product imports Darwin and the package targets macOS 26. xcodebuild is unavailable.
- **Impact:** This audit can verify source structure and embedded current-manifest evidence, but cannot independently execute macOS, Xcode, AppKit, Metal, LaunchAgent, Keychain, signing, or LM Studio gates.
- **Evidence:** `evidence/independent-command-evidence.json`
- **Required correction:** Run the required commands on a macOS 26 Xcode host and attach immutable evidence bound to this archive/source manifest.

## Memory-leak and performance conclusion

The earlier unbounded MainActor telemetry delivery path and per-gauge duplicated Metal resource construction appear repaired in the current source. This audit did **not** identify a new deterministic permanent retain cycle in those repaired paths. It therefore does not label the application as leak-free or claim a measured runtime improvement.

The remaining evidence-based risks are:

- hundreds of possible native Metal surfaces;
- telemetry ring-buffer replacement/copy churn and duplicate history samples;
- pressure-adjusted resource limits not wired across the product;
- append-only durable control-plane/audit histories;
- unbounded accepted dashboard connection lifetime;
- native UI and low-memory Instruments gates not run.

These require the same visible/hidden navigation flow under Allocations, Leaks, SwiftUI, Time Profiler, Metal System Trace, and memory-pressure injection. A lower aggregate memory number alone is not acceptance evidence.

## Required repair order

1. **Close FCA-001 first.** Completion truth is foundational; no autonomy/package result is trustworthy while arbitrary generic evidence can pass gates.
2. **Consolidate continuity authority.** Remove the legacy manual blocker/global fallback from managed mode before claiming autonomous rollover.
3. **Implement package ingestion and Work Queue.** This is the missing orchestration layer the plan centered on.
4. **Implement real project reset.** Add maintenance lease, backups, repository eviction, selective reset, generation fencing, and receipts.
5. **Wire resource pressure end to end.** Admission, concurrency, telemetry, gauge rendering, event retention, and provider payloads must degrade coherently.
6. **Complete native operator actions.** Provider probe/configuration, project relink, runtime cancellation, checkpoint, and early rollover.
7. **Resolve or explicitly constrain E2.** Do not call quarantine-and-verify elimination.
8. **Run the release-blocking macOS matrix.** Signed UI, shell lifecycle, real manager-owned rollover, crash injection, low-memory stress, Instruments, Keychain, LaunchAgent, and Xcode parity.
9. **Produce a single release attestation.** Bind source archive, Git tree, source manifest, toolchain, evidence, and all gates.

## Acceptance position

The project should be classified as **advanced partial implementation — not release complete**. It is suitable for continued engineering and focused qualification, but not for a claim that every planned feature works autonomously, reliably, and efficiently.
