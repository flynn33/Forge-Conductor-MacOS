# Forge Conductor for macOS

Forge Conductor is a native Swift control plane, dashboard, and MCP server for
project-scoped work performed in the normal [LM Studio](https://lmstudio.ai)
chat interface. Forge supplies ordered instructions, project tools, Development
Policy enforcement through CLU, durable project memory, and automatic
continuity. The user does not start project work through a Forge Managed Run.

| | |
|---|---|
| **Version** | **0.17.0** |
| **Build** | **27** |
| **Platform** | macOS 26 or later |
| **Toolchain** | Swift 6.2 and Xcode 26.6 or later |
| **License** | [Apache License 2.0](LICENSE) |
| **Documentation** | [Documentation guide](docs/README.md) |

For a fresh download, open `ForgeConductor.xcworkspace` and select the
`ForgeConductor` scheme. Debug runs use automatic **Apple Development** signing
for team `9AQ2C2838M`. Release archives use **Developer ID Application** signing
on that same team and compile the distribution peer policy. The daemon's exact
signed hashes are sealed into the app and CLI before export; changing signing
classes after archiving invalidates that trust relationship. See [Xcode](XCODE.md).

<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:BEGIN -->
## Current Dashboard columns — implementation and QA complete

**0.17.0 (27)** uses two independent, equal-width column stacks: MCP Servers
above MCP Tools on the left, Sub-agents above Hot Processes on the right.
Their outer top/bottom bounds align; internal splits follow content. Hot
Processes fills the remaining right-column height. Approved Compute chips,
effects, panel content and accessibility identifiers are retained.

Thirteen public native view methods passed with zero failures/skips, and all
358 PNGs were individually reviewed. The matching My Mac Debug build and
strict signature verification passed; the canonical UI target compiled only.
[Native QA](docs/GRAPHITE-NATIVE-QA.md) records exact source/build identities, separate cache/Metal
layers and retained evidence. The frame and broader qualification records
below remain preceding checkpoints; their executions are not relabeled.
Exact owner publication and synchronization refs are recorded externally.
<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:END -->

<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:BEGIN -->
## Preceding frame refinement — source 2463aa06…

Version/build remains **0.17.0 (27)** for this Unreleased iteration. Compute
frames are smaller and darker; duplicate visible hardware names and activity
badges are removed while exact accessibility identities and states remain.
The approved chips and telemetry effects are preserved. Dashboard omits its
inline Guided Mode banner and guide button; other routes retain guidance.
Workbench Settings labels its existing action **Open Guide**. Sub-agents and
Hot Processes fill the same grid row, retaining its 200-point minimum.

The current scoped source manifest `2463aa06…` covers 434 inputs with unchanged
canonical build graph and all 30 resource files. Thirteen native view methods
passed and all 357 successful PNGs were reviewed; the one failed fixture
invocation is retained separately. The matching My Mac Debug build and strict
signature verification passed (candidate CDHash `3b5399f0…`). Separate Compute
checks, their overlapping SwiftPM repeat and exact evidence limits are recorded
in [the Compute phase record](docs/COMPUTE-CORES.md). The `28548a73…` source, 116-test/140-execution and 463-image
receipts below remain the preceding checkpoint, not fresh proof of changed
inputs. Exact owner publication and synchronization refs are recorded externally.
<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:END -->

## Preceding qualified checkpoint — 0.17.0 (27), source 28548a73…

**Preceding UI implementation and QA complete.**
0.17.0 (27) source manifest 28548a73… passed **116 distinct production tests in 140
successful executions**, with zero failures/skips. The separate native view
matrix passed **21 unique methods in 22 invocations**; all **463 selected PNGs**
were individually opened and reviewed. The 15-check/434-input audit, matching
signed Debug build and four scoped ordinary workflows passed. Historical
failures and superseded inputs remain separate. Native caches, genuine Metal
readbacks and ordinary observations retain their explicit limits; no
installation, notarization, App Store upload or distribution was performed.
Owner source/wiki publication and synchronization are complete. Exact publication
and readback refs are retained externally.

Current source is **0.17.0 (27)**. The native Graphite workspace has
Settings-first optional controls, aligned text and detailed CPU/GPU materials
from the supplied reference. Bounded Metal lighting follows valid telemetry;
missing, stale and paused states retain distinct meaning. Current selected
fixture checks, matching Debug package and four scoped ordinary workflows passed.
The current native view/control matrix and final checks passed. Exact owner publication/readback/synchronization refs are retained externally.

[Graphite Workbench](docs/GRAPHITE-WORKBENCH.md) and
[Compute Cores](docs/COMPUTE-CORES.md) record all 62 criteria/18 capture gates,
exact tested inputs, prior pixel/movie reviews and retained failed checkpoints.
The final QA mapping combines current native fixture normal/minimum views with
the signed ordinary workflows and actual native Settings/Dashboard observations. No installation, notarization, App Store Connect upload
or distribution was performed.

Current independent review opened all 463 selected view PNGs and 68 Compute layers;
the 20-frame drawable movie is separately verified. Four matching manual ordinary workflows completed:
healthy/failure paired exports (16/3 records), native folder save/cancel/root
rejection/relaunch and shell OFF/relaunch/ON with real MCP denial/execution.
Actual Settings was reviewed at 900×560 content (900×592 outer); all nine
sections, draft/Reload, six opt-ins and Setup-only persistence were observed.
Normal composed Dashboard, menus, Pause/Resume, restored preferences, native
Quit, unchanged seven registrations per case and twelve empty private suite
key sets have scoped proof. The completed current native matrix and exact limits
are recorded in [Compute Cores](docs/COMPUTE-CORES.md).

The historical October 1 Developer ID-signed Desktop candidate was
`~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID/Forge Conductor.app`,
with its matching `.xcarchive` in the same directory. For the product-path
check, the archive helper's `forge-conductor install` command copied artifacts
into `~/.forge-conductor`; its `install-lmstudio-plugin` command then wrote all
three MCP entries. Neither command installed the app into `/Applications`.
The stopped `0.16.2 (23)` app was backed up and the signed `0.16.3 (24)`
candidate was copied into `/Applications` separately. The signed `.pkg` was
built, but `installer` required root and did not install it.

The CLI staging/deploy run created synchronized primary, fallback, and
CLU revision `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`. The configured helper,
the archive's embedded helper, and the then-copied `/Applications` app's
embedded helper all had SHA-256
`49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
After the copied candidate app and LM Studio were cold-started, ordinary LM Studio
fallback PID `38508` reported an attached Jamf-Technician context. A later
replacement PID `38964` reported the same deployment-scoped client ID and
attached context; `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` then returned `ok: true` without a manual rebind. The
`mcp.json` SHA was unchanged across GUI launches. GUI **Deploy to LM Studio**
was not exercised; its source selects the running app executable, so the CLI
receipt does not qualify that path. The full scope and remaining
distribution limits are in the [qualification record](docs/QUALIFICATION-STATUS.md).

The root version authorities, compiled protocol constants, all Xcode build
configurations, and current repository documentation use `0.17.0 (27)`.
The [GitHub wiki](https://github.com/flynn33/Forge-Conductor-MacOS/wiki)
publication/readback/synchronization refs are retained externally. Installed-app
references are dated qualification snapshots; the later publication readback
found the prior `/Applications` app absent, as recorded in
[qualification status](docs/QUALIFICATION-STATUS.md). Historical
candidate receipts, including the `0.16.2 (23)` Developer ID record, retain the
identity they actually tested.

## Graphite Workbench

The native interface uses a shared graphite palette across the main window,
Settings, panels, fields, catalog rows and Metal telemetry. Provider inspection
is separate from activation: select a row to inspect it, then use its explicit
activation toggle. The main workspace opens without a global control bar.
Open **Forge Conductor → Settings…** (**⌘,**) for **Workbench** preferences:
navigation, telemetry updates and contextual guidance apply immediately.
Six independent options can show Navigation, Auto-refresh, Guided Mode, Guide,
Refresh or Guided Setup above the selected view. These shortcuts are off by
default; Navigation, Telemetry and Guide menus retain the actions.
Optional-control visibility and Guided Mode persist across relaunches;
navigation visibility and Auto-refresh retain their existing session behavior.

Manager has nine local sections: Workbench, Authorized Folders, Service, Runtime,
Settings, Project Shell, Protected Filesystem, Maintenance and Doctor. Native
Settings opens at Workbench; the main Manager entry opens at Authorized Folders.
Workbench uses the shared guide and interface state without a Save/Reload
footer. Configuration edits in the folder, settings and shell sections remain
staged until **Save settings**; **Reload from disk** explicitly replaces them.
Opening preferences or changing sections preserves those drafts. Settings uses
a larger, scrollable workspace. Earlier native preference/menu and draft-preservation
cases passed for their checkpoint inputs; Tools column geometry also passed at both sizes. Final
current-input validation is recorded in the phase evidence.

The dashboard retains all measurements and its combined **Compute Cores**
panel. Existing Projects, Continuity, Rune Forge, Runtimes, Agents, Tools,
Live Feed, Events & Evidence, Diagnostics, Guided Setup and help remain
available. Current-source behavior takes precedence over decorative controls
in the reference design. The [scope and evidence record](docs/GRAPHITE-WORKBENCH.md)
tracks final visual review separately from implementation.

## Compute Cores revision 2 — verified UI scope

The CPU/GPU materials use the supplied reference and retain its detailed frames,
grain and contacts. Bounded Metal lighting brightens and changes color with
valid telemetry. Measured logical CPU activity, host fallback, aggregate GPU
response, independent freshness, pause and native rendering failure remain
distinct states.

The signed ordinary Debug candidate matches source manifest 28548a73…; all four
scoped workflows and actual Settings/normal Dashboard observations passed.
The 116 distinct production tests, 21 native view methods and 463 reviewed
images qualify the recorded UI scope. Exact owner publication, remote readback
and synchronization references are retained externally. This phase performed
no installation, notarization or distribution.
[Graphite](docs/GRAPHITE-WORKBENCH.md), [Compute](docs/COMPUTE-CORES.md) and
[native QA](docs/GRAPHITE-NATIVE-QA.md) retain exact artifacts, capture limits,
unavailable proof classes and failed checkpoints.

## What Forge Conductor does

- Registers one or more project folders with stable, isolated identities.
- Imports one or more instruction packages and preserves their drag-ordered
  priority.
- Connects LM Studio models to project-bound native filesystem, Git, memory,
  shell, instruction, policy, and continuity tools through MCP.
- Lets the user select Development Policy files and folders in Rune Forge and
  drag-order them by importance.
- Runs CLU as the governance-enforcement agent. CLU reports the exact violated
  policy and its content to the model and keeps an exportable, bounded log for
  each project.
- Commits compact checkpoints and resume-ready handoffs, then automatically
  creates and verifies a successor LM Studio chat after a visible 30-second
  countdown.
- Presents native macOS controls for providers, projects, policy, continuity
  data, telemetry, diagnostics, and Manager lifecycle.

Forge Conductor does not run the model itself, replace the working installation
from a source build, or claim shipment from successful compilation alone.

Selected project folders establish durable project identity, generation, and
the default working directory; they are not an operating-system filesystem
sandbox. Owner-authorized filesystem, Git, shell, and runtime tools execute
natively. macOS determines TCC access from the responsible signed host and
executable in the actual launch chain; Forge does not manufacture or override a
Full Disk Access grant. After every grant or candidate change, quit and relaunch
the affected hosts and verify the exact signed candidate with a live protected-
path read that does not expose file contents. Forge still enforces project context and generation,
per-client tool grants, the shell enable switch, timeouts, output bounds,
durable result fencing, and protection against destructive root operations.
Project memory, instructions, policy, and continuity remain logically isolated
through their project-scoped APIs; unrestricted native shell access is not a
physical secrecy boundary for same-user backing files.

Runtime ownership remains bounded: native jobs have a finite descendant budget
and hard tracking cap, and unconfirmed termination becomes identity-fenced
cleanup debt rather than indefinite ownership. Local outside-project delete
and move independently rebuild protected roots and descriptor-recheck the
source at the namespace mutation boundary, closing same-user rename races while
leaving ordinary outside-project paths available.

## Current LM Studio workflow

1. Start Forge Conductor and confirm Manager is running.
2. In **Provider**, select **LM Studio** and choose **Connect and Check**. The
   pinned **LM Studio Advanced**, **Connect and Check**, and **Run Advanced
   Probe** controls use the same Manager preparation path.
3. In **Projects**, select one or more project folders.
4. Add one or more instruction files, folders, ZIPs, or packages. Drag package
   rows to set priority. **Delete Package** removes the selected package.
5. In **Rune Forge**, choose **Add Development Policy…** and select one or more
   files or folders. Drag sources to set policy priority.
6. Open a normal LM Studio chat and ask the model to call
   `get_forge_status`. The call durably attaches a new MCP deployment to the
   sole active project. With multiple projects, call it again with the returned
   applicable `project_id`; that explicit selection attaches the deployment.
   Primary, fallback, and CLU helper restarts reuse the same deployment-scoped
   client identity, so the attachment survives reconnects.
   The response also names every active Development Policy source in priority
   order, identifies the governing policy revision, requires the model to read
   and follow those sources before development changes, and returns the bound
   project's instruction packages in durable execution order with their IDs,
   names, paths, and immutable snapshot hashes. Then give the model the task
   normally.
7. CLU monitors the model, delivers policy violations with the exact applicable
   policy content, and records an exportable log for that project.
8. At context pressure the model saves a resume-ready handoff. Forge displays a
   30-second Dashboard countdown, creates exactly one foreground LM Studio
   successor chat, submits `get_forge_status` with `resume=true`, verifies the
   exact handoff acknowledgement, and then seals the predecessor.
9. **Continuity** contains a scrollable project-ID list and, under the selected
   project, the actual stored checkpoint and handoff packets with packet ID,
   type, source, and timestamp. **Delete** removes only the selected packet or
   multi-selection after one confirmation. **Copy Project ID**, **Reset**, and
   **Clear Cache** remain on this surface; instruction packages remain on
   Projects.

Forge does not use LM Studio's `/api/v1/chat` integrations array for automatic
continuity. The native host adapter uses the public macOS Accessibility surface
to activate LM Studio, press **New**, fill **Chat input**, and press **Send**.
The visible GUI-hosted model then calls the already-installed Forge MCP tool.
A deterministic nonce binds that exact tool receipt to the handoff, and durable
intent/submitted state prevents duplicate successor tabs after retry. This
requires macOS Accessibility access for the signed Forge Conductor candidate;
it does not require a Forge-held LM Studio credential.

Build-21 host evidence completed this foreground flow through
`mcp/forge-conductor-fallback`, exact handoff acknowledgement, and predecessor
sealing. Owner inspection, CLU live delivery acceptance, and shipment remain
separate.

## Projects and instruction packages

The Projects surface supports:

- multi-folder selection and validated absolute-path registration;
- multi-source instruction import;
- drag-and-drop and explicit earlier/later ordering;
- **Delete Package** for the selected package;
- project removal and relinking;
- confirmed project-generation reset;
- selective project-content clearing; and
- **Clear Cache…**, scoped to Forge's disposable cache while preserving project files,
  instructions, policy, memory, credentials, and continuity.

Instruction artifacts are immutable and content-addressed. The model discovers
their durable order through the locations and tools returned by
`get_forge_status`; package selection does not start a model session.

See [instruction packages](docs/INSTRUCTION-PACKAGES.md).

## Provider connection

The Provider surface offers mutually exclusive selection for LM Studio, Claude
Code Desktop, and Codex Desktop. Grok Build remains visible but non-selectable.

For a same-host LM Studio, **Connect and Check** authenticates only to Forge's
own Manager, uses the private loopback endpoint without an LM Studio login or
operator token, performs bounded supported-CLI recovery when the endpoint is
offline, discovers loaded models, resolves the configured model, checks the
tool contract, and saves a revision-bound readiness receipt. A legacy local
credential reference is removed from Forge configuration and Keychain. Linked
HTTPS providers retain their separate optional credential path.

Claude Code Desktop and Codex Desktop own their sessions and permission
prompts. Forge provisions only supported Forge-owned integrations and does not
automate private desktop UI.

See [provider integrations](docs/PROVIDER-INTEGRATIONS.md) and [LM Studio
connection](docs/LM-STUDIO-CONNECTION.md).

## Product surfaces

| Surface | Responsibility |
|---|---|
| **Dashboard** | Bounded telemetry and activity for the project bound to the active MCP client, policy state, and the visible automatic successor countdown |
| **LM Studio MCP** | MCP deployment, role health, and host synchronization |
| **Projects** | Multi-folder registration, reset, scoped maintenance, and drag-ordered instruction-package selection and deletion |
| **Rune Forge** | Development Policy selection and ordering, CLU violation delivery, per-project history, and log export |
| **Continuity** | Scrollable project IDs plus first-class checkpoint/handoff rows, exact single/multi-packet Delete, Copy Project ID, Reset, and Clear Cache |
| **Provider** | Provider selection, connection verification, provisioning, repair, removal, and advanced LM Studio configuration |
| **Manager** | Local section navigation for process lifecycle, selected project roots, staged settings, native shell policy, protected filesystem, maintenance and doctor |
| **Events & Evidence** | Bounded audit events and diagnostics with request, job, handoff, and connection identifiers; JSON and explicitly limited Markdown exports |

The current source records sanitized error identity and returned execution details
for failed tools. Diagnostic exports identify their selected history and disclose
when the Markdown timeline omits earlier rows. The owner-installed 0.16.4
startup failure is recorded separately; the October 3 `0.16.5 (26)` correction
added startup capture and export even when the graph cannot be constructed.

## Build and test

Open the canonical workspace and use the `ForgeConductor` scheme:

```bash
open ForgeConductor.xcworkspace

xcodebuild \
  -workspace ForgeConductor.xcworkspace \
  -scheme ForgeConductor \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Build or test the Swift packages directly when an app bundle is not required:

```bash
swift build --product forge-conductor
swift build --product forge-conductor-app
swift test
```

Run repository consistency checks before committing:

```bash
script/check_repository_hygiene.sh
git diff --check
```

See [Xcode guidance](XCODE.md) for signing, archive identity, installation, and
distribution checks. A SwiftPM build is not a substitute for the signed native
product set.

## Architecture and verification boundaries

`ForgeConductorCore` owns domain, persistence, application services, MCP, and
Manager behavior. `ForgeConductorApp` provides the native SwiftUI interface and
Metal gauges. The CLI, native session host, runtime launcher, and privileged
filesystem helper share versioned contracts. Long-lived resources have bounded
ownership and shutdown behavior; project state is fenced by stable identity and
generation.

A passing build proves compilation. A unit or UI test proves only its tested
flow. Live LM Studio behavior, signing, notarization, Gatekeeper acceptance,
privileged-service execution, hardware coverage, owner acceptance, and shipment
remain separate evidence boundaries.

Current status is recorded in:

- [Roadmap](ROADMAP.md)
- [Qualification status](docs/QUALIFICATION-STATUS.md)
- [Changelog](CHANGELOG.md)
- [Architecture](docs/ARCHITECTURE.md)

## Repository map

```text
Sources/                         Product source
Tests/                           SwiftPM, Xcode, qualification, and UI tests
ForgeConductor.xcworkspace       Canonical Xcode workspace
ForgeConductor.xcodeproj         Native product and test graph
docs/                            Current guides, contracts, and retained evidence
script/                          Direct build and repository checks
VERSION                          Product version authority
BUILD_NUMBER                     Bundle build authority
```

Historical automation packages remain retained only as evidence and have no
dispatch authority. Current work follows `AGENTS.md`, `ROADMAP.md`, and
`docs/DELIVERY-WORKFLOW.md`.

## Contributions and security

External contributions are currently closed; see
[CONTRIBUTING.md](CONTRIBUTING.md). Report security issues through
[SECURITY.md](SECURITY.md). Copyright and third-party notices are in
[NOTICE](NOTICE).
