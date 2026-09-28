# Forge Conductor architecture

Version: `0.16.0`; build: `15`.

Forge Conductor is a native macOS control plane and MCP server for work carried
out in externally owned model conversations. The current LM Studio workflow
begins in the normal LM Studio chat interface. Forge supplies project-scoped
files, instructions, memory, Development Policy governance, tools, and
automatic continuity.

## Design rules

1. `ForgeConductorCore` owns reusable domain, persistence, application, MCP,
   provider, Manager, and telemetry services.
2. `ForgeConductorApp` owns native SwiftUI/AppKit presentation and bounded Metal
   gauges.
3. Dependencies point inward through Swift protocols; host and filesystem
   effects are injected ports.
4. Project authority is bound to stable project identity and generation.
5. Queues, caches, histories, logs, retries, output, and recurring work have
   explicit limits and shutdown owners.
6. Manager mutations use authenticated loopback routes; model tools use stdio
   MCP and cannot obtain Manager credentials.
7. Provider readiness, stored configuration, and live host behavior are
   separate evidence boundaries.

## Product composition

| Component | Responsibility |
|---|---|
| `ForgeConductorCore` | Domain models, SQLite and file persistence, project services, tools, provider preparation, continuity, CLU, Manager, telemetry |
| `ForgeConductorApp` | Native operator interface and lifecycle binding |
| `ForgeConductorCLI` | Install, doctor, status, Manager, and stdio MCP entry points |
| `ForgeNativeSessionHostPlugin` | Statically registered supported host boundary for automatic successor creation |
| Runtime launcher | Bounded signed native process execution for retained low-level services |
| Filesystem daemon | Versioned privileged filesystem boundary |

The canonical native graph is `ForgeConductor.xcworkspace` and its existing
Xcode project. SwiftPM compilation is useful evidence but is not a substitute
for the signed app build.

## Manager ownership

`ManagerNode` is the single owner of the authenticated loopback control surface
and its watchdogs. The GUI either attaches to the existing current Manager or
starts a local one. Provider configuration, project mutation, policy catalog
changes, exports, cache maintenance, and operator snapshots use bounded typed
Manager routes.

The Manager owns no foreground LM Studio UI automation. It interacts with LM
Studio only through supported CLI, REST, and MCP boundaries.

## Project and instruction ownership

Project registration canonicalizes a selected folder, establishes stable
identity, and advances a generation on reset. Multiple projects may be active,
but their memory, tools, policy logs, and continuity remain isolated.

`ProjectInstructionQueueStore` imports files, folders, archives, and supported
documents into immutable content-addressed snapshots. The durable order shown
in Projects is authoritative. Drag reordering is revision-checked so stale UI
snapshots cannot overwrite newer state. The model queries bounded catalog and
content pages after calling `get_forge_status`; package selection does not
start a model conversation.

## MCP and tool authorization

LM Studio starts Forge's versioned stdio MCP registration. `get_forge_status`
is available without a Managed Run and returns registered project identities,
query tools, and the selected project's file, instruction, and continuity
locations. `resume=true` requests the latest resume-ready handoff.

Filesystem, Git, shell, memory, instruction, policy, and continuity tools pass
through the same authorization layer. Project-bound calls require a valid
project identity and generation. Paths outside the authorized project roots and
Forge control-state namespaces are rejected before dispatch.

## Provider ownership

Provider selection, LM Studio **Connect and Check**, the Advanced connection
check, and probe converge on one Manager preparation path. That path validates
Manager authentication, the saved endpoint, optional credential, supported CLI
recovery, loaded inventory, exact model selection, and tool contract. It does
not start or resume model work.

Claude Code Desktop and Codex Desktop retain ownership of their conversations,
model selection, permission prompts, and reload requirements. Forge modifies
only supported Forge-owned plugin, hook, and MCP artifacts. Grok Build remains
non-selectable.

## Automatic continuity

The ordinary LM Studio model writes compact checkpoints and a resume-ready
handoff at context pressure. The authoritative handoff commit precedes any host
effect. Manager then exposes a 30-second Dashboard countdown.

At expiry, the statically registered LM Studio host adapter:

1. resolves or creates one successor identity from a stable idempotency key;
2. activates LM Studio and presses its public Accessibility **New** control;
3. fills the visible Chat input with `get_forge_status`, `resume=true`, the
   exact handoff ID, and a deterministic nonce, then presses Send;
4. observes the installed GUI MCP tool's exact nonce-bound receipt;
5. validates the exact handoff identifier in that receipt;
6. durably records acknowledgement and predecessor sealing; and
7. reuses the same identity after retry or Manager restart.

The adapter ledger and GUI intent/submitted records are bounded and owner-only.
A host failure retains the same handoff and publishes a bounded redacted
diagnostic. The adapter uses no REST integrations array and does not store a
same-host LM Studio credential.

The Continuity UI does not drive this state machine. It is limited to a
scrollable project-ID list, Copy, and confirmed project-scoped Delete.

## Rune Forge and CLU

Rune Forge admits user-selected policy files and folders immediately, then
catalogs them through bounded durable work. The user-selected order is persisted
and defines priority.

CLU observes model and tool activity without entering the canonical
authorization/result path. It evaluates ordered policy, appends immutable
project-scoped violation history, reserves retry-stable notices, and adds a
notice to the active model response containing the exact policy identity and
bounded applicable policy content. Export takes a stable upper event sequence
and atomically writes JSONL, JSON, Markdown, or CSV.

Policy failure is visible and fail-forward: it cannot silently authorize a
tool, mutate a canonical result, or take over task execution.

## Telemetry and gauges

Telemetry producers use one bounded delivery boundary: at most one in-flight
main-actor delivery and one replaceable latest snapshot. Sequence numbers and
coalescing counters expose stale or dropped delivery.

Hidden or detached gauges perform no recurring render work. Visible gauges use
a bounded cadence and shared immutable Metal resources. Mutable buffers are
reused and shutdown cancels all recurring work.

## Persistence and recovery

SQLite is authoritative for project memory, control-plane state, policy logs,
and continuity. Owner-only JSON and Markdown files are either configuration,
bounded ledgers, or rebuildable projections. Mutations use transactions or
atomic file replacement. Recovery resumes durable transition state rather than
inventing completion.

The disposable cache is a separate real directory beneath the application
home. Clearing it validates that boundary and recreates only the required cache
subdirectories; it does not delete projects, instructions, policy, memory,
credentials, continuity, or diagnostics.

## Compatibility boundary

Low-level managed-runtime and run-record types remain for stored-data
compatibility, native validation, and reusable bounded execution services.
They are not the current user launch workflow, are absent from primary
navigation, and cannot serve as acceptance evidence for the roadmap.

## Trust boundaries

- Loopback HTTP binds only to local addresses and requires the owner credential
  for mutation.
- Stdio MCP tools never receive that credential.
- Credentials remain in Keychain or owner-only stores and are redacted from
  snapshots, logs, and exports.
- Provider and desktop-host installation changes are revision-fenced and
  limited to Forge-owned artifacts.
- Privileged filesystem operations use the versioned signed helper contract.
- No private desktop UI automation is used.

## Qualification boundary

Compilation, deterministic tests, current-candidate native UI behavior, live LM
Studio behavior, signing, notarization, Gatekeeper, privileged-service health,
hardware coverage, and owner acceptance are distinct gates. The current release
state and exact owner-defined workflow are recorded only in
[ROADMAP.md](../ROADMAP.md).
