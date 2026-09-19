# Forge Conductor for macOS

Forge Conductor is a native Swift control plane, dashboard, and MCP server for
running project-scoped work with local models in
[LM Studio](https://lmstudio.ai).

| | |
| --- | --- |
| **Version** | **0.10.0** |
| **Build** | **2** |
| **Platform** | macOS 26 or later |
| **Toolchain** | Swift 6.2 and Xcode 26.6 or later |
| **License** | [Apache License 2.0](LICENSE) |
| **Documentation** | [Documentation guide](docs/README.md) |

> **Release status:** `0.10.0 (2)` is the current development identity. It is
> not a shipment claim. Open qualification work remains in the
> [roadmap](ROADMAP.md) and [qualification status](docs/QUALIFICATION-STATUS.md).

## What Forge Conductor does

- Connects LM Studio models to native filesystem, Git, memory, shell, and
  continuity tools through MCP.
- Keeps durable state isolated by project identity and generation.
- Runs ordered instruction packages with bounded execution and explicit gates.
- Coordinates checkpoints, handoffs, successor acknowledgement, and recovery.
- Presents native macOS controls for projects, providers, runs, telemetry,
  diagnostics, and manager lifecycle.
- Packages the GUI, CLI, runtime launcher, Core framework, and privileged
  filesystem helper as one versioned product set.

Forge Conductor does not run the model itself, silently replace the installed
application, or claim a release from a successful source build alone.

## Quick start

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

Build or test the Swift packages directly when you do not need an app bundle:

```bash
swift build --product forge-conductor
swift build --product forge-conductor-app
swift test
```

Run the repository consistency checks before committing a change:

```bash
script/check_repository_hygiene.sh
git diff --check
```

See the [Xcode guide](XCODE.md) for signing, archive identity, installation, and
distribution checks. A SwiftPM build is not a substitute for the signed Xcode
product set.

## First-run workflow

1. Start LM Studio and load a local model.
2. Open Forge Conductor and start the Manager.
3. In **Projects**, register the repository by picker or absolute path. Forge
   authorizes that exact selected folder and preserves existing authorized
   roots; the same path does not need to be entered in Manager first.
4. In **Provider**, save and test the LM Studio endpoint and selected model.
5. Add instruction packages to the registered project.
6. In **Autonomy**, select the project, enter the instructions, and choose
   **Start Task**. Forge uses the saved model plus manager-owned capability and
   completion defaults; unchanged technical defaults are omitted from the start
   request and resolved again by the Manager. Optional overrides remain under
   **Advanced**. Before admission, Forge prepares an inspectable project-bound
   descriptor covering the source snapshot, model/configuration, exact grants,
   completion checks, automatic continuity, and resource budget. Start verifies
   that descriptor again; changed inputs refresh preparation before any run is
   persisted. If a prerequisite is missing, the sheet reports an exact
   readiness state and offers the focused Projects, Model connection,
   permissions, or refresh action without submitting a run.
7. Review the run's events and evidence.

The current setup guide can be reopened from the question-mark toolbar button.
Comprehensive current-view help is tracked as an open remediation milestone.

## Project lifecycle

The **Projects** tab exposes the complete registration lifecycle:

- **Register Project…** selects a folder with the native picker.
- **Enter Project Path…** accepts a validated absolute path.
- Both registration actions authorize only the selected canonical folder and
  preserve existing authorized roots before establishing project identity.
- **Remove Selected Project…** is available below the project list and from a
  project row's context menu.
- **Relink…** reconnects the same repository identity at another location.
- **Reset Generation…** fences active work and advances the generation.
- **Clear project content** removes selected content from active retrieval.

Removing a project removes its active registration from the Projects tab and
fences the current generation. Durable project memory and historical evidence
remain available if the same repository is registered again. The app always
shows a destructive-action confirmation before removal.

## LM Studio connection

LM Studio is the MCP host. It launches Forge Conductor's `serve` command over
stdio. Forge installs primary and fallback registrations that point to the same
versioned executable with different roles.

```bash
forge-conductor version
forge-conductor install-lmstudio-plugin
forge-conductor doctor
```

Use **LM Studio MCP → Deploy to LM Studio** for the equivalent native workflow.
Detailed deployment and recovery behavior is documented in
[LM Studio connection](docs/LM-STUDIO-CONNECTION.md).

## Product surfaces

| Surface | Responsibility |
| --- | --- |
| **FORGE RIG** | Bounded CPU, GPU, memory, disk, and model-load telemetry |
| **LM Studio MCP** | MCP deployment, role health, and host synchronization |
| **Projects** | Registration, removal, generations, memory, continuity, and instruction queues |
| **Autonomy** | Manager-owned runs, budgets, gates, retries, and completion |
| **Provider** | Local endpoint, model inventory, credentials, and contract probes |
| **Manager** | Process lifecycle, authorized roots, shell policy, and filesystem service |
| **Events & Evidence** | Bounded audit events, receipts, diagnostics, and exports |

## Architecture

| Layer | Responsibility |
| --- | --- |
| `ForgeFilesystemProtocol` | Versioned privileged-helper and product identity contract |
| `ForgeConductorCore` | Domain, persistence, application services, MCP, and manager |
| `ForgeConductorApp` | Native SwiftUI operator interface and Metal gauges |
| `ForgeConductorCLI` | Install, doctor, status, manager, and MCP entry points |
| Native helpers | Runtime launcher, host adapter, and privileged filesystem daemon |

Long-lived resources have explicit owners and shutdown boundaries. Project
state is isolated by stable identity. Queues, histories, output, retries, and
rendering are bounded. See [architecture](docs/ARCHITECTURE.md) for the full
ownership and trust model.

## Versioning

The product version uses
`<release>.<feature release>.<patch or hotfix>`. `VERSION` is the repository
authority and `BUILD_NUMBER` is the bundle build authority. Runtime constants,
Xcode settings, documentation, and release notes must match both files.

See [versioning policy](docs/VERSIONING.md) for advancement rules and the
release checklist.

## Verification boundaries

A passing build proves compilation. A passing unit or UI test proves only the
tested flow. Signing, notarization, Gatekeeper acceptance, privileged-service
execution, hardware coverage, public distribution, and shipment are separate
gates.

Current results and remaining gates are recorded in:

- [Roadmap](ROADMAP.md)
- [Qualification status](docs/QUALIFICATION-STATUS.md)
- [Functional development build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md)
- [Changelog](CHANGELOG.md)

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

Historical automation packages remain retained for evidence but have no dispatch
authority. Current work follows `AGENTS.md`, `ROADMAP.md`, and
`docs/DELIVERY-WORKFLOW.md`.

## Contributions and security

External contributions are currently closed; see [CONTRIBUTING.md](CONTRIBUTING.md).
Report security issues through the process in [SECURITY.md](SECURITY.md).

Copyright and third-party notices are in [NOTICE](NOTICE).
