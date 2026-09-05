# Forge Conductor (macOS)

Native **Swift** control plane and MCP server for **local models in [LM Studio](https://lmstudio.ai)** on macOS.

Forge Conductor is purpose-built for LM Studio and its local MCP runtime.

| | |
|---|---|
| **Version** | **0.9.0** |
| **Build** | **1** |
| **User guide** | [USER-GUIDE.md](USER-GUIDE.md) |
| **Changelog** | [CHANGELOG.md](CHANGELOG.md) |
| **License** | [Apache License 2.0](LICENSE) |
| **Platform** | macOS 26+ |
| **Wiki** | [Project wiki](https://github.com/flynn33/Forge-Conductor-MacOS/wiki) |
| **Contributions** | **Closed** — see [CONTRIBUTING.md](CONTRIBUTING.md) |

> **Current status:** this is a 0.9.0 development snapshot, not a ship-authorized
> release. The Swift runtime, Xcode app, and built app bundle all report 0.9.0
> build 1. Implemented behavior and remaining release work are listed separately
> below. Package P10/G10 records remain open; this documentation does not mark
> any package gate complete.

### How LM Studio connects

LM Studio is the MCP **host**. It spawns a Forge **stdio** server:

| Executable | Argv | Role |
|------------|------|------|
| `…/Forge Conductor.app/…/Forge Conductor` | `serve` | **Default MCP** via `ForgeProcessEntry` (Deploy to LM Studio) |
| Selected app or CLI executable | `serve` + `FORGE_MCP_ROLE` | Independent primary and fallback MCP registrations |
| App (LaunchAgent) | `manager run --home …` | Dashboard manager (`install-login`) |
| App (double-click) | _(none)_ | SwiftUI GUI |

**Product path (v0.5+):** GUI → **LM Studio MCP** → **Deploy to LM Studio**. Forge transactionally writes primary + failover configuration, triggers LM Studio reload (relaunching it only if needed), verifies LM Studio synchronized the exact revision, and independently smokes both tool servers. Details: [`docs/LM-STUDIO-CONNECTION.md`](docs/LM-STUDIO-CONNECTION.md). Current product behavior and open shipment work are recorded in [CHANGELOG.md](CHANGELOG.md). The [package qualification ledger](.forge-codex/state/release-handoff.md) retains gate evidence but is not product-feature authority; historical release test plans are not current ship authority.

```bash
# After building products — does NOT write LM Studio by itself:
forge-conductor install
# Explicit deploy (same as GUI Deploy to LM Studio):
forge-conductor install-lmstudio-plugin
# GUI: LM Studio MCP tab → Deploy to LM Studio
```

No manual LM Studio configuration-file edit or restart is required. Selecting which plugins a model may use remains a per-chat LM Studio choice.

## Requirements

- macOS 26+
- Swift 6 / Xcode toolchain
- [LM Studio](https://lmstudio.ai) for running local models

## Quick start

```bash
cd /path/to/Forge-Conductor-MacOS
# Reproducible native app build, bundle staging, and launch:
./script/build_and_run.sh --verify
# Build and stage the app without launching or touching the live Forge home:
./script/build_and_run.sh --build-only

# Full Core/CLI/connector acceptance suite:
swift test

# CLI install (from built product or SPM release)
forge-conductor install
forge-conductor doctor
forge-conductor manager start --open   # native dashboard / manager
# LM Studio starts MCP via ~/.lmstudio/mcp.json → forge-conductor serve (Swift stdio)
```

The build/run script stages a development smoke bundle. Its optional build
override must equal the compiled canonical build; Developer ID distribution
uses the Xcode archive/export path. Follow the deterministic
[Xcode installation instructions](XCODE.md#install-the-exact-xcode-build) to
install the complete matching app, CLI, runtime launcher and framework.
Native CI covers source integrity, Debug/Release Swift tests, and native app/CLI
compilation. Signed UI, service lifecycle and distribution evidence remain
separate release requirements.

## What the UI shows

| Surface | Meaning |
|---------|---------|
| **FORGE RIG** | Host telemetry (CPU/GPU/RAM/disk) + LM Studio-oriented load |
| **LM Studio MCP** | LM Studio host, model backends, Forge MCP from `mcp.json` / live processes |
| **Agents / Tools / Feed** | Playbooks and tool audit for local-model agent runs |
| **Projects** | Durable project identity, generation, bindings, memory, and continuity state |
| **Autonomy / Continuity** | Manager-owned runs, provider leases, budgets, handoffs, successor acknowledgment, and fencing state |
| **Runtimes / Provider** | Effective shell policy, durable jobs, editable provider settings, redacted credentials, and contract health |
| **Events & Evidence / Diagnostics** | Bounded manager events, durable evidence references, logs, and doctor signals |
| **Manager** | Start/Stop/Restart control, authorized folders, project-shell policy, protected-filesystem service controls, maintenance, and doctor |

Only Forge-managed LM Studio runtime entries appear in these surfaces; unrelated
processes and foreign-project continuity remain excluded.

The LaunchAgent manager is the single owner of the loopback dashboard port. Opening the SwiftUI app attaches to that manager through a native typed client; it does not start a competing listener. The app uses a persistent button-based navigation column; use its toolbar button or the **Navigation** menu to show or hide it.

## Architecture

| Layer | Responsibility |
|-------|----------------|
| **Domain** | Typed models (`ForgeSnapshot`, `AppConfig`, agent sessions) |
| **Infrastructure** | SQLite, paths, process runner, PDF, audit |
| **Application** | `ForgeApp`, catalog, sessions, continuity, project memory, durable jobs, tool packs |
| **MCP** | JSON-RPC stdio for LM Studio (`tools/list`, `tools/call`) |
| **Dashboard / App** | SwiftUI + Metal gauges; optional loopback HTTP |
| **CLI** | install / doctor / serve / manager |
| **Native support** | Runtime launcher, session-host adapter, and protocol-v5 privileged filesystem helper |

State: `~/.forge-conductor` (`FORGE_CONDUCTOR_HOME` override).  
LM Studio MCP config: `~/.lmstudio/mcp.json`.  
Durable memory notes: SQLite `memory_notes` (see [docs/DURABLE-MEMORY.md](docs/DURABLE-MEMORY.md)).
Context and agent handoffs: SQLite `context_handoffs` with rebuildable JSON/Markdown projections (see [docs/CONTEXT-AGENT-CONTINUITY.md](docs/CONTEXT-AGENT-CONTINUITY.md)).

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the [project wiki](https://github.com/flynn33/Forge-Conductor-MacOS/wiki).

## 0.9.0 behavior and current qualification

The historical 0.9.0 baseline introduced durable, project-scoped memory and the
runtime reliability implementation around continuity, resource ownership,
telemetry, and local tool authorization. The current tree contains additional
work recorded under **Unreleased** in the changelog.

### Implemented and test-backed in the current tree

| Area | Implemented behavior |
|------|----------------------|
| **Product identity** | The CLI reports marketing version **0.9.0**. Swift constants, Xcode configurations, and the built app bundle report version **0.9.0**, build **1**. |
| **Operator app** | The native SwiftUI app exposes Rig, MCP, Agents, Tools, Feed, Projects, Autonomy, Continuity, Runtimes, Provider, Evidence, Diagnostics, and Manager surfaces. An earlier exact-revision Apple Development-signed 100-cycle Rig/MCP result is supporting evidence; the final current-source signed navigation and action matrix remains open. |
| **Project memory** | Twelve `project_memory.*` tools provide bounded search, optimistic updates, links, batch writes, health, and checksummed import/export while legacy `memory_*` tools remain available. |
| **Shell** | Project shell tools are enabled on clean installs, ambiguous legacy disabled state migrates to enabled, explicit opt-out persists, and `shell_exec` retains its registered name, authorized `/bin/bash -lc` behavior, 120-second ceiling, and established result contract. Clean-profile `bash.run` is additive. |
| **Continuity** | Durable checkpoints, handoffs, successor state, fencing, and a native LM Studio provider adapter are implemented and covered by deterministic recovery tests. Real-provider threshold rollover and the full crash-state matrix remain open below. |
| **Runtime and telemetry** | Startup, settings and diagnostics export run outside the main actor with bounded operation ownership. Hidden windows and hidden ancestors stop Metal draw submission; showing the window redraws pending values. Telemetry, subprocess pipes and durable jobs remain bounded. |
| **Filesystem mitigation** | Protocol-v5 capture, bounded protected quarantine, durable receipts, and additive `fs_delete_recovery` narrow and record regular-file/symlink deletion race impact. Move and recursive directory deletion remain unavailable in production. |

The [current shipping handoff](.forge-codex/state/release-handoff.md) records
exact source manifests, Debug/Release regression counts, native tests, separate
sanitizer runs and signed bundle checks. All four native production onboarding
scenarios passed, covering folder authorization, provider save/discovery and
manager restart, plus Settings shell disable/re-enable with fresh MCP processes.
These results do not qualify every feature or close the remaining release gates.

### Open or deferred before shipment

- **Filesystem E2:** the signed distinct-process 57-row matrix, durable-crash
  recovery matrix, terminal receipt/physical-leaf reconciliation, and formal
  closure remain required. Production `fs_move` and recursive directory
  `fs_delete` are currently unavailable; their hardened internal paths and
  tests are not a production capability. Quarantine is mitigation, not
  elimination.
- **Native release:** the focused signed Debug navigation test is supporting
  evidence only. Developer ID Release build, full native/settings/service
  lifecycle, archive, notarization, stapling, and Gatekeeper execution remain
  open.
- **Shell qualification:** a bounded Apple Development-signed installed-app
  scenario executed the established `shell_exec` contract through both the app
  executable and installed raw CLI. It proved clean-install enablement,
  accidental legacy-disabled migration, explicit opt-out and denial,
  `tools/list` presence, login-Bash/result compatibility, app close/reopen, and
  installed LaunchAgent manager PID replacement with predecessor exit. The
  current-source Apple Development-signed Release layout also passes raw
  installed-CLI `version`, `status`, and `doctor` with its adjacent signed
  runtime launcher. That installed-app run deliberately did not invoke System
  Events and remains partial. A separate Xcode run passed native Settings shell
  disable/re-enable and execution from fresh MCP processes. The complete
  installed/native matrix, Developer ID Release signing and P10 exact-production
  qualification remain open.
- **Managed provider setup:** Provider now saves endpoint, model and Keychain
  credential changes through authenticated manager controls. Save supports an
  offline server; Refresh Models and Test Connection separately verify the
  saved configuration. The four native onboarding scenarios passed; complete
  installed-stack and provider/autonomy qualification remain open. A successful
  save or connection test alone does not qualify managed Autonomy.
- **Provider continuity:** an unresolved provider-response crash is fenced for
  660 seconds. LM Studio exposes no request-ID receipt lookup; after the fence,
  each retry can create at most one duplicate model inference, and repeated
  operator or recovery retries can repeat inference. Tool-effect reconciliation
  prevents duplicate tool execution, but the inference race is not eliminated.
  Release authority still requires the manager-owned threshold-forced real-
  provider rollover with exact successor acknowledgment, predecessor fencing,
  automatic continuation, GUI-closed operation, and durable crash recovery.
- **Hardware and completion:** representative physical-hardware qualification
  is owner-deferred. The full clean release matrix, current package P10/G10 and
  G09-G12 evidence, and final completion validation remain open.

Legacy `memory_*` and `session_*`/`context_*` tools remain compatible. Current
product behavior and qualification boundaries are in
**[CHANGELOG.md](CHANGELOG.md)**. The [package qualification ledger](.forge-codex/state/release-handoff.md)
records its own still-open evidence state and does not override current source
or executable behavior.

No implementation, unit test, focused UI test, or synthetic-provider result in
this snapshot closes P10, G10, filesystem E2, or final release qualification.

## Design principles

1. OOP modules + DI via `ForgeApp.bootstrap`.
2. Apple-native stack (Foundation, SQLite3, Network, Metal) — no Node/Python core.
3. **LM Studio is the host** for local models; Forge is the MCP tool server + rig.
4. Durable sessions, memory notes, and context/agent handoffs in SQLite for local-model agent runs.
5. Current-source SwiftPM matrices and signed native UI execution gate release qualification; native GUI compilation alone is build evidence, not an execution pass. Xcode remains the distribution/signing project.

The historical 0.9.0 qualification snapshot is recorded in
[`.forge-codex/evidence/P12-final-validation-report.md`](.forge-codex/evidence/P12-final-validation-report.md).
It is exact older-checkpoint evidence, not authority for the current P10 tree.
Earlier audit records remain available under `docs/`.

## CLI

```
forge-conductor install
forge-conductor install-lmstudio-plugin [--binary PATH]
forge-conductor doctor
forge-conductor status
forge-conductor agents
forge-conductor serve                 # MCP stdio (LM Studio client)
forge-conductor manager run [--open]
forge-conductor manager start|stop|restart|status
forge-conductor version               # prints 0.9.0; app bundle build is 1
```

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)** for the full version history.

- **0.9.0** — Project memory, coordinated continuity, runtime ownership, and security hardening
- **0.8.0** — Automatic continuity budgets, workspace resume, and MCP presence
- **0.7.0** — Context and agent continuity (`session_*`, `context_*`), resume-ready handoffs
- **0.6.0** — Durable memory MCP tools (`memory_*`)
- **0.5.x** — LM Studio deploy path, agents, tool packs, rig / manager

## License

Copyright 2026 Jim Daley.

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

You may use, copy, modify, and redistribute this software under that license.

## Contribution policy

**No outside contributors are invited.**

Developers may use the software under the Apache 2.0 license, but must **fork** this repository or **copy** it into a **new repository** they control. Outside developers are **not** allowed to submit pull requests or otherwise alter this repository. **No pull requests will be approved.**

Full policy: [CONTRIBUTING.md](CONTRIBUTING.md).

## Sponsors

Support development of Forge Conductor and related projects:

**[Sponsor @flynn33 on GitHub](https://github.com/sponsors/flynn33)**
