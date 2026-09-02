# Forge Conductor architecture

Forge Conductor is a native macOS orchestration server for local models hosted by LM Studio. The same codebase supplies a SwiftUI/Metal operator app, a CLI, a persistent local manager, and MCP stdio connector processes.

## Design rules

1. `ForgeConductorCore` contains reusable domain and service modules; executable targets are composition and presentation shells.
2. Dependencies point inward through Swift protocols. LM Studio installation and MCP verification are injected ports, not hard-coded global calls.
3. The Apple-native stack is Foundation, SwiftUI, AppKit, Combine, Metal, Network, IOKit, Mach, SQLite3, and FileManager. The runtime does not require Node or Python.
4. Framework features are exposed through modular `ToolPackHandling` implementations and stable MCP tool names.
5. Primary and fallback LM Studio connectors are independent processes with typed identities and aggregate health.
6. Persistent sessions, active bindings, memory notes, and context handoffs survive process restarts.

## Package products

| Product / target | Responsibility |
|---|---|
| `ForgeFilesystemProtocol` | Shared protocol-v5 request, identity, recovery, and receipt contracts for the privileged filesystem boundary |
| `ForgeConductorCore` | Domain, application services, infrastructure, MCP, manager, dashboard, telemetry |
| `ForgeNativeSessionHostPlugin` | Native provider adapter and session-host integration used by continuity workflows |
| `forge-conductor` / `ForgeConductorCLI` | CLI, installer, manager commands, and MCP stdio executable |
| `forge-conductor-app` / `ForgeConductorApp` | SwiftUI/AppKit/Metal operator application |
| `forge-runtime-launcher` / `ForgeRuntimeLauncher` | Signed, resource-bounded native process launcher for managed jobs |
| `forge-filesystem-daemon` / `ForgeFilesystemDaemon` | Privileged leaf capture, protected quarantine, and request recovery; authorized quarantine disposition and E2 qualification remain open |
| `ForgeConductorTests` | Unit, integration, security, connector, and process acceptance tests |

The Xcode project mirrors these boundaries. SwiftPM provides a second
reproducible Apple-native build path. `script/build_and_run.sh` stages the GUI,
embedded manager CLI, runtime launcher, filesystem daemon, and daemon property
list, then signs nested code before strictly verifying the enclosing bundle.
The script does not synthesize Xcode's embedded framework layout.

Signed Xcode products bind each role to an exact Apple signing requirement.
Development team `9AQ2C2838M` requires Apple Development; distribution team
`2Y25RTLZET` requires Developer ID Application. Manager staging, runtime launch,
and the outer bundle verifier apply the corresponding Apple anchor, identifier,
team, and certificate-class requirement to the app, CLI, daemon, runtime
launcher, and core framework. This is identity admission, not rollback
freshness or Developer ID release qualification.

## Core module map

```text
Domain/          Typed models, connector roles/health, protocols, JSON support
Application/     Composition root, agent/session/continuity/project-memory services, authorization, tool packs
Infrastructure/ Paths, configuration, SQLite stores, resource policy, audit, diagnostics, process execution
MCP/             Bounded JSON-RPC stdio server and independent serve verifier
Manager/         Persistent local service lifecycle and normalized settings
Dashboard/       Loopback HTTP telemetry/control surface and request policy
Telemetry/       Native collectors, bounded latest-value delivery, LM Studio discovery, transactional deployment
```

## Composition root

```text
ForgeApp.bootstrap(home:)
  -> AppPaths + ConfigStore
  -> SQLiteStore migration
  -> AuditService + DiagnosticLog
  -> AgentCatalog + AgentSessionService
  -> ContextContinuityService + ContinuityCoordinator
  -> ProjectMemoryService + HostAdapterRegistry
  -> ProjectControlPlaneRepository + RuntimeJobSubsystem
  -> ManagedAutonomyRuntime + ManagedContinuityWorker
  -> ResourcePolicy + RuntimeDiagnostics
  -> LM Studio installer/verifier/deploy services
  -> ToolAuthorizationService -> ToolRouter -> modular tool packs
  -> TelemetryService
```

The root owns its services. Back-references are non-owning, avoiding service cycles. Presentation code receives the root through `AppModel`; it does not construct infrastructure directly.

## Managed runtime ownership

The runtime subsystem durably records job intent and exact process-group identity before releasing a signed native launcher to execute the requested tool. Read roots and writable roots are explicit and independently validated. Child-writable scratch is separate from manager-owned, hash-verified output artifacts. Each job has bounded output, duration, descendants, CPU time, descriptors, and file size.

Normal completion, cancellation, timeout, restart recovery, and application shutdown converge on the same persisted TERM/KILL/probe state machine. A process group remains owned until exact-identity liveness checks confirm its death; service stores remain open while the bounded reaper still has ownership work. Startup also performs a bounded sweep of scratch and artifact directories that lack a matching durable job row.

## Manager ownership

The persistent LaunchAgent `ManagerNode` is the sole owner of the loopback dashboard port. A double-clicked GUI detects an existing manager by its PID file and port ownership, then attaches through the typed, Foundation-native `ManagerDashboardClient`. If no manager exists, the GUI may host a local manager. Remote status polling retries transient loss and Manager controls use the same loopback API, so a GUI launch never competes with a healthy manager for port 7788.

