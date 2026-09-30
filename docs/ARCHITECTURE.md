# Forge Conductor architecture

Version: `0.16.3`; build: `24`.

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
identity and a default working directory, and advances a generation on reset.
Multiple projects may be active, but their memory, instruction artifacts,
policy logs, continuity, and durable activity remain isolated by identity and
generation. Registration does not create a filesystem access boundary.

`ProjectInstructionQueueStore` imports files, folders, archives, and supported
documents into immutable content-addressed snapshots. The durable order shown
in Projects is authoritative. Drag reordering is revision-checked so stale UI
snapshots cannot overwrite newer state. The model queries bounded catalog and
content pages after calling `get_forge_status`; package selection does not
start a model conversation, and artifact reads require the attached project and
generation rather than a Managed Run.

## MCP and tool authorization

LM Studio starts Forge's versioned stdio MCP registration. `get_forge_status`
is available without a Managed Run and returns registered project identities,
query tools, the selected project's file, instruction, and continuity
locations, and the ordered active Development Policy source paths. Its required
bootstrap action directs the model to read those sources in priority order and
follow their applicable requirements before development changes. `resume=true`
requests the latest resume-ready handoff.

Filesystem, Git, shell, memory, instruction, policy, and continuity tools pass
through the same authorization layer. Project-bound calls require a valid
project identity and generation, and tool grants and the shell enable switch
still gate dispatch. For native filesystem, Git, shell, PDF, search, and
runtime calls, an absolute path may be outside the selected project folder.
Forge canonicalizes the path but does not wrap the command in a Seatbelt
profile. macOS attributes TCC access to the responsible signed host and
executable in the actual launch chain; Forge does not infer Full Disk Access
from a parent UI grant. The exact signed candidate must pass a live protected-
path read after relaunch, without exposing file contents. Ordinary POSIX and SIP
constraints remain in force.
Selected project roots supply registration identity and the default base for
relative paths, not access confinement.

Runtime jobs retain the signed launch gate, process-group ownership, deadlines,
output and environment bounds, cancellation, and durable result fencing. A
bounded libproc tracker records start identities and cleans up observed children
that leave the process group with `setsid(2)` or `setpgid(2)`. The normal
per-job descendant budget is 16, with an absolute 1,024 retained-identity cap.
Crossing either boundary produces a typed terminal failure; sticky capacity
evidence does not prevent terminalization after every retained identity exits.
If termination cannot be confirmed, the job releases live ownership as a
bounded cleanup debt with a retry deadline and one identity-fenced startup
retry. A reused PID is never signaled. Public macOS process snapshots are not
atomic and the out-of-group tracker is not durable across a Manager crash;
unrestricted same-user code that escapes entirely between observations remains
an explicit native-shell trust boundary.
Filesystem delete and move retain explicit protection against `/`, user and
Manager homes, mounted-volume roots, active workspace roots, and any ancestor
whose removal would contain one of those roots. Authorization performs the
first check; local execution independently reconstructs that set, pins the
source by descriptor identity, and compares it against every protected root and
ancestor again immediately before delete or move. Changed parents, case aliases,
blank operands, and an uninspectable protected identity fail closed. In-project
delete and move may use the signed generation-fenced filesystem helper; paths
outside a declared project root use the bounded local implementation. Memory,
instruction, policy, and continuity APIs remain project/generation scoped, but
an owner-authorized unrestricted shell is not a physical secrecy boundary for
same-user files backing those services.

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

Dashboard resolves its tracked project from current live MCP presence and the
matching active durable `mcp_client` binding. Recent activity orders multiple
live clients; heartbeat order is the deterministic fallback. An exact
nonterminal run is used only when no live binding resolves, and registration
alone is never presented as an active project.

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
- Native model tools deliberately inherit host access; project selection is not
  represented as a security sandbox.
- No private desktop UI automation is used.

## Qualification boundary

Compilation, deterministic tests, current-candidate native UI behavior, live LM
Studio behavior, signing, notarization, Gatekeeper, privileged-service health,
hardware coverage, and owner acceptance are distinct gates. The current release
state and exact owner-defined workflow are recorded only in
[ROADMAP.md](../ROADMAP.md).
