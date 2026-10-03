# Forge Conductor ↔ LM Studio (evidence-based)

This document is derived from **this Xcode project’s source** and **on-disk / runtime checks**, not from the retired Python stack.

Current source identity: version **0.16.5**, build **26**. This connection document does
not authorize release; the qualification boundary below remains controlling.

## Build-24 CLI staging/deploy reconnect receipt — October 1, 2026

A fresh universal Developer ID archive was built while Git HEAD was
`b8a2c5dee546dff8d914405c2169a075bd0187e2`, retaining product code
`a54100b453ba8b1c1489ff09ac64dd6193fc1597` and identity `0.16.3 (24)`.
The archive's own `Contents/Helpers/forge-conductor install` copied its helper
and app into `~/.forge-conductor`, not `/Applications`. The staged helper's
`install-lmstudio-plugin` command then wrote primary,
fallback, and CLU entries in `~/.lmstudio/mcp.json` under deployment
`7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`. Each entry launches
`/Users/flynn/.forge-conductor/bin/forge-conductor serve`; no entry has a
`cwd`. The staged helper, archive-embedded helper, and manually copied
`/Applications` candidate helper all match SHA-256
`49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
The old v0.16.2 GUI and desktop-provider process were stopped, and the signed
candidate was manually copied over `/Applications/Forge Conductor.app` for
cold-start observation, not installed by the signed `.pkg`. Cold-starting that
copy and LM Studio left the registration file
unchanged at SHA-256
`7663a4f6ae3bee266eb7cefe7edc18056ff1f34c72d72ae8265dbb4e1398b7a3`.

The ordinary LM Studio Jamf-Technician chat launched fallback PID `38508`;
its `get_forge_status(project_id)` reported v0.16.3 and attached project
generation 7. After that helper exited, fallback PID `38964` reported the
same deployment-scoped client
`lm-studio:faf23139c06a39f92a71bf3bcdb267154717cd7e623e4d326188093f6f96d54a`
with `project_context.attached: true`. The next four project calls—`fs_list`,
`git_status`, `instruction_catalog`, and `continuity.status`—all returned
`ok: true` without a manual rebind. The chat transcript is
`~/.lmstudio/conversations/Jamf-Technician/1790852478591.conversation.json`.
The signed `.pkg` build succeeded but macOS declined package installation
without root. GUI Deploy was not exercised; its source passes the running app
executable, distinct from the staged helper chosen by the CLI run. This
receipt qualifies only CLI staging/deploy and hosted tools, not package
installation, GUI Deploy, or public release.

## Build-23 live bootstrap receipt

The retained Developer ID candidate is `/Users/flynn/Desktop/Forge Conductor
0.16.2 (23)-22e7443-DeveloperID/Export/Forge Conductor.app`; its embedded MCP
helper is `Contents/Helpers/forge-conductor`. LM Studio registration revision
`32b3c0a3-c621-4e1e-bfe2-75838c5ea86d` binds primary, fallback, and CLU to that
exact helper. After LM Studio restart, the open Jamf-Technician chat called
`get_forge_status` through final repeated fallback PID `12436`, which reported version
`0.16.2`. The raw result includes the Development Policy location, ordered
sources and mandatory read/follow action, policy read tools, durable ordered
instruction packages, project and store locations, continuity, and resume
state. Primary PID `12434` and CLU PID `12435` are the restored standby roles
from the same candidate. `/Applications/Forge Conductor.app` was not replaced.

## Build-24 deterministic reconnect receipt

Source `a54100b453ba8b1c1489ff09ac64dd6193fc1597` contains the executable replay
for the reported stable client `A800AC6E-8B31-4E64-A0CE-9B9DA192CADA`.
`fs_list`, `instruction_catalog`, `shell_exec`, and `continuity.status` first
assert `project_context_required`; `get_forge_status(project_id)` then asserts
`project_context.attached == true`; the same four calls immediately assert
success on the same client.

A separate restart replay constructs a primary and fallback `MCPServer` with
different random process identities and the same non-empty deployment ID. The
derived client IDs are identical, only the first server calls status, and all
four gated tools succeed through the second server without another bind call.
Empty deployment IDs retain a fresh random client that status can attach.
Two-project selection remains explicit and generation-reset invalidation stays
fenced while status remains readable.

## Build-24 live deployed-helper reconnect receipt

On October 1, 2026, the reloaded `~/.lmstudio/mcp.json` primary, fallback, and
CLU registrations all named `/Users/flynn/.forge-conductor/bin/forge-conductor`
with argument `serve`, no `cwd`, and deployment revision
`6b6aa0b4-c3bd-454b-96e4-1273abf390f1`. That helper reported `0.16.3`; SHA-256
`41a0a94fe247a2ea4718f43b1dd32a19bc7414e4d202f37d8c32e09312046387`
exactly matched the helper embedded in the source-`a54100b` build-24 candidate.

Forge and LM Studio were both terminated and relaunched before a new ordinary
LM Studio chat made any tool call. The fresh chat used the fallback
registration and hosted PID `33715`. Its first
`get_forge_status(project_id)` reported v0.16.3 and attached project
`d2610542-b616-7e8f-ee36-ef902d6060e1` generation 7 to deployment-scoped
client `lm-studio:12ec4eaf781d85b33f4dde7e180dbbd44367c93155660ec486c1b4cb2d21a6fc`.
Without a second bind or initialization call, `fs_list`, `git_status`,
`instruction_catalog`, and `continuity.status` all returned successful JSON.
The registration record, status `canonical_root`, and
`git rev-parse --show-toplevel` agree on
`/Users/flynn/GitHub/Jamf-Technician`; the Documents-path variant is absent.
At that earlier hand-deployment checkpoint, `/Applications/Forge
Conductor.app` was not replaced and remained the separate v0.16.2 GUI
installation. The matching wiki receipt for that checkpoint is revision
`e615c2405a094b43f9ebb4794ba0676c86ae38bd`.

The published `get_forge_status` tool description is:

> Runtime, project, ordered instruction-package execution, and required
> Development Policy bootstrap status. Attaches a new MCP deployment to
> project_id, or to the sole active project when selection is unambiguous. Read
> and follow every ordered active
> Development Policy source before development work, then read instruction
> packages in the returned execution order. Set resume=true in a successor
> chat to load the latest resume-ready handoff.

## What the product is

| Component | Role |
|-----------|------|
| **LM Studio** | MCP **host** (spawns stdio servers, routes tool calls from local models) |
| **Forge Conductor Swift app (GUI)** | Dashboard / manager / installer UI. With no argv → SwiftUI. |
| **App binary `…/Forge Conductor serve`** | Same MCP server over stdin/stdout (`ForgeProcessEntry` → `MCPServer.swift`) |
| **CLI `forge-conductor serve`** | Same MCP server (default registration target) |

There is **no** in-process link from the GUI into LM Studio’s address space.
The statically registered native session-host plugin uses LM Studio's public
macOS Accessibility surface for automatic foreground successor chats. Ordinary
work remains in the user's LM Studio interface; the stdio registration below
serves both user-created and successor chats.

## Forge Link implementation boundary

The first network-link foundation is present in source. It defines a versioned
`local` or `linked` provider endpoint mode, strict discovery/pairing/health/
capability/control/role data contracts, and an owner-only paired-node registry
with bounded files, cross-process locking, atomic replacement, and revision
compare-and-swap. Existing provider configuration that predates the field
decodes as `local`; a linked endpoint is required to use HTTPS.

This is a contract and persistence milestone, not an operational network path.
The product does not yet advertise or browse Linux nodes, perform pairing,
issue credentials, run a Forge Link listener, install the GB10 companion, or
offer linked-node selection in Provider. The local workflows documented below
remain the only qualified behavior until those later milestones close.

### Process entry (one binary, four modes)

| Argv | Mode |
|------|------|
| _(none)_ | GUI |
| `serve` / `mcp` / `mcp-serve` | Stdio MCP (`ForgeProcessEntry` → `MCPServer`) |
| `manager run [--home …] [--open]` | Dashboard manager (LaunchAgent path) |
| `provider-hook <provider> <event> --home …` | Internal bounded desktop-host hook bridge; not an interactive operator command |

## LM Studio chat and connection setup

Turn on **LM Studio** in Provider before starting LM Studio work. The
mutually exclusive activation toggle runs the manager-owned **Connect and
Check** workflow, verifies the transactional MCP deployment and exact saved
model contract, and commits the durable `lmstudio` selection only after that
readiness succeeds. Selecting a desktop host instead does not reuse this HTTP
model path; see
[Provider integrations](PROVIDER-INTEGRATIONS.md).

Forge keeps the active selection until another provider is ready, so clicking
the active selector cannot leave the MCP workflow providerless. If a replaceable
background snapshot is still loading when LM Studio is selected, the explicit
activation supersedes that load instead of silently ignoring the click.

The native Provider screen saves the LM Studio server origin and an exact model
key. A same-host local endpoint has no LM Studio token field and rejects token
replacement through the Manager API; any legacy local Forge credential
reference is removed from configuration and Keychain. Linked HTTPS endpoints
retain their separate optional credential path. Saving is durable and does not
prove the server is reachable. With a saved loopback endpoint, **Connect and
Check** is the ordinary one-button path. Forge
first attempts normal inventory. After a transport-level offline result, it
locates LM Studio's supported `lms` CLI in the system or per-user application,
the standard LM Studio user location, Homebrew locations, or `PATH`; reads `lms
server status --json --quiet`; starts the server with `lms server start` when
needed; and performs bounded readiness polling. Status parsing accepts the
bounded JSON object even when the CLI surrounds it with diagnostic text and
accepts a valid integer or string port. Forge retries only the configured
endpoint and loopback variants on the exact CLI-reported or start-reported port.
Each candidate must pass the ordinary model-inventory transport before Forge
may persist the corrected endpoint. Forge does not scan ports.

The same action then chooses the sole compatible loaded model when no model is
pinned, runs the complete model/tool contract check, and durably records
readiness. Forge never loads a model; when zero or multiple compatible models
are loaded, Provider gives the required load or selection action. A missing or
failing `lms` CLI, non-loopback endpoint, authentication failure, timeout, or
invalid inventory remains a typed failure instead of triggering broad host
discovery. **Refresh Models**, the Advanced connection check, and the probe
remain available for diagnosis; the connection check and probe use the same
actionable preparation path as the primary button.

If LM Studio has already synchronized the exact versioned MCP configuration,
deployment preserves the running host and its loaded model while MCP child
processes remain available for lazy chat activation. A relaunch is reserved for
a genuinely stale unsynchronized state. Closing the Provider view does not
cancel Manager-owned preparation; reopening the view reconciles the durable
operation state.

Every current Provider entry point sends a no-run-resumption preparation
request. Provider verification therefore cannot start, resume, or otherwise
take ownership of the user's LM Studio conversation.

Forge's native adapter reads LM Studio's `GET /api/v1/models` inventory as
authoritative model metadata. When that native response omits
`loaded_instances`, Forge may reconcile loaded state only from a bounded
`GET /api/v0/models` response whose exact model identifier reports
`state: loaded` and a valid context length. Missing, malformed, mismatched, or
unloaded compatibility data remains unavailable. LM Studio's OpenAI-compatible
`/v1/models` lists downloaded models when just-in-time loading is enabled, so
that list alone does not prove readiness.

On September 17, 2026, this host's `lms ps` and native v0 inventory reported
`qwen/qwen3.8-27b` loaded with a 262144-token context while the native v1
response returned the same model metadata with an empty `loaded_instances`
array. The Xcode **My Mac** Debug candidate reconciled that exact observation,
reported the model loaded, and passed the manager connection probe. That is
historical connection evidence bound to that source and host.

Register one or more repositories in **Projects** with the native picker or
**Enter Project Path…**. Add and order instruction packages there, add and order
Development Policy sources in **Rune Forge**, then open a normal LM Studio chat
and call `get_forge_status`. The response lists registered project identities
and reports attachment in `project_context`. A sole active project is attached
automatically; when multiple projects are active, pass the applicable
`project_id` to attach it and return its file, instruction, and continuity
locations. No Managed Run is required. LM Studio's primary, fallback, and CLU
helpers derive one client identity from the installed deployment ID, so process
restart or role failover does not discard the durable binding.

### Native host access and project context

The selected project supplies durable identity, generation, and the default
working directory. It is not a filesystem sandbox. After a client has a valid
project binding, owner-authorized filesystem, search, PDF, Git, shell, and
runtime tools may use native absolute paths outside the selected project. Forge
does not insert `/usr/bin/sandbox-exec`. macOS attributes TCC access to the
responsible signed host and executable in the actual LM Studio → Forge → child
launch chain; Forge does not infer Full Disk Access from a parent UI grant.
After a grant or candidate change, quit and relaunch the affected hosts and run
a live protected-path read through the exact signed candidate without emitting
file contents. POSIX permissions and SIP continue to apply.

Forge still requires the client binding for attribution and generation
fencing. Status bootstrap creates that binding only for a new deployment and
does not reactivate a row deliberately fenced by project reset. Forge applies
tool grants and the shell enable switch, canonicalizes paths,
bounds time and output, and rejects destructive operations against `/`, the
user or Manager home, a mounted-volume root, an active workspace root, or an
ancestor whose removal would contain one of those roots. Project memory,
instructions, policy, and continuity remain isolated through their scoped
APIs. Because shell access is deliberately native and unrestricted, those API
boundaries do not claim physical secrecy of same-user backing files.

Native runtime jobs track observed descendants by PID start identity, including
children that leave the launch process group. The normal budget is 16 and the
absolute retained-identity cap is 1,024; overflow fails the job rather than
growing without bound. Local outside-project delete and move rebuild their protected-root set at
execution and descriptor-recheck the source identity immediately before the
namespace change, so a rename between authorization and dispatch fails closed.

When the model saves a resume-ready handoff, Manager publishes a visible
30-second Dashboard countdown. At expiry, the native adapter activates LM
Studio, presses its exposed **New** control, fills **Chat input** with
`get_forge_status`, `resume=true`, the exact handoff ID, and a deterministic
rollover nonce, then presses **Send**. The visible GUI-hosted model calls the
already-installed `mcp/forge-conductor` or fallback tool. Forge accepts only the
owner-only receipt containing that exact handoff and nonce, then seals the
predecessor. Durable intent/submitted state and the native idempotency ledger
prevent duplicate successor chats across retries or Manager restart.

This path requires macOS Accessibility access for the signed Forge Conductor
app. It does not use `POST /api/v1/chat`, an integrations array, an
operator-facing LM Studio token, or a Forge-held same-host credential. Build 21
completed this live path in a selected foreground LM Studio tab through
`mcp/forge-conductor-fallback`.

## Authoritative connection path (stable)

**Primary (official LM Studio mechanism):** `~/.lmstudio/mcp.json`

**Operational registration (all roles use the same selected, smoke-tested
binary; CLU exposes its restricted surface):**

```json
{
  "mcpServers": {
    "forge-conductor": {
      "command": "/path/to/the/selected/forge-conductor-or-app-binary",
      "args": ["serve"],
      "env": {
        "FORGE_MCP_ROLE": "primary",
        "FORGE_CONDUCTOR_HOME": "/Users/<you>/.forge-conductor",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/<you>/.forge-conductor/bin"
      }
    },
    "forge-conductor-fallback": {
      "command": "/path/to/the/selected/forge-conductor-or-app-binary",
      "args": ["serve"],
      "env": {
        "FORGE_MCP_ROLE": "fallback",
        "FORGE_CONDUCTOR_HOME": "/Users/<you>/.forge-conductor",
        "PATH": "…"
      }
    },
    "forge-conductor-clu": {
      "command": "/path/to/the/selected/forge-conductor-or-app-binary",
      "args": ["serve"],
      "env": {
        "FORGE_MCP_ROLE": "clu",
        "FORGE_CONDUCTOR_HOME": "/Users/<you>/.forge-conductor",
        "PATH": "…"
      }
    }
  }
}
```

Current deployment also registers the restricted CLU role with the same
executable and `FORGE_MCP_ROLE=clu`. Its four continuity controls are a
deliberately smaller tool surface; do not replace that registration with either
general-tool entry. The CLI normally resolves the installed CLI executable. The
GUI deliberately supplies its own app executable. Primary, fallback, and CLU
never mix versions within one deployment.

SwiftPM builds place both `ForgeConductor_ForgeConductorCore.bundle` and
`ForgeConductor_ForgeConductorApp.bundle` beside their products. The native
staging path copies both into the app's `Contents/Resources`; its verification
mode waits three seconds and fails if the launched process exits. Installing a
bare CLI without the Core bundle still fails before changing the Forge home. A
relocated CLI lacking that bundle previously aborted before MCP `initialize`,
so both role smokes failed with an incomplete handshake. Focused deployment
acceptance exercises the relocated executable with its complete resource
boundary.

**Ship path (when deliberately registering an installed app):**

```bash
forge-conductor install-lmstudio-plugin \
  --binary "$HOME/.forge-conductor/Forge Conductor.app/Contents/MacOS/Forge Conductor"
