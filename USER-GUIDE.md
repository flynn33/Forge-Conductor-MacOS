# Forge Conductor user guide

Version **0.10.0**, build **2**. This guide covers the native Forge Conductor
application and its LM Studio integration on macOS.

> `0.10.0 (2)` is the current development identity. It has not inherited the
> artifact qualification of earlier `0.9.0 (1)` candidates. See
> [qualification status](docs/QUALIFICATION-STATUS.md) for current evidence and
> open release gates.

## Find the right guide

| Need | Guide |
| --- | --- |
| Build, archive, or sign the app | [Xcode guide](XCODE.md) |
| Connect or repair LM Studio MCP | [LM Studio connection](docs/LM-STUDIO-CONNECTION.md) |
| Queue project instructions | [Instruction packages](docs/INSTRUCTION-PACKAGES.md) |
| Configure protected completion | [Native completion](docs/NATIVE-COMPLETION.md) |
| Understand current release evidence | [Qualification status](docs/QUALIFICATION-STATUS.md) |
| Browse all current and historical docs | [Documentation guide](docs/README.md) |

## 1. What this is

Forge Conductor is a **local MCP tool server** plus a **native dashboard**. LM Studio is the host: it loads the model, owns the chat window, and calls Forge tools over stdio.

Forge does **not**:

- run the language model
- sit inside LM Studio’s process
- open a new LM Studio GUI chat (the `lms chat` CLI is a different, non-GUI session)
- replace chat history with a compressed window inside the current chat

Forge **does**:

- expose filesystem, git, memory, agent, continuity, and project-scoped shell tools to the model
- persist task state under `~/.forge-conductor`
- checkpoint and hand off that state without waiting for the model to remember `session_*`
- block further project tools on a chat that has already been handed off, until `context_get`

---

## 2. Requirements

- macOS 26+
- LM Studio installed (for models and MCP)
- A Forge binary that understands `serve` (0.5+ app or the `forge-conductor` CLI)

An older GUI-only `/Applications/Forge Conductor.app` that ignores `serve` will make LM Studio sit on the plugin until it times out (~60s). Point MCP at a binary you have verified with `serve`.

---

## 3. Layout on disk

Default home (override with `FORGE_CONDUCTOR_HOME`):

| Path | Role |
|------|------|
| `~/.forge-conductor/store.sqlite` | Sessions, memory, handoffs, presence, and audit index |
| `~/.forge-conductor/control-plane.sqlite3` | Project/generation/binding/run control state and dedicated bounded transition-authority rows; diagnostic audit retention cannot grant or revoke transition authority |
| `~/.forge-conductor/config.json` | Config (dashboard port, allowed roots, timeouts) |
| `~/.forge-conductor/bin/forge-conductor` | Installed CLI (typical MCP target after `install`) |
| `~/.forge-conductor/memory/current-task.md` | Readable projection of the latest packet |
| `~/.forge-conductor/memory/NEXT-CHAT.md` | Written when a handoff fires — what to do next |
| `~/.forge-conductor/memory/handoffs/` | JSON copies + `LATEST` pointer |
| `~/.forge-conductor/logs/` | Diagnostic JSONL |
| `~/.lmstudio/mcp.json` | LM Studio’s MCP registry |
| `~/.lmstudio/extensions/plugins/mcp/forge-conductor/` | Primary mcpBridge plugin |
| `~/.lmstudio/extensions/plugins/mcp/forge-conductor-fallback/` | Fallback mcpBridge plugin |

Primary and fallback are two registrations of the **same** binary with `FORGE_MCP_ROLE=primary` or `fallback`. They are independent processes. Fallback is redundancy, not a second product.

---

## 4. Install and deploy

