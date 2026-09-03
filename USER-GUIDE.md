# Forge Conductor user guide

Version **0.9.0**, build **1**. This guide is for operators who run Forge Conductor with
[LM Studio](https://lmstudio.ai) on macOS.

## Current status

| Implemented and test-backed in this source | Still open or deferred before shipment |
|---------------------------------|----------------------------------------|
| The CLI reports 0.9.0; runtime constants, Xcode settings, and the built app bundle report 0.9.0 build 1. | Signed distinct-process filesystem E2 and recovery qualification. |
| Native app surfaces build; an earlier exact-revision Apple Development-signed 100-cycle Rig/MCP navigation result remains supporting evidence. | Final current-source navigation/action rerun, Developer ID Release, full native/settings/service lifecycle, archive, notarization, staple, and Gatekeeper validation. |
| Project memory, durable jobs, and telemetry have current-source regression coverage. The SwiftPM Release suite executes 1,001 tests with 5 declared environment skips and 0 failures; a dedicated signed Xcode app-hosted contract suite executes 2 tests with 0 failures. A bounded signed installed-app scenario passed shell policy, migration, `tools/list`, established `shell_exec` through app and raw CLI, app relaunch, and installed-manager PID-replacement checks. | Production Settings control and post-Settings re-enable through XCUI, Developer ID Release, and exact P10 production qualification. |
| Durable continuity state, provider receipt storage, successor/fencing models, and tool-effect reconciliation are implemented. | Manager-owned threshold-forced real-provider rollover, exact successor acknowledgment, automatic continuation, GUI-closed operation, and durable crash recovery. |
| Protected regular-file/symlink deletion has protocol-v5 capture and recovery machinery. | Production `fs_move`, recursive directory `fs_delete`, signed distinct-process filesystem E2, and recovery qualification. |
| The managed adapter can load and validate an existing LM Studio configuration. | A supported clean-install app/CLI/manager control for creating and updating that configuration. |
| Package P10/G10 evidence remains available for qualification review. | Package P10/G10 and current G09-G12 remain open; representative physical-hardware qualification is owner-deferred. |

Where implementation has only unit, synthetic-host, simulator, focused Debug,
or build-only evidence, that boundary is stated plainly. This guide does not
mark a package or release gate complete.

Related detail (developer-oriented):

- [README.md](README.md) — build, CLI, architecture
- [docs/LM-STUDIO-CONNECTION.md](docs/LM-STUDIO-CONNECTION.md) — how LM Studio spawns Forge
- [docs/CONTEXT-AGENT-CONTINUITY.md](docs/CONTEXT-AGENT-CONTINUITY.md) — packet format and triggers
- [docs/DURABLE-MEMORY.md](docs/DURABLE-MEMORY.md) — `memory_*` tools
- [CHANGELOG.md](CHANGELOG.md)

---

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

From this repository, after a successful build:

```bash
cd /path/to/Forge-Conductor-MacOS-main
swift test                          # optional but recommended
swift build --product forge-conductor --configuration release
# copy or:
./script/build_and_run.sh --build-only

# CLI into ~/.forge-conductor (does not write LM Studio by itself)
forge-conductor install

# Same effect as GUI → LM Studio MCP → Deploy to LM Studio
forge-conductor install-lmstudio-plugin \
  --binary "$HOME/.forge-conductor/bin/forge-conductor"

forge-conductor doctor
```

`install` does **not** replace `/Applications/Forge Conductor.app`. If that path is not writable (common on a locked-down Mac), keep using the staged GUI under `dist/Forge Conductor.app` or the home CLI for MCP.

`install-lmstudio-plugin` is the supported way to write `mcp.json` and both mcpBridge plugins. Do not hand-edit those files unless deploy failed and you are diagnosing.

Confirm the registered command is a `serve`-capable 0.9.0 binary:

```bash
forge-conductor version    # should print 0.9.0
plutil -p ~/.lmstudio/mcp.json
```

For an app bundle, `CFBundleShortVersionString` must be `0.9.0` and
`CFBundleVersion` must be `1`.

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
run deliberately did not invoke System Events; native Settings control and post-
Settings re-enable remain blocked for Xcode XCUI. Developer ID Release signing,
exact current-source P10 production qualification, the full native UI matrix,
archive, notarization, and staple/Gatekeeper evidence remain open. The bounded
compatibility scenarios pass; shipment does not.

---

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

---

## 6. Continuity (packet automation and current boundary)

The checkpoint and handoff behavior below is implemented. The current
development snapshot has not yet proven autonomous session succession through a
manager-owned, threshold-forced real-provider rollover. Until that test also
proves exact successor acknowledgment, predecessor fencing, idempotent sealing,
automatic continuation, GUI-closed operation, and crash-state recovery, use the
new-chat recipe as the operational path rather than treating autonomous
continuity as qualified.

Unit and synthetic-host tests do not close this gate. The authority run must use
the real provider with the GUI closed and recover from every durable crash state.

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

Version 0.9.0 adds independent project stores for larger, structured working sets.
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
- The current checkpoint does not yet qualify manager-owned autonomous
  succession. A directly invoked provider-adapter test is not a substitute for
  the required forced-rollover scenario.
- Protected filesystem capture and quarantine mitigate known destructive-path
  races but do not eliminate them. E2 remains mandatory until the signed
  distinct-process 57-case matrix and formal predicates pass. Production
  `fs_move` and recursive directory `fs_delete` are unavailable until their
  additive signed-helper protocols are implemented and qualified.
- Managed Autonomy is not operable on a clean install until the product can
  create and validate its LM Studio provider configuration; test-written files
  are not a supported operator workflow.
- Current G09-G12, native Settings/release/signing, exact shell UI
  qualification, real-provider continuity, and owner-deferred representative
  physical-hardware gates remain open; this guide is not a ship authorization.
- `/Applications/Forge Conductor.app` is not updated by `install` if the OS refuses the overwrite. Check **version** on the binary LM Studio actually spawns.
- `forge-conductor install` from the CLI may stage a **CLI** binary inside `~/.forge-conductor/Forge Conductor.app`. That bundle is not a substitute for the SwiftUI GUI in `dist/` or a proper app-bundle install.
- Read-only tools can list most of your home directory. Treat that as a real permission, not a sandbox.

---

## 13. Troubleshooting

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