```

Only do this after the **shipped** app binary responds to `serve` with MCP initialize (smoke below).
Do **not** point LM Studio at an older GUI-only `/Applications/Forge Conductor.app` — it ignores `serve`, opens UI, and LM Studio reports a ~60s plugin timeout.

LaunchAgent already uses the app as: `manager run --home …` (unrelated to MCP spawn).

**Secondary (lockstep mirror on this Mac):**
`~/.lmstudio/extensions/plugins/mcp/<name>/` with `runner: "mcpBridge"`.
The Forge primary, fallback, and CLU mirrors use the same executable and their
role-specific arguments and environment from `mcp.json`, and LM Studio reports them through
`PluginProcess(mcp/…)` logs.

Source of truth in code:

| Concern | Source file |
|---------|-------------|
| Stdio MCP protocol + unbuffered stdout | `Sources/ForgeConductorCore/MCP/MCPServer.swift` |
| SQLite multi-process wait | `Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift` (`busy_timeout=3000`) |
| CLI entry `serve` | `Sources/ForgeConductorCLI/ForgeConductorMain.swift` |
| App entry `serve` / `manager run` | `Sources/ForgeConductorCore/Application/ForgeProcessEntry.swift` |
| Typed connector role / aggregate health | `Sources/ForgeConductorCore/Domain/LMStudioConnector.swift` |
| `mcp.json` parse/merge/write | `Sources/ForgeConductorCore/Telemetry/LMStudioEnvironment.swift` |
| Transactional mcpBridge plugin deployment | `Sources/ForgeConductorCore/Telemetry/LMStudioMCPPluginInstaller.swift` |
| Pre/post deployment health and promotion | `Sources/ForgeConductorCore/Telemetry/LMStudioDeployService.swift` |
| Independent process/identity smoke | `Sources/ForgeConductorCore/MCP/MCPServeVerifier.swift` |
| GUI install / heal | `Sources/ForgeConductorApp/AppModel.swift`, `Views/MCPServersView.swift` |
| Live observation only | `ProcessDiscovery.swift`, `ForgeCollector.swift` |

## Handshake / timeout (what we fixed, what you must verify)

### Root signals (investigated)

| Signal | Meaning |
|--------|---------|
| `spawn …/forge-serve ENOENT` | Stale registration still pointed at deleted Python/bash launcher |
| ~60s `Client created` → `Client disconnected` in LM Studio logs | Host handshake timeout (stdio reply delayed or never arrived) |
| Forge logs `initialize`, but LM Studio never requests `tools/list` | LM Studio rejected the initialize response; verify newline-delimited MCP output and ensure no LSP-style `Content-Length` headers are emitted |
| GUI holding SQLite store | Concurrent writer contention without `busy_timeout` |
| Fully buffered stdout on pipes | `initialize` response stuck until buffer fill |

### Code repairs (Xcode → CLI product)

| Fix | Location |
|-----|----------|
| `setvbuf(stdout/stderr, _IONBF)` | `MCPServer.run` |
| Exactly one compact JSON-RPC message plus `\n` per stdout frame; no `Content-Length` | `MCPStdioTransport` in `MCPServer.swift` |
| Deployment smoke accepts only newline-delimited responses | `MCPServeVerifier` |
| Unique `FORGE_DEPLOYMENT_ID` in both role entries forces every `mcp.json` deploy to be observable | `LMStudioEnvironment` / installer |
| Exact-revision synchronization, loaded-model-preserving hot reload, scoped stale-state relaunch fallback, and runtime evidence | `NativeLMStudioHostActivator` |
| `PRAGMA busy_timeout=3000` | `SQLiteStore` |
| Transactional SwiftPM Core resource-bundle staging and bare-binary rejection | `ManagerInstaller` |
| Registration never writes `forge-serve` | `LMStudioEnvironment` / installer |
| Default spawn target = CLI `forge-conductor` | `resolveBinaryURL` / Install Plugin |

### Transactional operational deploy

Deployment performs these checks before reporting success:

1. The selected executable must pass independent primary, fallback, and
   restricted CLU MCP handshakes.
2. Existing `mcp.json` must parse; foreign servers are preserved.
3. All three plugins are staged and validated before live paths change.
4. Fallback commits first, followed by CLU, primary, and an atomic configuration write.
5. All three committed roles are smoked again. A commit failure rolls back all live paths.
6. Every deploy writes a new shared revision to all three role environments,
   even when the binary path is unchanged.
7. LM Studio is launched if necessary; an already running host with the exact synchronized revision is preserved, and only a genuinely stale unsynchronized host is gracefully relaunched.
8. Success is withheld until LM Studio's own synchronized MCP state contains all
   three roles with that exact revision. When the current chat activates them,
   host-originated `tools/list` evidence is also recorded for each role.

LM Studio then spawns the selected executable as:

`~/.forge-conductor/bin/forge-conductor serve`

That binary must be rebuilt and installed or selected explicitly.
**Do not silently overwrite** `/Applications/Forge Conductor.app` or the LaunchAgent home app unless the operator explicitly ships.

### Evidence checklist (stdio — no LM Studio UI required)

```bash
BIN="$HOME/.forge-conductor/bin/forge-conductor"
test -x "$BIN"

