# Forge Conductor for macOS

Forge Conductor is a native Swift control plane, dashboard, and MCP server for
project-scoped work performed in the normal [LM Studio](https://lmstudio.ai)
chat interface. Forge supplies ordered instructions, project tools, Development
Policy enforcement through CLU, durable project memory, and automatic
continuity. The user does not start project work through a Forge Managed Run.

| | |
|---|---|
| **Version** | **0.16.0** |
| **Build** | **19** |
| **Platform** | macOS 26 or later |
| **Toolchain** | Swift 6.2 and Xcode 26.6 or later |
| **License** | [Apache License 2.0](LICENSE) |
| **Documentation** | [Documentation guide](docs/README.md) |

> **Release status:** the current build remains unshippable until the
> owner-defined workflow in [ROADMAP.md](ROADMAP.md) passes current-candidate
> owner-machine runtime acceptance. Source compilation or a historical run is
> not release evidence. The working installation remains separate from
> candidates.

The current Apple Development-signed Desktop candidate is `Forge Conductor
0.16.0 (19)-868645e.app` with its matching `.xcarchive` on the Desktop. It is
not installed over `/Applications/Forge Conductor.app` and is not a shipment
claim.

## What Forge Conductor does

- Registers one or more project folders with stable, isolated identities.
- Imports one or more instruction packages and preserves their drag-ordered
  priority.
- Connects LM Studio models to project-scoped filesystem, Git, memory, shell,
  instruction, policy, and continuity tools through MCP.
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
   `get_forge_status`. With multiple projects, use the returned `project_id` to
   query the applicable project-file, instruction, and continuity locations.
   Then give the model the task normally.
7. CLU monitors the model, delivers policy violations with the exact applicable
   policy content, and records an exportable log for that project.
8. At context pressure the model saves a resume-ready handoff. Forge displays a
   30-second Dashboard countdown, creates exactly one stored LM Studio
   successor chat, submits `get_forge_status` with `resume=true`, verifies the
   exact handoff acknowledgement, and then seals the predecessor.
9. **Continuity** contains a scrollable project-ID list and, under the selected
   project, the actual stored checkpoint and handoff packets with packet ID,
   type, source, and timestamp. **Delete** removes only the selected packet or
   multi-selection after one confirmation. **Copy Project ID**, **Reset**, and
   **Clear Cache** remain on this surface; instruction packages remain on
   Projects.

LM Studio documents that `/api/v1/chat` creates a stored stateful chat and can
use installed MCP integrations. It does not document a guarantee that an
API-created chat becomes the foreground GUI tab. Forge does not use unsupported
private UI automation to fabricate that behavior.

Current build-19 host evidence proves the tokenless normal GUI chat path and
its Forge tool/location lookup. The tokenless automatic API successor is not
accepted: LM Studio currently returns HTTP 403 when that request attaches the
local `mcp/forge-conductor` registration. Shipment remains open until Forge can
complete the owner-defined successor flow without an operator-facing or
Forge-held LM Studio credential.

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
| **Dashboard** | Bounded telemetry, Forge activity, policy state, and the visible automatic successor countdown |
| **LM Studio MCP** | MCP deployment, role health, and host synchronization |
| **Projects** | Multi-folder registration, reset, scoped maintenance, and drag-ordered instruction-package selection and deletion |
| **Rune Forge** | Development Policy selection and ordering, CLU violation delivery, per-project history, and log export |
| **Continuity** | Scrollable project IDs plus first-class checkpoint/handoff rows, exact single/multi-packet Delete, Copy Project ID, Reset, and Clear Cache |
| **Provider** | Provider selection, connection verification, provisioning, repair, removal, and advanced LM Studio configuration |
| **Manager** | Process lifecycle, authorized roots, shell policy, and filesystem service |
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
