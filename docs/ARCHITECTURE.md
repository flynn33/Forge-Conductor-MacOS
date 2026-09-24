# Forge Conductor architecture

Forge Conductor is a native macOS orchestration server for managed local models
hosted by LM Studio and for Forge-integrated desktop coding hosts. The same
codebase supplies a SwiftUI/Metal operator app, a CLI, a persistent local
manager, desktop hook/plugin packages, and MCP stdio connector processes.

## Design rules

1. `ForgeConductorCore` contains reusable domain and service modules; executable targets are composition and presentation shells.
2. Dependencies point inward through Swift protocols. Provider installation,
   host CLI execution, hook forwarding, and MCP verification are injected ports,
   not hard-coded global calls.
3. The Apple-native stack is Foundation, SwiftUI, AppKit, Combine, Metal, Network, IOKit, Mach, SQLite3, and FileManager. The runtime does not require Node or Python.
4. Framework features are exposed through modular `ToolPackHandling` implementations and stable MCP tool names.
5. Primary and fallback LM Studio connectors are independent processes with
   typed identities and aggregate health; desktop hosts retain ownership of
   their model and session.
6. Persistent sessions, provider selection, active bindings, memory notes, and
   context handoffs survive process restarts.

The implemented Rune Forge Development Policy feature adds a manager-owned,
non-interfering observer and policy-log boundary without entering tool
authorization, run admission, queue state, project generations, or completion.
Its implemented persistence foundation uses schema-versioned SQLite as query
authority, immutable digest-chained violation events, a repairable JSONL mirror,
and bounded owner-only fallback storage. A non-throwing service boundary keeps
all policy-log faults additive to ordinary Forge execution.
The same manager-owned database now catalogs every selected source immediately,
then processes regular files and directory trees through bounded durable work
rows. Native extractors retain source revisions, artifacts, segments, cursors,
and repository identity; links and special entries are described without being
followed or opened, and incomplete interpretation remains an active source.
The built-in Raven Forge Development adapter projects immutable native rules
with exact pinned revision, path, and heading provenance into the same
schema-versioned policy database. Optional parity-utility results are recorded
as observations and cannot activate, suspend, or otherwise control policy.
Immutable bounded development observations enter a dedicated table or
owner-only outbox. One manager evaluator selected by an expiring process/boot
lease advances a committed cursor only after idempotent lifecycle writes;
detector faults become append-only evidence and cannot stop peer detectors or
the observed development operation.
Coding-agent reporting uses a separate bounded notice store and delivery ledger.
Managed runs receive a retry-stable context snapshot before a safe provider
input, while ordinary MCP responses append a second text content item after the
canonical content. Transport failures retain eligibility for later delivery;
neither path changes tool payloads, error status, authorization, or run outcomes.
A dedicated manager coordinator now composes these stores, owns the only
continuous index/evaluation task, and follows manager start, stop, and restart.
Its typed HTTP boundary separates read-only bounded snapshots, violation pages,
and notice reservations from credential-protected source, observation, scan,
presentation, and export requests. Process clients retain observations in a
bounded owner-only FIFO outbox across manager outages. Initialization or loop
faults publish degraded health and bounded retry state without failing ordinary
manager bootstrap. The export boundary takes a stable upper event sequence,
streams bounded filtered history through manager-owned staging, synchronizes
the file, and atomically replaces the user-selected destination. Durable
request receipts preserve retry identity across Manager restarts; export faults
do not mutate the authoritative policy log.
Product operations submit only redacted status, identity, and digest evidence
after their canonical durable boundary. One process-owned emitter admits those
observations synchronously into a 256-item queue, reports drops explicitly,
drains through one asynchronous worker, and becomes idle when empty. A separate
owner-only client outbox survives Manager outage and resolves the current
loopback endpoint on each retry. Ordinary and managed tool arguments and result
bodies never enter policy storage, and observation delivery cannot authorize a
tool, admit or complete a run, or alter a canonical result. Shutdown stops
admission and uses a bounded deadline; an unresponsive transport is reported
without holding application shutdown indefinitely.
The SwiftUI app exposes that boundary through a dedicated Rune Forge tab. Its
main-actor view model owns one cancellable five-second polling loop, caps the
visible source and violation collections at 100 entries each, preserves
optimistically accepted sources and the last confirmed snapshot through
Manager outages, and cancels work at the view lifetime boundary. The native
open panel accepts one file or folder without a content-type allowlist. A
`NavigationSplitView` keeps source and violation selection separate from detail
presentation, while occurrence and delivery details remain bounded by the
Manager snapshot. Guided Mode content is bundled and requires no provider or
Manager connection. An `NSSavePanel`-backed format menu exports JSONL, JSON,
Markdown, or CSV without database or file work on the main actor. The Manager
response reports the event count, byte count, digest, destination, and retry
identity.

