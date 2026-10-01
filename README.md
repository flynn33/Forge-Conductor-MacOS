# Forge Conductor for macOS

Forge Conductor is a native Swift control plane, dashboard, and MCP server for
project-scoped work performed in the normal [LM Studio](https://lmstudio.ai)
chat interface. Forge supplies ordered instructions, project tools, Development
Policy enforcement through CLU, durable project memory, and automatic
continuity. The user does not start project work through a Forge Managed Run.

| | |
|---|---|
| **Version** | **0.16.3** |
| **Build** | **24** |
| **Platform** | macOS 26 or later |
| **Toolchain** | Swift 6.2 and Xcode 26.6 or later |
| **License** | [Apache License 2.0](LICENSE) |
| **Documentation** | [Documentation guide](docs/README.md) |

> **Release status:** current source is `0.16.3 (24)` and includes the MCP
> reconnect/project-binding correction from product code
> `a54100b453ba8b1c1489ff09ac64dd6193fc1597`. A fresh universal Developer ID
> archive was locally installed and cold-started through the product CLI
> installer and LM Studio deploy path on October 1. This is an installed-candidate
> proof, not notarization, stapling, Gatekeeper acceptance, public shipment, or
> release.

The retained Developer ID-signed Desktop candidate is
`~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID/Forge Conductor.app`,
with its matching `.xcarchive` in the same directory. For the product-path
acceptance run, a fresh archive was built from synchronized `main`; its
`Contents/Helpers/forge-conductor` was installed by `forge-conductor install`
into `~/.forge-conductor/bin`, then `install-lmstudio-plugin` wrote all three
MCP entries. The stopped `0.16.2 (23)` `/Applications` app was backed up and
replaced with the same signed `0.16.3 (24)` candidate for GUI cold-start proof.
The signed `.pkg` was built but the macOS package installer required root and
did not install it; no package-install pass is claimed.

The product installer/deploy run created synchronized primary, fallback, and
CLU revision `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`. The configured helper,
the archive's embedded helper, and the replacement `/Applications` app's
embedded helper all have SHA-256
`49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
After the candidate app and LM Studio were cold-started, ordinary LM Studio
fallback PID `38508` reported an attached Jamf-Technician context. A later
replacement PID `38964` reported the same deployment-scoped client ID and
attached context; `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` then returned `ok: true` without a manual rebind. The
`mcp.json` SHA was unchanged across GUI launches. The full scope and remaining
distribution limits are in the [qualification record](docs/QUALIFICATION-STATUS.md).

The root version authorities, compiled protocol constants, all Xcode build
configurations, and current repository documentation use `0.16.3 (24)`.
Historical candidate receipts, including the `0.16.2 (23)` Developer ID
record, retain the identity they actually tested.

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
| **Manager** | Process lifecycle, selected project roots, native shell policy, and filesystem service |
| **Events & Evidence** | Bounded audit events, receipts, diagnostics, and exports |

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