# Expect initialize + tools/list in well under 1s (typically <100ms)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| env FORGE_CONDUCTOR_HOME="$HOME/.forge-conductor" FORGE_MCP_ROLE=primary "$BIN" serve
```

Success criteria:

- `serverInfo.name` = `forge-conductor` (or `forge-conductor-fallback` with role=fallback)
- `tools/list` exposes the versioned Forge surface, including legacy compatibility
  tools, `project_memory.*`, durable runtime tools, `fs_delete_recovery`,
  `shell_exec`, and additive `bash.run`
- Each response is a single compact JSON object terminated by `\n`; stdout contains no `Content-Length` header
- No `forge-serve` in `~/.lmstudio/mcp.json` or mcpBridge configs

### LM Studio host verification (automated)

Standalone stdio smoke does not prove that LM Studio accepted the configuration. Deploy therefore requires LM Studio's generated `last-synced-mcp-state.json` to contain both `mcp/forge-conductor` and `mcp/forge-conductor-fallback` entries with the committed revision. The operation launches LM Studio when it is closed and relaunches it only when hot reload cannot replace possible stale processes. MCP plugin processes are lazy and start when selected by a chat; when they start, Forge records revision-correlated `tools/list` evidence. If synchronization fails, Deploy returns an error instead of reporting success.

For diagnosis only:

```bash
rg -i 'Plugin\(mcp/forge-conductor\)|forge-serve|ENOENT|timeout' \
  ~/Library/Logs/LM\ Studio/main.log ~/.lmstudio/server-logs/