Accepted provider receipts are manager-owned and durable across restart. An
unresolved provider response is fenced for 660 seconds; after that, one retry
can create at most one duplicate model inference. LM Studio exposes no request-
ID receipt lookup, so repeated retries can repeat inference. Durable tool-effect
reconciliation prevents duplicate tool execution, not duplicate inference.

## LM Studio fail-forward lifecycle

```text
resolve executable
  -> smoke primary identity
  -> smoke fallback identity
  -> parse existing LM Studio configuration
  -> stage and validate both plugin directories
  -> commit fallback, then primary, then mcp.json atomically
  -> smoke both committed registrations
  -> ready | primary_only | fallback_promoted | unavailable
```

- `forge-conductor` and `forge-conductor-fallback` have distinct role environment values and `serverInfo.name` identities.
- Foreign MCP registrations are preserved.
- Malformed configuration aborts without replacing live plugins.
- A failed commit or post-commit validation rolls back the previous configuration and plugin directories.
- A healthy fallback with a failed primary is a degraded, serving state (`fallback_promoted`), not a total outage.
- LM Studio remains the process host. Forge prepares and verifies two hot connectors; LM Studio/operator policy determines which enabled connector receives a tool call.

## Trust boundaries

- Dashboard HTTP binds only to `localhost`, `127.0.0.1`, or `::1`.
- Browser mutations require same-origin JSON. Wildcard CORS is not emitted.
- Privileged tool invocation is not exposed over HTTP; it is available over the LM Studio MCP stdio boundary.
- Agent grant/deny lists and configured workspace roots are enforced before tool dispatch.
- Ordinary filesystem authorization canonicalizes paths and rejects traversal or
  symlink escape before dispatch. Privileged destructive mutation has additional
  protocol-v5 capture and quarantine controls, but its documented E2 races remain.
- HTTP bodies, MCP frames, file reads, subprocess capture, and returned shell output are bounded.
- Audit records redact commands and file contents.
- Session and handoff paths may narrow existing authority but cannot create new
  trusted authorization roots.

`shell_exec` is intentionally a powerful local-model capability. Schema-v2
configuration enables project shell tools by default and exposes an explicit
native opt-out. Every call still requires an authorized workspace and has a
120-second maximum. The legacy compatibility profile remains `/bin/bash -lc`.
It is not an operating-system sandbox and should be granted only to trusted local
agents. Pre-v2 configuration is backed up and migrated once with a verified receipt.

## Qualification boundary

This architecture describes implemented surfaces, not a release pass. P10 and
filesystem E2 remain open: bounded capture and quarantine mitigate substitution
races but do not eliminate them, and the signed distinct-process 57-case matrix
plus formal closure are still required. A bounded Apple Development-signed
Release installed-app run executed the established `shell_exec` contract through
both the app and raw CLI, across app relaunch and installed-manager PID
replacement. It also proved clean defaults, legacy migration, opt-out denial,
`tools/list`, raw-CLI `version`/`status`/`doctor`, and exact cleanup restoration
with the adjacent signed runtime launcher. It deliberately did not invoke System
Events, so native Settings control and post-Settings re-enable remain blocked for
Xcode XCUI. Developer ID Release and P10 exact-production qualification remain
open. An earlier exact-revision Apple Development-signed 100-cycle Rig/MCP
navigation test is supporting evidence; the final current-source rerun,
Developer ID Release signing, the full production native UI,
settings, and service-lifecycle matrix, archive, notarization, and staple/
Gatekeeper evidence remain release-blocking.

Autonomous continuity requires the manager-owned, threshold-forced real-provider
rollover with exact successor acknowledgment, predecessor fencing and idempotent
sealing, automatic continuation, GUI-closed operation, and every durable
crash-state recovery. The 660-second response fence and restart-durable receipts
mitigate one ambiguity; without a provider request-ID lookup, retries can still
repeat inference even though reconciled tool effects do not execute twice. Unit
and synthetic-host tests are insufficient. Current
G09-G12 and owner-deferred representative physical-hardware qualification also
remain open.

## Persistence

`~/.forge-conductor` (or `FORGE_CONDUCTOR_HOME`) contains:

- `store.sqlite` for sessions, bindings, handoff packets, durable memory, audit index, and presence
- `control-plane.sqlite3` for project identities, generations, bindings, runs,
  and dedicated bounded registration/relink transition authority; diagnostic
  audit pruning cannot change that authority
- `runtime-jobs.sqlite` for managed-job intent, process identity, termination phase, receipts, and artifact metadata
- `.runtime-support` for the private staged launcher and manager-owned runtime artifacts
- `audit.jsonl` for append-only tool audit
- `logs/*.jsonl` for categorized diagnostics
- `agents/*.md` for replaceable playbook modules
- `memory/handoffs/*` and `memory/current-task.md` as rebuildable continuity projections
- `config.json` for local configuration

## Build and run

```bash
./script/build_and_run.sh            # build, stage app bundle, launch
./script/build_and_run.sh --build-only # build and stage without launching
./script/build_and_run.sh --verify   # launch and verify the exact GUI process
swift test                           # full Core/CLI acceptance suite
```

The staged bundle contains `Contents/Helpers/forge-conductor`,
`Contents/Helpers/forge-runtime-launcher`, and
`Contents/MacOS/forge-filesystem-daemon`. Nested code is signed before the app
seal and each artifact is strictly verified.

Version: `0.9.0`
Build: `1`