The Dashboard's view-owned five-second operational monitor also composes a bounded,
coalesced, app-local Managed Activity projection. The public Manager operator
DTO retains bounded, redacted mission and work-item text plus non-sensitive
state, identity, and event metadata. Authenticated
`GET /api/manager/operator/activity` requires the exact run, project, and
generation before returning current phase/next action,
assistant/model-error/tool summaries, or managed activity rows. Provider
responses and tool transitions append idempotent
2 KiB content-hashed projections, retained per run as at most 128 assistant and
128 tool rows; the append-only non-activity audit lineage excludes those rolling
projection rows so retention cannot create audit-chain gaps. Event sequence
preserves same-second order. Both native clients stream Manager responses
through a strict 4 MiB ceiling. The app merges those events with an exact
project/generation Stjornarvald snapshot into at most 100 rolling rows,
applies an 8 KiB presentation cap, and stops updating when the view-owned
monitor stops. This is not token streaming and does not add a second full
provider transcript. Rune Forge separately renders the global newest bounded
policy snapshot as a verbose Policy Feed without changing evaluation or
execution.

The Dashboard uses intrinsic `Grid` rows for CPU/GPU, Storage/Managed Activity,
MCP servers/tools, and agents/processes. The compact activity region scrolls
internally, while `ViewThatFits` supplies a vertical fallback at constrained
widths. Settings, Autonomy, Continuity, and Rune Forge controls use adaptive
grids or bounded scrollable sheets rather than fixed overflowing action rows.

Dashboard and Guided Setup derive provider readiness from the durable selected
provider. A Claude or Codex selection can project **HOST READY** independently
of LM Studio health only when the descriptor is selectable, a verified receipt
exists, no mutation is in flight, and ready preparation matches both provider
identity and selection revision. Missing, stale, or non-selectable evidence is
never promoted to ready.

Its pinned authority, current-source ownership map, preserved surfaces, and
delivery state are recorded in [Rune Forge and Stjornarvald](STJORNARVALD.md).
Its 40-row implementation result and explicit physical accessibility limit are
recorded in [the acceptance record](RUNE-FORGE-STJORNARVALD-ACCEPTANCE.md).

## Package products

| Product / target | Responsibility |
|---|---|
| `ForgeFilesystemProtocol` | Shared protocol-v5 request, identity, recovery, and receipt contracts for the privileged filesystem boundary |
| `ForgeConductorCore` | Domain, application services, infrastructure, MCP, manager, dashboard, telemetry |
| `ForgeNativeSessionHostPlugin` | Native provider adapter and session-host integration used by continuity workflows |
| `forge-conductor` / `ForgeConductorCLI` | CLI, installer, manager commands, and MCP stdio executable |
| `forge-conductor-app` / `ForgeConductorApp` | SwiftUI/AppKit/Metal operator application |
| `forge-runtime-launcher` / `ForgeRuntimeLauncher` | Signed, resource-bounded native process launcher for managed jobs |
| `forge-filesystem-daemon` / `ForgeFilesystemDaemon` | Privileged regular-file, symbolic-link, empty-directory and no-replacement move capture, protected quarantine, and request recovery; bounded recursive deletion composes those transactions, while root-service E2 qualification remains open |
| `ForgeConductorTests` | Unit, integration, security, connector, and process acceptance tests |

The Xcode project mirrors these boundaries. SwiftPM provides a second
reproducible Apple-native build path. `script/build_and_run.sh` stages the GUI,
embedded manager CLI, runtime launcher, filesystem daemon, and daemon property
list, then signs nested code before strictly verifying the enclosing bundle.
The script does not synthesize Xcode's embedded framework layout.

Signed Xcode products bind each role to an exact Apple signing requirement.
The active development and Developer ID distribution team is James Daley's
`9AQ2C2838M`; the earlier `2Y25RTLZET` distribution team remains admitted
only for previously signed Developer ID products. Active Debug and explicit
development-signed Release builds require Apple Development, while ordinary
Release requires Developer ID Application. Product-role admission accepts only
the active build's certificate class for the exact owner team and only
Developer ID for the earlier team. Manager staging, runtime launch,
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
  -> ProviderIntegrationCoordinator + provider adapters + desktop hook policy
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