```

## Fail-forward connection state

| Mechanism | Behavior |
|-----------|----------|
| State | Meaning |
|---|---|
| `ready` | Primary and fallback both passed role-aware MCP verification |
| `primary_only` | Primary is serving; fallback is degraded and should be repaired |
| `fallback_promoted` | Primary is degraded; fallback remains a valid serving connector |
| `unavailable` | Neither connector is healthy; deployment/health check fails closed |

The two registrations are separate LM Studio-hosted processes with distinct `serverInfo.name` values. This prevents one broken stdio session from taking down both paths. Forge does not impersonate LM Studio's scheduler: automatic selection between enabled MCP servers is ultimately a host/operator responsibility.

## Operator steps

1. Build with the canonical Xcode `ForgeConductor` scheme or the direct
   `swift build --product forge-conductor-app` command.
2. Install CLI layout: `forge-conductor install` (does **not** write LM Studio by itself).
3. Deploy and activate: **Deploy to LM Studio** in the GUI, or `forge-conductor install-lmstudio-plugin`.
4. Load a tool-capable local model and run **Provider → Connect and Check**.
5. Register project folders, order instruction packages, and order Development
   Policy sources.
6. Open an LM Studio chat, call `get_forge_status`, and provide the task.

### App-as-MCP qualification checklist

1. Build an app whose executable enters MCP stdio mode when run with `serve`; normal startup must remain silent on stderr.
2. Smoke that app path with the same initialize/`tools/list` protocol.
3. `forge-conductor install-lmstudio-plugin --binary "<app executable>"`.
4. Confirm the command reports host acknowledgement for primary, fallback, and
   CLU; restart is automated only if hot reload is insufficient.

Completing this connector checklist proves only the LM Studio registration and
stdio path. The retained Apple Development-signed installed-app qualifier
passed raw-CLI checks and `shell_exec` across app relaunch and installed-manager
PID replacement. It remains partial because its own System Events Settings
step was not run. A separate native Xcode run passed four production onboarding
scenarios, including Settings shell off/on with fresh MCP processes and real
provider discovery/connection. The historical 100-cycle navigation result and
later native gauge component tests retain their distinct source and fixture
scopes; see [qualification status](QUALIFICATION-STATUS.md).

The October 3 `0.16.5 (26)` repair completed a universal Developer ID archive/export
and isolated native bootstrap and folder-picker export checks, recorded in
[qualification status](QUALIFICATION-STATUS.md). That candidate evidence does
not qualify installation, notarization, distribution, or a full LM Studio workflow.

P10, filesystem E2, current G09-G12, the complete
installed/native UI and service-lifecycle matrix, notarization/Gatekeeper,
manager-owned real-provider forced rollover, and owner-deferred representative
physical-hardware qualification remain open. Focused connector or onboarding
passes do not replace those release-blocking runs.

The retained compatibility automation uses the same typed LM Studio provider configuration as
the MCP plugin registration described above. In **Provider**, enter the endpoint
and model identifier, choose to keep/replace/clear the Keychain credential, and
select **Save**. Saving works offline. Choose **Connect and Check** for automatic
local-server recovery, model resolution, and contract verification. Save edits
before connection work, and load models in LM Studio itself. Active runs and
in-flight operations block conflicting configuration changes. The native screen
uses authenticated, revisioned manager controls and follows manager replacement.
See the [provider workflow](../USER-GUIDE.md#2-connect-lm-studio).

## Auto-heal

On GUI bootstrap, registration is **not** auto-written (operator must Install Plugin).
`LMStudioMCPPluginInstaller.ensureConnection` exists for explicit heal paths when registration is incomplete or drifted. Repairs use the same typed, transactional installation boundary rather than modifying only one role.

## Doctor and stale registrations

Settings → **Run doctor** reports the executing Forge version and build, the
resolved current-build executable, and separate status rows for the primary,
fallback, and CLU mcpBridge plugins. A role is current only when its deployed
files and LM Studio registration resolve to that executable and matching
deployment state. Existing plugin files whose registration still names an old
app or CLI path are reported as **stale**, not as absent.

Any non-current LM Studio role makes the visible Doctor result **ISSUES**, even
though plugin checks are advisory rather than failures of the local database or
runtime. Choose **Deploy current build to LM Studio** from the Doctor result to
run the normal transactional three-role deployment, then rerun Doctor. Do not
repair only the CLU directory or hand-edit one registration: all roles must stay
bound to the same build and deployment revision.