For a complete signed Xcode installation or update, use the
[explicit Xcode build and transactional installer](XCODE.md#install-the-exact-xcode-build).
It selects one build directory and keeps the app, CLI, runtime launcher and
framework together. Release distribution uses Xcode archive/export and the
owner’s manual shipping process after qualification.

For a separate source-built Debug app from this repository:

```bash
cd /path/to/Forge-Conductor-MacOS
open ForgeConductor.xcworkspace
xcodebuild -scheme ForgeConductor -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/forge-conductor-user-guide build
```

Run `/private/tmp/forge-conductor-user-guide/Build/Products/Debug/Forge
Conductor.app` in Xcode or as a separate local candidate. Start **Manager**,
authorize your project folder, register it in **Projects**, and save/probe the
loaded model in **Provider**. For managed work, choose the registered project,
enter the instructions, and select **Start Task** in **Autonomy**. Forge fills
the saved model, registered capability profile, and completion check; technical
overrides remain available under **Advanced**. For an LM Studio desktop chat, deploy the
MCP roles as described below. A SwiftPM CLI build by itself is not the complete
signed app; its Core resource bundle must be adjacent before MCP initialization.

For the installed same-build CLI and signed app, use the
[Xcode installer steps](XCODE.md#install-the-exact-xcode-build). The CLI's
`install` command stages the selected signed CLI/resource/launcher set in the
per-user Forge home; it does not replace `/Applications/Forge Conductor.app`.

In **LM Studio MCP**, select **Deploy to LM Studio**. The equivalent
`forge-conductor install-lmstudio-plugin` command from the same-build installed
CLI transactionally writes `mcp.json` and both mcpBridge roles. Do not hand-edit
those files unless deploy failed and you are diagnosing.

Confirm the registered command is a `serve`-capable 0.10.0 binary:

```bash
forge-conductor version    # should print 0.10.0
plutil -p ~/.lmstudio/mcp.json
```

For an app bundle, `CFBundleShortVersionString` must be `0.10.0` and
`CFBundleVersion` must be `2`.

On a clean install, project shell tools are enabled by default. Schema-v1
configurations persisted no provenance capable of distinguishing the shipped
disabled default from a user-chosen false value, so they migrate to enabled. An
explicit schema-v2 user opt-out records provenance and remains disabled. The current native
app exposes **Enable project shell tools** and the default timeout in Settings,
and the same policy is persisted in `~/.forge-conductor/config.json`. Model tool
arguments cannot change this operator policy.

`shell_exec` remains registered in MCP `tools/list`, including when the operator
has opted out. When enabled, it requires an authorized project workspace, runs
the command synchronously through `/bin/bash -lc`, enforces the 120-second
maximum, and retains its established result fields (`ok`, `exit_code`, `stdout`,
`stderr`, timeout and truncation fields, `command`, and `cwd`). `bash.run` is an
additive durable-job tool that starts Bash with profile and rc files disabled;
it does not replace or redefine `shell_exec`.

The current tree has policy, migration, registration, execution, result-contract,
and restart regressions. A bounded Apple Development-signed Release installed-
app run executed `shell_exec` through login Bash from both the app executable and
installed raw CLI. It verified clean-install enablement, accidental legacy-
disabled migration, explicit opt-out and denial, one `shell_exec` entry in
`tools/list`, app close/reopen, and installed LaunchAgent manager replacement by
a new PID with predecessor exit. The raw installed CLI also passed `version`,
`status`, and `doctor`, and the launcher beside it was signed and verified. The
installed-app run deliberately did not invoke System Events and remains partial.
A separate Xcode run passed native Settings shell disable/re-enable and execution
from fresh MCP processes. The final current-local-workspace universal Developer
ID archive and stapled app ZIP passed strict signatures and local Gatekeeper;
the full installed/native root-service matrix, installer signing/notarization,
public download, and broader hardware checks remain open. The bounded
compatibility scenarios pass; shipment does not.

---

Numeric settings require whole numbers within the field's supported range. An
invalid request returns the field and permitted range without saving any part
of the request. Correct the value and save again; the manager remains available.

Settings controls become editable after saved settings load. If startup fails,
Settings shows the error and **Retry startup**. Operator screens also wait for
startup to finish and provide retry if it fails. Settings saves run in the
background. Wait for **Settings saved** before using
a changed manager address or shell policy. A second settings operation is
rejected while the first is active. Edits made during a save remain visible and
are explicitly marked unsaved when the earlier save completes. Diagnostics
exports also run in the background and report their output paths on completion.

The manager also persists versioned budget defaults and project overrides through
its authenticated settings API. Conflicting edits return the current revision;
a saved policy takes effect at the next controlled runtime boundary. Dedicated
native budget controls and complete tool-call reservation enforcement remain
separate implementation phases. See [Budget policy](docs/BUDGET-POLICY.md) for
scope, units, persistence and requested/effective behavior.

## 5. Daily use with LM Studio

1. Open Forge Conductor (dashboard) if you want live telemetry. Default: `http://127.0.0.1:7788/`.
2. Open LM Studio. Load a model. Enable the **Forge-Conductor** preset if you use one.
3. In the chat, enable MCP servers **forge-conductor** and **forge-conductor-fallback**.
4. Start a **new** chat for a new work block. Do not keep an already-handed-off chat alive for more project tools.
5. First useful model calls (the preset asks for these; Forge also survives if they are skipped):
   - `forge_status`
   - `context_get`
   - `memory_search` / `memory_list` as needed
6. Work. Prefer `agent_run_start` with an explicit `cwd` for write work and any locally enabled shell work. Read-only listing of folders under your home is allowed without a session (not `Library`, `.ssh`, and similar).
7. When Forge hands off, **start a new chat** and call `context_get`. Read `~/.forge-conductor/memory/NEXT-CHAT.md` if the model is confused.

LM Studio only starts the `serve` processes when a chat has those MCP servers selected. Idle “MCP not running” on the dashboard with no chat open is expected.

### Managed project setup and ordered instruction packages

The built-in setup guide opens on first launch and remains available from the
question-mark toolbar button. For a Forge-managed autonomous queue:

1. Start LM Studio's local server with a loaded tool-capable model.
2. In **Provider**, save the loopback endpoint and loaded model, then run the
   connection and contract checks. Provider is the manager-owned connection
   Forge uses to create model sessions; it is separate from the MCP servers
   enabled in an ordinary LM Studio desktop chat.
3. In **Manager**, add the repository or its parent directory to **Allowed
   Roots**, apply the settings, and start the manager if it is stopped.
4. In **Projects**, register the local repository folder.
5. Under **Instruction packages**, add a Markdown/text file, a folder of
   instructions, or a `.forgepackage`/`forge-package.json` manifest. Drag rows
   up or down to establish the execution order.
6. Choose **Start Ordered Autonomy**. Forge starts one managed run at a time for
   that project and advances only when the prior package completes. A failed,
   cancelled, paused, or configuration-blocked run stops advancement.

Each accepted package is copied to protected, content-addressed storage and
bound to the selected project UUID and generation. The model's filesystem scope
is the registered repository, even when the imported instruction file lives
elsewhere. **Stop Queue** prevents the next package from starting while leaving
an already admitted run visible in **Autonomy**.

Use **Remove Selected Project…** below the project list, the row context menu,
or **Remove Project…** in the detail pane to remove a registration. Forge asks
for confirmation, advances the project generation, and invalidates bindings;
durable project memory and historical run evidence remain. Registering the same
repository again reconnects its durable identity. Package formats, manifest
fields, limits, and storage behavior are documented in
[Project instruction packages](docs/INSTRUCTION-PACKAGES.md).

---

## 6. Continuity (packet automation and current boundary)

When a project is registered, Forge preserves old handoff files, imports clearly
attributable records as read-only history, and quarantines ambiguous records with
an explanation. These records do not start or authorize a successor. Project
initialization reports migration status and counts. If migration is pending,
registration retains the committed project identity and reports reconciliation
as required. Resolve the reported migration issue, then retry registration for
the same project. See [Legacy migration](docs/CONTINUITY-INGRESS.md#legacy-migration-during-project-registration)
for inventory limits and recovery behavior.

The checkpoint and handoff behavior below is implemented. Forge's native
managed-host path has completed one threshold-forced real-provider rollover:
the successor restored and acknowledged the exact durable handoff, ordinary
work ran, its output was consumed by the following turn, the predecessor was
fenced and sealed, and restart replay remained stable. Deterministic tests cover
repeated rollovers and injected recovery transitions. A second live attempt hit
the provider's bounded deadline and is retained as a nonpass, so the single
live pass is not described as a broad provider reliability matrix.

LM Studio's desktop chat remains a separate host-owned mode. Its supported APIs
do not let Forge attach to or replace an existing GUI conversation. Use the
new-chat recipe below for an LM Studio-owned desktop chat. Forge-managed
Autonomy uses the native session host for automatic rollover and does not claim
to automate LM Studio's private GUI.

For a native client with an explicit read-only task approval, use
`forge-conductor manager task prepare --request /absolute/approval.json`.
Preparation does not start a provider or a run. The CLI keeps the task credential
in protected storage and prints a safe receipt. If it reports
`reconciliation_required`, use `manager task reconcile --task UUID` with the
reported task ID. Add `--home /absolute/path` to each command when using a custom
installation. See [native source attachment](docs/CONTINUITY-INGRESS.md#authenticated-native-source-attachment)
for scope limits, rotation, revocation, and the native connection contract.

### Configure the managed provider

Open **Provider** and enter the LM Studio endpoint (normally
`http://127.0.0.1:1234`). Remote endpoints require HTTPS. Enter the model's exact
identifier, or leave it empty when exactly one supported model is loaded.
Choose **Keep existing credential**, **Replace credential**, or **Clear credential**.
Replacement tokens are stored in Keychain and are never returned in snapshots.

Select **Save**. Saving persists settings even when LM Studio is offline; it
does not load a model or test the connection. **Refresh Models** queries the saved
endpoint and shows available models and their loaded state. Select a model and
save again to use that selection. Unsaved edits disable discovery and probes
until they are saved. **Test Connection** checks the saved endpoint
and loaded model. **Run Contract Probe** also checks the provider capabilities
required for managed execution. Load models in LM Studio itself.

Forge uses LM Studio's native v1 inventory for model metadata. Some desktop
versions can briefly return no `loaded_instances` there even though the native
v0 inventory reports the exact selected model as `loaded`. Forge checks that
bounded compatibility response and accepts only an exact model identifier with
a valid loaded context length. A different identifier, an unloaded state, or an
invalid response remains unavailable.

Finish or cancel existing managed runs before changing settings. An in-flight
probe or active run blocks a conflicting save. Invalid settings leave the last
saved revision intact; if another control changed that revision, refresh and
review it before retrying. If a save is cancelled or the connection is lost,
refresh to reconcile the persisted result. A credential cleanup notice means
settings were saved but Keychain cleanup needs a retry after Keychain is unlocked.
These controls configure Forge-managed sessions; LM Studio MCP deployment remains
in **LM Studio MCP**.

If a run reaches **Blocked configuration** because its native completion policy
is missing or its required environment is unavailable, repair or import the
policy for that exact run and select **Retry**. Forge revalidates the persisted
completion request without repeating the model turn or its tool calls. Provider,
resource, and other recoverable failures continue through normal recovery.

### 6.1 Provider-response recovery boundary

Accepted provider receipts are durable across manager restart. If Forge crashes
after the provider may have accepted a request but before its response is
resolved, the manager fences that request for **660 seconds**. LM Studio does not
expose a request-ID receipt lookup, so a retry after the fence can create at
most one duplicate model inference for that attempt. Repeated operator or
recovery retries can therefore repeat inference.

Forge reconciles manager-owned tool effects so a replayed response does not run
the same tool effect twice. This limits side effects, but it does not make model
inference exactly once and does not eliminate the response race.

### 6.2 What the model can still call

| Tool | Effect |
|------|--------|
| `session_checkpoint` | Soft-save packet; work may continue |
| `session_handoff` | Finalize; mark resume-ready; return `resume_seed` |
| `context_get` | Load latest (or a given id) packet; adopt workspace; **clear a context-budget block** on this client |
| `context_list` | List recent packets |

### 6.3 What Forge does without being asked

Progress tools are: `fs_*`, `shell_exec`, `git_*`, `memory_set`, `search_text`, `pdf_*`, `agent_run_start`, `agent_run_complete`.

| When | What happens |
|------|----------------|
| Every **5** progress tools, or **3 minutes** | Auto-checkpoint. Existing goal, next actions, and narrative on the packet are **kept**. |
| `agent_run_start` / `agent_run_complete` | Checkpoint immediately. |
| Every **20** progress tools, or **12 minutes** | Auto-handoff: packet `resume_ready`, `memory/NEXT-CHAT.md`, `handoff_required` on the tool result. |
| After that handoff, or after **9** identical tool calls | Further `fs_*` / `shell_exec` / `git_*` on **that MCP client** return `context_budget_exceeded`. The write is not executed. |
| New LM Studio chat | New `serve` process, new client id. The in-memory block from the old process is gone. Call `context_get` so the model loads the packet. |

Identical-call budget (separate from the 20-tool rule):

- 4th identical call: soft handoff signal (`handoff_required`), work can still continue
- 9th identical call: hard `identical_call_loop` and the same client is blocked

### 6.4 What a handoff is not

A handoff is a **file + SQLite packet**. It does not shrink the current LM Studio transcript. The current chat still contains every prior tool dump. That is why the block exists: to make you start a **new** chat instead of prefilling 150k tokens again.

Forge cannot click “New chat” in the LM Studio GUI.

### 6.5 New-chat recipe

1. Leave the old chat (it may now refuse project tools).
2. New chat, same preset, MCP enabled.
3. `context_get` (no id = latest packet).
4. If the packet lists open agents, `agent_run_status` with that `session_id`, or complete and start a new agent with the same `cwd`.
5. Continue from `task.next_actions` and `memory/current-task.md`.

---

## 7. Memory notes

Key/value notes in SQLite. They survive chats, model unloads, and MCP restarts.

| Tool | Purpose |
|------|---------|
| `memory_set` | Upsert `key` + `body` |
| `memory_get` | Read one key |
| `memory_list` | Browse (`prefix`, `tag`) |
| `memory_search` | Substring search |
| `memory_delete` | Delete a key |

Suggested keys: `project/<slug>/overview`, `project/<slug>/paths`, `project/<slug>/decisions`, `user/preferences`. Internal keys (`agent_run/*`, `continuity/*`) are hidden from list/search unless `include_system` is true.

### 7.1 Project-scoped memory

Version 0.9.0 introduced independent project stores for larger, structured working sets.
Call `project_memory.initialize` with an authorized project path, then use the
returned project id with the remaining tools.

| Tool group | Purpose |
|------------|---------|
| `project_memory.remember` / `remember_batch` | Store one record or a bounded transactional batch |
| `project_memory.search` / `get` / `list_recent` | Retrieve bounded, paginated results |
| `project_memory.update` / `forget` / `link` | Version, tombstone, and relate records |
| `project_memory.export` / `import` | Move checksummed project artifacts with preview support |
| `project_memory.status` | Report store health, capabilities, sizes, and limits |

Project memory is additive. The original `memory_*` notes remain available for
small global or continuity-oriented keys.

---

## 8. Agents

Specialists: `explore`, `plan`, `implement`, `debug`, `test`, `review`, `security`, `docs`, `precommit-audit`, `research`.

Typical sequence:

```
agent_recommend → agent_run_start(agent_id, goal, cwd) → tools → agent_run_complete(report)
```

`agent_run_start` requires an explicit workspace `cwd` for `shell_exec` / `git_add` / `git_commit` when no implicit workspace exists. After `context_get`, the packet’s `cwd` is adopted, so shell in that folder can work without starting a new agent. Starting an agent is still the right way to bind a playbook and tool policy.

`agent_run_complete` must fill every key in that agent’s `output_schema`. An incomplete report is a warning, not a silent success.

---

## 9. Dashboard

Default bind: `http://127.0.0.1:7788/` (loopback).

| Surface | What it shows |
|---------|----------------|
| Rig | Host CPU / RAM / GPU / disk (sampled continuously) |
| LM Studio MCP | Live Forge stdio servers, configured roles, LM Studio host processes |
| Agents / Tools / Feed | Sessions and recent tool audit |
| Manager / Settings | Start/stop the HTTP control plane; inspect and change the persisted project-shell policy |

`primary_alive` / `fallback_alive` are true only when a **stdio `serve` process** for that role is running. That happens when a chat has MCP enabled, not merely because the GUI is open.

The MCP list shows Forge stdio roles (`mcp-stdio`, `mcp-stdio-fallback`) and configured-but-not-started roles. LM Studio helper and model-backend processes are not listed as MCP servers.

Host metrics run at ~30 Hz in the native UI. That is intentional and uses CPU even when MCP is idle.

---

## 10. Errors you will see

| Code | Meaning | What to do |
|------|---------|------------|
| `context_budget_exceeded` | This chat was handed off. Project tools are blocked on this client. | New chat + `context_get` |
| `identical_call_loop` | Same tool + same args 9 times. | Change arguments, or new chat + `context_get` |
| `shell_disabled` | The operator explicitly opted out of project shell tools, or the configured policy is not enabled. | Use the native Project shell setting or a valid local policy update; model arguments cannot override it |
| `active_session_required` | `shell_exec` / some git tools need a workspace (agent `cwd` or adopted packet `cwd`). | `agent_run_start` with `cwd`, or `context_get` if a packet has one |
| `path_outside_allowed_roots` | Path is outside Forge home, configured roots, agent/packet cwd, and (for writes) not a permitted home read. | Use a path inside the workspace; do not write outside it |
| `tool_forbidden` / `tool_not_granted` | Current agent playbook does not allow that tool. | Different agent, or complete the session |
| `path_outside_allowed_roots` on a folder you just named | Usually no session and no packet cwd yet. | `context_get` or `agent_run_start` with that folder as `cwd` |

`shell_exec` failures record `exit_code` and a truncated `stderr` in the audit error field.

---

## 11. Two MCP servers

You will see **forge-conductor** (primary) and **forge-conductor-fallback**. They expose the same versioned tool surface. Both should stay registered.

LM Studio may send all `tools/call` traffic to one of them (often fallback). That is a host routing choice. As long as one role is serving, work proceeds. Do not delete fallback because primary looks idle.

---

## 12. Limits (do not expect these)

- Forge will not open a new LM Studio window or tab.
- Forge will not compact the current chat’s token window.
- One manager-owned autonomous succession completed with the real loopback LM
  Studio provider. Deterministic tests cover repeated rollover; the second live
  attempt timed out during long prompt processing and is not counted as a pass.
- An interrupted protected deletion can retain a recovery handle and prevent
  new mutations on that protected volume. Path absence alone is not a successful
  delete receipt. Preserve the recovery identifier; do not remove protected
  transaction files manually. Signed recovery and retained-entry disposition
  qualification remain open.
- Protected filesystem capture and quarantine mitigate known destructive-path
  races but do not eliminate them. E2 remains mandatory until the signed
  distinct-process 57-case matrix and formal predicates pass. Production
  `fs_move` refuses replacement and crosses neither an authorized root nor a
  volume; recursive directory `fs_delete` commits bounded bottom-up helper
  transactions. Their focused protocol/adversarial tests pass, while approved
  root-service execution remains unmeasured on this host.
- Configure the managed provider using Provider controls and test the saved
  connection before starting Autonomy. The current signed combined native case
  also canceled and reopened the policy picker, imported an exact run-bound
  manifest fixture, and read back the protected policy; a completed installed-stack run
  remains open.
- The local notarized Developer ID app ZIP passed Gatekeeper, but Installer
  notarization, public-download acceptance, unsupported existing-desktop attachment,
  privileged root-service E2, and the representative physical-hardware matrix
  remain open; this guide is not a ship authorization.
- `/Applications/Forge Conductor.app` is not updated by `install` if the OS refuses the overwrite. Check **version** on the binary LM Studio actually spawns.
- `forge-conductor install` from the CLI may stage a **CLI** binary inside `~/.forge-conductor/Forge Conductor.app`. That bundle is not a substitute for the SwiftUI GUI in `dist/` or a proper app-bundle install.
- Read-only tools can list most of your home directory. Treat that as a real permission, not a sandbox.

---

## 13. Troubleshooting

**Bootstrap failed: migration backup verification**

Do not delete a migration manifest, replace a backup with the current database,
or loosen file permissions to force startup. A completed manifest may refer to
a historical backup that is no longer present. Preserve the Forge home first;
check database integrity, schema version, and the exact migration receipt on a
disposable copy before any recovery. A newer verified backup cannot restore the
missing historical version. The CLI's `status` and `doctor` commands can confirm
startup after the recovery record is reconciled.

**MCP never starts / 60s timeout**
The registered `command` is not a `serve` binary, or stdout is being buffered (0.5+ unbuffers it). Run:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  | forge-conductor serve
```

You should get a JSON-RPC initialize result immediately.

**Dashboard empty / no MCP telemetry**
Open a chat with MCP enabled. Then check `/api/status` and `/api/snapshot`. `presence` is filled from live `serve` heartbeats (every 10s while the process is up).

**Model keeps spinning with no tools**
That is LM Studio prompt processing (large context), not a dead Forge server. Check `lms ps` (`PROCESSINGPROMPT` vs `GENERATING`) and `~/.forge-conductor/logs/`.

**Handoff looks stale**
Read `memory/current-task.md` and `context_get`. Auto-checkpoint keeps existing next-actions unless the model overwrites them. Status `source: auto` means Forge wrote the last persist, not that the goal changed.

**Doctor complains about `~/.forge-conductor/bin/forge-conductor`**
Install the CLI, or treat an app-bundle `serve` path as valid. A missing home shim is not a failed MCP deploy if `mcp.json` points at a working binary.

---

## 14. Moving this project to another Mac

This directory is a git repository (`origin` → `https://github.com/flynn33/Forge-Conductor-MacOS.git`). It is the source you copy or push.

On the new Mac:

1. Clone or copy this folder.
2. `swift test` then build/install as in §4.
3. `forge-conductor install-lmstudio-plugin --binary` the **new Mac’s** installed CLI or app `serve` binary.
4. Copy `~/.forge-conductor/store.sqlite` and `memory/` only if you want the same packets and notes. Do not copy another machine’s `mcp.json` command paths.

Do not commit `.build/` or `dist/` (they are gitignored).