The native **Provider** screen saves revisioned endpoint/model settings through
authenticated manager routes and keeps, replaces, or clears credentials in
Keychain. Saving works while LM Studio is offline; model discovery and probes
use the saved revision. Unsaved edits, active runs, and overlapping operations
cannot silently replace that configuration. The router forwards these controls
to the current manager after replacement. See the
[provider workflow](../USER-GUIDE.md#configure-the-managed-provider).

## Provider integration ownership

`ProviderIntegrationCoordinator` is the single actor owner of the durable,
mutually exclusive provider selection, deployment receipts, current operation,
and bounded recent-operation ledger. Every activation, deactivation, repair,
or removal request is revision-fenced and idempotency-keyed. Selection changes
only after the requested adapter reaches a usable state; failure or cancellation
retains the prior selection. Startup converts an interrupted operation to an
honest recovered terminal state rather than replaying an unknown host mutation.
Manager admission serializes provider mutations against run creation. A
desktop provider with a nonterminal run cannot be selected, deselected,
repaired, or removed.

LM Studio's adapter composes the existing transactional primary, fallback, and
continuity-role deployment with `managed_provider_push`. Claude and Codex
adapters use `DesktopProviderPluginInstaller` to stage deterministic
Forge-owned plugin, hook, skill, and MCP files, merge compatible host settings,
invoke a supported host CLI when available, verify the committed result, and
roll back a failed commit. Foreign paths, symbolic links, malformed settings,
and unproved ownership are refused. Removal is available only while a provider
is inactive and is limited to artifacts Forge can prove it owns.
Host unregister is a separate verified boundary: an unavailable or inconclusive
supported CLI/live inventory leaves local artifacts and the receipt intact in
**Awaiting User Action**. Source-file deletion alone is never recorded as host
removal; a retry after manual unregister settles idempotently.

The Grok descriptor and ownership adapter remain for recognition and cleanup,
but `grok-build` is non-selectable and cannot admit a run. Grok's documented
passive startup output does not affect model context and prompt-submit stdout is
discarded, so a staged or enabled package is not assignment-ingress evidence.

Generated desktop hooks and MCP registrations use the same explicit canonical
Forge home. Hooks invoke `provider-hook ... --home <forge-home>` and MCP invokes
`serve --home <forge-home> --desktop-provider <provider-id>`; neither depends on
a GUI application's inherited shell environment to locate Forge state. The
command-line provider role is immutable and starts without project authority.
The current hook assignment carries a five-minute, single-use capability whose
digest is stored on the autonomous-run binding. `desktop_run_attach` atomically
consumes it and copies that run's frozen authorization scope to the exact MCP
client. Provider, session, run, project generation, selection revision, and
deployment must all still match. Every other project tool is rejected before
attachment, and replacement assignment, session end, terminal state, restart
recovery, or deletion revokes the binding. Supported host CLI JSON inventories
must report the exact Forge plugin enabled before activation is considered
verified. Host reload and permission/trust acceptance remain separate user
actions when the host requires them.

Selectable desktop runs bind `desktop_plugin_pull`, `host-selected`, the provider-selection
revision, and verified deployment identity. They do not activate the managed
provider coordinator; checkpoint and continuity context crosses the
authenticated desktop-hook boundary while the host retains its conversation.
`DesktopProviderHookBridge` accepts bounded event envelopes and sends them only
to the authenticated loopback Manager route. Its policy never auto-allows a
permission request and can deny only a recognized Forge MCP call when that host
is inactive or local policy is unavailable. See
[Provider integrations](PROVIDER-INTEGRATIONS.md).

## Project instruction queue ownership

`ProjectInstructionQueueStore` owns bounded instruction ingestion and queue
metadata. A selected file or directory is validated without following symbolic
links, hashed, and copied to an owner-only content-addressed snapshot before an
atomic queue-file commit makes it visible. Every record carries the project UUID
and generation; the autonomous run receives the registered repository root as
its tool scope rather than authority over the instruction source location.

The queue projection augments each linked run with bounded, journal-derived
instruction-delivery counts. Dashboard treats fully delivered instruction documents
as steps and completed queue records as packages. Completion presets use stable
identifiers that the manager compiles into typed native obligations; the bound
instruction package exclusively supplies any additional requirements. Each prepared descriptor also
binds a validated failure policy and optional bounded model-facing instructions.

`ManagerNode` is the single scheduler. Its existing bounded autonomy watchdog
reconciles durable package/run links, observes terminal run state, and starts at
most the next queued package for a project. The run identifier is persisted in
the package queue before creation, so a restart can replay the exact idempotent
run request. Completed runs advance the queue. Failure, cancellation, pause, or
terminal failure stops it. Provider readiness uses the bounded provider-wait
path and resumes after Connect and Check succeeds; persisted legacy
`blocked_configuration` state is recovered automatically rather than becoming
a Forge configuration requirement. The compiled
`forge.package.tool-success` validator accepts only bounded durable tool results
for the exact run/project generation.

Project generation reset cancels unfinished records from the old generation.
Project removal archives the control-plane identity, advances its generation,
invalidates bindings, and removes its active queue metadata while leaving
project memory and historical run evidence intact. See the
[instruction package guide](INSTRUCTION-PACKAGES.md).

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
- Desktop provider hooks use the owner-only Manager bearer, reject redirects
  and non-loopback destinations, and validate bounded request/response JSON.
  They never auto-approve host permissions.
- Agent grant/deny lists and configured workspace roots are enforced before tool dispatch.
- Ordinary filesystem authorization canonicalizes paths and rejects traversal or
  symlink escape before dispatch. Privileged destructive mutation has additional
  protocol-v5 capture and quarantine controls. Move publishes from the protected
  capture with no replacement inside one authorized writable root and volume;
  recursive delete commits bounded bottom-up leaf/empty-directory transactions.
  The documented signed distinct-process E2 matrix remains unmeasured.
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
with the adjacent signed runtime launcher. That installed-app qualifier remains
partial because its own System Events Settings step was not run. A separate
native Xcode run passed four production onboarding scenarios: folder
selection/cancellation/invalid-root handling, offline provider save and manager
replacement, Settings shell off/on with fresh MCP processes, and real-provider
model discovery/connection. Those passes retain their recorded source and
Apple Development scope; they do not complete the installed/native matrix.

The earlier exact-revision 100-cycle Rig/MCP navigation result remains historical
supporting evidence. A later native Release gauge run passed four tests,
including 100 lifecycle cycles and draw/buffer/weak-owner assertions, while
closed fixture windows accumulated to 101. This does not establish whole-app
window or leak closure. The current functional-development candidate passes a
canonical workspace Release build, coherent Apple Development signatures,
isolated CLI checks and a bounded direct GUI launch. Developer ID Release signing,
the public-distribution native matrix, P10, archive, notarization, staple/
Gatekeeper evidence and the broader hardware matrix remain owner-deferred or
outside this delivery scope. The retained local and CI results are distinguished
in [qualification status](QUALIFICATION-STATUS.md).

One manager-owned threshold-forced real-provider rollover completed exact successor
acknowledgment, predecessor fencing and idempotent sealing, automatic continuation,
GUI-closed injected-crash recovery and stable replay. Deterministic tests cover two
sequential rollovers and the wider crash matrix. A second live attempt exceeded the
600-second provider deadline and later returned a conflict, so it is not counted as
a repeat pass. The 660-second response fence and restart-durable receipts
mitigate one ambiguity; without a provider request-ID lookup, retries can still
repeat inference even though reconciled tool effects do not execute twice. Unit
and synthetic-host results remain accurately distinguished from the live result.

The 0.14.0 desktop-provider package, coordinator, route, hook, recovery, and
ownership contracts require deterministic focused evidence and a canonical
Xcode build. Those checks do not prove that Claude or Codex is open, has
reloaded an integration, has accepted hook trust, or has completed a live
session. Live acceptance is recorded separately per selectable host; one host
cannot qualify the other. Grok requires a future supported assignment-ingress
contract and fresh evidence before it can become selectable.

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
- `managed-providers/provider-integrations.json` for the bounded durable
  selection, operation ledger, and redacted deployment receipts
- `managed-providers/desktop-provider-plugins/` for Forge-owned staged desktop
  packages and transaction backups
- `instruction-packages/Store/<sha256>/` for immutable accepted instruction content
- `instruction-packages/queue.json` for the owner-only project package order and durable run links

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

Version: `0.14.2`
Build: `7`
