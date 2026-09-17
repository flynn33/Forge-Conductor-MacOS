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

> **Current status:** this is a 0.9.0 development snapshot. The owner now targets
> a fully functional, feature-complete, shippable build and will perform shipment
> separately. The Swift runtime, Xcode app, and built app bundle report 0.9.0
> build 1. Open qualification gates remain listed below; no source update alone
> makes this a shippable release.

The earlier signed development candidate passed a repaired live-home startup,
manager, telemetry, and native navigation check. One historical store-migration
backup was absent and remains unavailable for rollback; its completed manifest
was preserved before a new verified migration backup was created. The current
macOS 27/Xcode 27 Swift suite executed 1,553 tests with 12 explicit skips and
zero failures after the SwiftPM CLI resource-staging, fail-closed, and bounded
Autonomy completion-parser repairs.
The native
UI-automation runner previously timed out before executing its test. The live
LM Studio MCP registrations now point to the installed 0.9.0 app. Its saved
provider reached the loaded `qwen/qwen3.8-27b` model and passed the tool
contract probe. A bounded read-only managed run reached a native session and
three `fs_read` calls, but its completion request was embedded at the end of
model prose and the installed manager left it `running` after yielding. The
current source repairs that parser; native completion policy and the registered
privileged filesystem daemon still require qualification.
A separate live run in the current-source development-signed candidate
recognized the model's completion marker and correctly entered
`blocked_configuration` when the owner-only native gate policy was absent.
With a private policy bound to a disposable read-only run, the same candidate
then completed against LM Studio: the signed native XCTest package executed its
one required case with no failures or skips, `tests` passed, and the terminal
state persisted after a manager restart. This qualifies that isolated path;
the operator policy importer is now Core- and native-UI-tested, including an
exact run-bound file selection and owner-only readback; an ordinary
installed-stack terminal run and the root daemon remain open.
The current Xcode **My Mac** Debug candidate also handles the live LM Studio
desktop response in which native v1 model metadata omitted loaded instances
while native v0 reported the selected `qwen/qwen3.8-27b` model loaded. Forge
reconciled that exact model and its 262144-token context, passed the connection
probe, executed one project-bound `fs_read`, and reached its native completion
gate. After an exact policy import, Retry revalidated the persisted completion
request without another model or tool turn; one signed XCTest case passed with
zero failures or skips and the run reached `completed`. This was an isolated
candidate flow and did not replace the installed app.
The current-source signed GUI also passed focused native project registration,
live Provider save/connection/relaunch, Manager folder authorization, and
Autonomy run-start tests on macOS 27. The Manager test initially reproduced an
accessibility-label recursion crash after selecting a folder. Removing the
redundant label from the authorized-path text let the identical flow pass while
retaining its path readback and accessibility identifier.
The full signed production-onboarding class then executed seven native cases
with no skips or failures; two further exact Provider-to-Autonomy repeats passed.
An earlier full-class attempt had one live Provider probe return unreachable
before Autonomy start. The failure is retained as a non-pass and the native test
now captures provider controls and manager state if it recurs.
The repaired source is now published on owner-authored `main` at
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`. Its exact tree passed the Xcode
**My Mac** production-onboarding surface again: five environment-independent
cases passed, and the two live LM Studio cases passed separately with zero
skips after Xcode received the loopback endpoint and loaded model through the
user launch environment. The current Provider case refreshed the live model
inventory, connected, relaunched the manager, and connected again. The current
Autonomy case registered and authorized an isolated project, connected to LM
Studio, admitted the exact read-only assignment, and exercised policy import.
The same revision's GitHub source-integrity, Swift Debug/Release, and Xcode
Debug/Release jobs all passed.
The post-repair arm64 development-signed Release candidate passed strict nested
bundle checks and ZIP integrity; its retained local archive and SHA-256 are in
the [functional-build evidence](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).
The exact owner-authored published tree subsequently produced a universal
Developer ID Release archive, manual export, integrity-checked app ZIP, and
trusted-timestamp Developer ID Installer package. Strict nested signing and the
Release privileged-bundle checker pass on the archive, export, ZIP extraction,
and expanded package payload. The exact app and Installer remain unnotarized,
so Gatekeeper correctly rejects them until that separate distribution gate is
completed. Nothing was installed or shipped.

The current delivery target is a shippable build with functional product paths,
signed distinct-process filesystem evidence, Developer ID packaging,
notarization/stapling, Gatekeeper acceptance, and appropriate hardware evidence.
The earlier [functional development build](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md)
remains a historical candidate record. These release gates remain open until
tested; the owner has authorized direct `main` updates and will ship separately.

For an Xcode archive, open `ForgeConductor.xcworkspace` and select the
`ForgeConductor` scheme. Its app icon is supplied by `AppIcon.appiconset`; the
similarly named `Forge Conductor` archive uses a different bundle identifier and
has no icon. The [Xcode guide](XCODE.md) gives the archive identity and bundle
checks to run before self-distribution. The canonical archive now contains one
installable app product, with the manager CLI embedded at `Contents/Helpers`.
Ordinary Release requests Developer ID Application for James Daley's team
`9AQ2C2838M`. Xcode used a cloud-managed Developer ID certificate for that
team on a different archive. James has now installed local Developer ID
Application and Installer identities for the same team on the archive host,
enabling that exact Developer ID archive and package signing. Those identities
are now available on this current host too. The former current-source Release
exit 65 was a certificate prerequisite failure; the current patch-bound source
has since produced a universal Developer ID archive, exported app, and signed
local installer package. The exported app and package pass signature and Release
bundle checks. Xcode Organizer notarized the app, and its stapled local export
passes Gatekeeper before and after ZIP extraction. The separately signed
installer package remains unnotarized and fails Gatekeeper's install assessment.
The extracted notarized app launched with a fresh Forge home on port 7790;
Manager Start, native folder authorization/save, and disposable project
registration committed under that isolated home before bounded shutdown.
The exact published-source distribution rebuild is complete. Functional
root-service execution, exact-artifact notarization/stapling and Gatekeeper
acceptance, public-download acceptance, and the second physical-hardware case
remain open.
The newer notarized policy-import candidate also used an isolated home and
fresh port 7792. After native folder authorization and project registration,
its packaged manager saved and probed the loaded LM Studio model, admitted a
read-only run with an exact imported signed XCTest policy, and reached
`completed` with one required native case passed, zero failed/skipped, and no
timeout/truncation. The same terminal state survived a full process restart.
Its [artifact and result receipt](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md#september-16-2026-packaged-native-completion-receipt)
records the ZIP hash and qualification limits. The current installed root
service remains a separate release gate; the exact published-source archive is
now rebuilt and recorded above.
The September 16 System Settings readback showed the owner installation's
background activity off and its Manager status **Approval required**; the old
OS daemon registration also has a development signing-category constraint.
This leaves distinct-process root-service execution open despite the valid
Developer ID app export.
The final current-local-workspace archive includes the updated canonical Xcode
test-target graph; its stapled exact-code export and extracted ZIP passed local
Gatekeeper. The final unshipped ZIP SHA-256 is
`f77f63c19807be2522d245c9a6e827d0713c99a04cf76d6f14baaaaebe470b19`.
The complete September 16 current-source `swift test` terminal summary
executed 1,554 XCTest cases with 12 explicit skips and zero failures.
The final local installer product was signed with a trusted timestamp through
the Installer key's already allowed `productbuild` path; its expanded app retains
the notarized app ticket and passes nested signing and app Gatekeeper checks.
The outer package remains unnotarized and fails Gatekeeper's install assessment.
Focused Debug and signed Xcode-compiled Release Core resource stress each
passed on this 128 GiB host with injected 8 GiB limits. Another physical-memory
capacity remains unqualified. The final optimized XCTest rerun compiled the
report-failure guard, passed one selected case with zero failures, and wrote a
Release-labeled report. The functional-build receipt records its exact path,
hash, and open gates. The published revision's macOS CI Release lane retained
the guarded report and bounded host-capacity inventory and passed. That hosted
result is not counted as a second physical host.
An isolated arm64 Apple Development-signed current-source Release build passed
the `DevelopmentRelease` nested-bundle check, embedded CLI checks, and a
bounded candidate GUI/manager startup on scratch port 7789 without replacing
the installed app.
The earlier universal `0.9.0 (1)` app archive and Developer ID export remain
historical evidence for their original source. The new local Developer ID
archive/export/package and hashes are recorded in the [Xcode guide](XCODE.md).
The owner will ship only after the remaining qualification gates close.

The [qualification summary](docs/QUALIFICATION-STATUS.md) identifies the tested
source revisions, passing local scenarios, and subsequent GitHub CI repairs.
The [wiki](https://github.com/flynn33/Forge-Conductor-MacOS/wiki) is an earlier
0.9.0 snapshot; use the current repository guides for the latest setup and
qualification state until the wiki is revised.

Manager-owned runs now use [installed native completion policy](docs/NATIVE-COMPLETION.md).
Missing policy blocks completion; model-supplied hashes cannot approve a gate.
The native managed host completed one real threshold-driven rollover; exact
attachment to an existing external desktop conversation remains unsupported
without an authenticated host API.

The [native source attachment](docs/CONTINUITY-INGRESS.md#authenticated-native-source-attachment)
supports explicitly approved read-only tasks through the existing manager, with
protected credentials and checkpoint, handoff, and CLU controls.

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

## Project roadmap and delivery

The [project roadmap](ROADMAP.md) records phases, milestones, accepted evidence,
and unresolved requirements. Every direct `main` update records affected rows.
Phase closeout updates this README, the Unreleased changelog, and affected
documents. The [delivery workflow](docs/DELIVERY-WORKFLOW.md) defines local-first
edits, Xcode workspace synchronization, owner-account publication, and readback.

Current owner-directed verification covers immutable reset confirmation,
recoverable content clearing, telemetry/manager ownership, production filesystem
dispatch, writable source handoff, deterministic repeated rollover and one complete
real-provider rollover. Generation reset still preserves durable memory; it must
not be described as a flush. Existing-desktop attachment remains a separate,
unsupported host capability.

The tracking workflow in [PR #46](https://github.com/flynn33/Forge-Conductor-MacOS/pull/46)
is merged; PR #47 is also merged, and local/remote `main` equality at merge commit `d05e56a` was
rechecked September 14, 2026. The current host, signing, provider, and hardware
prerequisites are recorded in the [roadmap](ROADMAP.md#current-prerequisite-snapshot--september-14-2026).
That inventory is not a native-build or release-qualification result.

## Requirements

- macOS 26+
- Swift 6 / Xcode toolchain
- [LM Studio](https://lmstudio.ai) for running local models

## Quick start

```bash
cd /path/to/Forge-Conductor-MacOS
# Build the native workspace without changing the installed app:
xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor \
  -configuration Debug -destination 'platform=macOS' build

# Full Core/CLI/connector acceptance suite:
swift test

# CLI install (from built product or SPM release)
forge-conductor install
forge-conductor doctor
forge-conductor manager start --open   # native dashboard / manager
# LM Studio starts MCP via ~/.lmstudio/mcp.json → forge-conductor serve (Swift stdio)
```

The Debug workspace build is compilation evidence. Developer ID distribution
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

For a first managed run, register a Git repository in **Projects** with the folder picker or **Enter Project Path…** and an absolute path. Authorize that repository folder under **Manager** settings. Start the LM Studio local server, load the model variant selected in LM Studio, then save `http://127.0.0.1:1234` and its model identifier in **Provider** and run **Test Connection**. **Autonomy** starts runs after these prerequisites; the manager itself starts with the app or its LaunchAgent and is controlled from **Manager**. An idle model shown by `lms ps` can still appear unloaded to Forge when LM Studio's v1 model inventory lists a different selected variant.

For deterministic completion, select the persisted Autonomy run and use
**Import Native Validation Policy…** with a separately prepared schema-1 JSON
policy and protected signed XCTest package. Forge binds the exact run, project
generation, source, package, and gate set before installing the owner-only file;
the manager still adjudicates actual native results. See the [native completion
guide](docs/NATIVE-COMPLETION.md).

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
| **Operator app** | The native SwiftUI app exposes Rig, MCP, Agents, Tools, Feed, Projects, Autonomy, Continuity, Runtimes, Provider, Evidence, Diagnostics, and Manager surfaces. The current Apple Development-signed Release product passed coherent bundle checks and a bounded isolated launch; an earlier 100-cycle Rig/MCP result remains supporting evidence. |
| **Project memory** | Twelve `project_memory.*` tools provide bounded search, optimistic updates, links, batch writes, health, and checksummed import/export while legacy `memory_*` tools remain available. |
| **Shell** | Project shell tools are enabled on clean installs, ambiguous legacy disabled state migrates to enabled, explicit opt-out persists, and `shell_exec` retains its registered name, authorized `/bin/bash -lc` behavior, 120-second ceiling, and established result contract. Clean-profile `bash.run` is additive. |
| **Continuity** | Durable checkpoints, handoffs, successor state, fencing, and a native LM Studio provider adapter are implemented. Deterministic recovery and double-rollover tests pass, and one real-provider threshold rollover completed through successor work and stable replay. |
| **Runtime and telemetry** | Startup, settings and diagnostics export run outside the main actor with bounded operation ownership. Hidden windows and hidden ancestors stop Metal draw submission; showing the window redraws pending values. Telemetry, subprocess pipes and durable jobs remain bounded. |
| **Filesystem mitigation** | Protocol-v5 capture, bounded protected quarantine, durable receipts, and additive `fs_delete_recovery` protect regular-file, symbolic-link, empty-directory, no-replacement move, and bounded bottom-up recursive-delete operations. Every production mutation uses the separately signed helper; no same-user fallback is accepted. |

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
  `fs_delete` now dispatch through the signed-helper recovery protocol and pass
  focused in-process contract/adversarial tests; root-service execution remains
  unmeasured on this host because the registered daemon still fails its launch
  constraint check despite the Login Items service being enabled.
  Quarantine is mitigation, not elimination.
- **Native development delivery:** an earlier Apple Development-signed Release
  app, coherent nested bundle, isolated CLI checks and bounded direct GUI launch
  passed for its recorded source. The current local patch now has a universal
  Developer ID archive/export and signed installer. The stapled app ZIP passes
  local Gatekeeper execution after extraction; the installer, public-download
  acceptance, and broader UI/hardware matrix remain open for the shippable
  target.
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
  installed/native matrix and P10 exact-production
  qualification remain open.
- **Managed provider setup:** Provider now saves endpoint, model and Keychain
  credential changes through authenticated manager controls. Save supports an
  offline server; Refresh Models and Test Connection separately verify the
  saved configuration. Native v1 metadata remains authoritative; when it omits
  loaded instances, Forge can reconcile only an exact model that native v0
  reports as loaded with a valid context length. The current Xcode **My Mac**
  candidate passed live discovery, connection, project-bound tool execution,
  repaired-policy retry, and terminal completion. Installed-stack and protected
  root-service qualification remain open. A successful save or connection test
  alone does not qualify managed Autonomy.
- **Provider continuity:** one real 131,072-token threshold rollover completed
  durable handoff, exact acknowledgment, predecessor sealing, successor `fs_read`,
  output consumption, injected crash recovery and stable replay. A second attempt
  exceeded the production 600-second provider deadline during prompt processing
  and later returned `lmstudio_conflict`; it is not a second pass. An unresolved
  provider-response crash is fenced for 660 seconds. LM Studio exposes no request-ID receipt lookup; after the fence,
  each retry can create at most one duplicate model inference, and repeated
  operator or recovery retries can repeat inference. Tool-effect reconciliation
  prevents duplicate tool execution, but the inference race is not eliminated.
  Deterministic tests cover two sequential rollovers and the broader crash matrix.
- **Hardware and completion:** the broader representative physical-hardware and
  RAM-tier matrix was deferred under the functional-development acceptance
  scope; it is now open for the shippable target and is not recorded as passed.
  Compatible macOS execution, automated native tests and accurately labeled
  simulated conditions remain in scope alongside current P10/G10, G09-G12 and
  functional completion evidence.

Legacy `memory_*` and `session_*`/`context_*` tools remain compatible. Current
product behavior and qualification boundaries are in
**[CHANGELOG.md](CHANGELOG.md)**. The [package qualification ledger](.forge-codex/state/release-handoff.md)
records its own still-open evidence state and does not override current source
or executable behavior.

The historical functional development build is distinct from P10/G10
distribution qualification. Nothing in this snapshot claims filesystem
root-service E2, installer notarization, public shipment, or universal
installation.

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
