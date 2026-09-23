# Forge Conductor for macOS

Forge Conductor is a native Swift control plane, dashboard, and MCP server for
running project-scoped work with local models in
[LM Studio](https://lmstudio.ai).

| | |
| --- | --- |
| **Version** | **0.12.0** |
| **Build** | **4** |
| **Platform** | macOS 26 or later |
| **Toolchain** | Swift 6.2 and Xcode 26.6 or later |
| **License** | [Apache License 2.0](LICENSE) |
| **Documentation** | [Documentation guide](docs/README.md) |

> **Release status:** `0.12.0 (4)` is the current development identity. It is
> not a shipment claim. Open qualification work remains in the
> [roadmap](ROADMAP.md) and [qualification status](docs/QUALIFICATION-STATUS.md).

The revision-3 guided-autonomy remediation is implemented across contextual
help, compact task admission, native tool selection, automatic completion,
provider/runtime preparation, durable continuity, and large instruction
packages. Integrated deterministic acceptance covers restart, provider
interruption, forced rollover, corrected completion evidence, and multi-page
instruction delivery. The Rig now adds bounded Managed Activity beside Storage,
and Rune Forge adds a verbose Policy Feed; responsive layout qualification covers
all primary views. Native distribution and shipment qualification remain separate.

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
4. Usually no Provider visit is required. **Start Task** runs the same
   manager-owned **Connect and check** workflow exposed in **Provider**: it
   resolves the saved or local-default endpoint, discovers models, preserves a
   compatible pin or selects the only compatible loaded model, performs the
   managed contract probe, and saves a revision-bound readiness receipt. When
   Forge cannot decide safely, it gives one exact action such as starting LM
   Studio, loading or selecting a model, or supplying a credential. Endpoint,
   exact model identifiers, credentials, inventory refresh, and probe details
   remain under **Advanced connection settings**.
5. Add instruction packages to the registered project. Files are admitted by
   inspected content rather than a filename whitelist. Forge preserves the
   originals, normalizes UTF-8/UTF-16 and supported native PDF, DOCX, RTF, and
   HTML text into an immutable catalog, uses bounded native Vision OCR when a
   visual source has no ordinary text representation, includes hidden files in
   folder and ZIP inventories, and reports each retained attachment,
   unrepresented visual/structural source, or unresolved conversion instead of
   dropping it.
   ZIPs are preflighted for traversal, links, encryption, unsupported
   compression, excessive expansion, and bounded size before native extraction;
   nested ZIPs are retained for separate review rather than expanded recursively.
   Large instruction bodies remain in the artifact rather than the compact run
   bootstrap summary; managed runs page them through project/run-bound read-only
   tools sized against both the transport ceiling and current provider context.
   Large queue refreshes are also loaded in stable revision-bound pages.
6. In **Autonomy**, select the project and one or more existing instruction
   packages in their displayed order, or type, paste, drop, or add a file,
   folder, or ZIP, then select **Start Task**. A single existing package keeps
   its exact stored content hash even if the original import path is gone;
   multiple packages and an optional new source become one deterministic,
   ordered run artifact. Every quick-text input, regardless of size, is also
   published through this immutable project/run-bound pipeline. Prepare and
   Start carry the artifact digest rather than the full instruction body. Forge
   uses the saved model plus manager-owned capability and completion defaults;
   unchanged technical defaults are omitted from the start request and resolved
   again by the Manager. Optional task label, saved-model
   choice, and network authority remain under **Customize**; provider/adapter,
   raw capability IDs, and raw completion-gate IDs are not routine inputs.
   **Completion Checks → Select** exposes native checkboxes for a buildable
   project, no build errors, no build warnings, available tests, complete
   instruction delivery, and no unresolved operations. **On failure** selects
   pause-for-review, bounded automatic retry, or terminal stop; an optional
   custom instruction is included in the model's managed-run context.
   Before admission, Forge prepares an inspectable project-bound
   descriptor covering the source snapshot, model/configuration, exact grants,
   a deterministic typed completion plan, automatic continuity, and resource
   budget. The plan is bound to the exact project generation and instruction
   artifact and records why each build, test, report, artifact, unresolved-work,
   or explicitly selected custom-policy obligation applies. Start verifies
   that descriptor again; changed inputs refresh preparation before any run is
   persisted. If a prerequisite is missing, the sheet reports an exact
   readiness state and offers the focused Projects, Model connection,
   permissions, or refresh action without submitting a run.
   The optional **Tools → Customize** editor is populated from the registered
   tool catalog. It supports searchable individual and category checkboxes,
   mixed-state **Allow all tools**, Select none, Restore recommended, explicit
   unavailable reasons, and saved per-project defaults. Each admitted run keeps
   the exact resolved grant and catalog revision it prepared with; later catalog
   changes apply only to future preparations.
   The **Runtimes** tab derives required, optional, and not-needed programs from
   the selected task's tools, automatic completion plan, structured project and
   instruction requirements, and runtime preferences. A missing optional Python
   or PowerShell executable does not block an unrelated Swift task. Availability
   distinguishes not installed, application-wide policy disablement, missing
   project authorization, failed probes, and unknown state; an absent path alone
   is never labeled as proof of non-installation.
   During completion, Forge evaluates the latest relevant durable result for
   each automatic obligation. A corrected build or test can supersede an earlier
   failure, while an unrelated successful read cannot complete repair work and
   unresolved effects remain fail-closed. Long run histories are read in bounded
   pages. The run detail shows the derived checks and keeps the signed custom
   policy importer collapsed under **Advanced controls** for specialized use.
   A settled task exposes **Delete Task…**. Forge confirms the action and
   deletes only a completed, cancelled, or terminally failed run whose runtime
   work is settled; project files are unchanged.
7. Review the run's events and evidence.

The run view leads with the task, current state/work, recent model and tool
activity, automatic continuity, completion, and recovery. Provider, session,
lease, project, and run identifiers remain available under **Technical details**.

For at-a-glance monitoring, **FORGE RIG** places a bounded, coalesced
**Managed Activity** projection immediately below Load Trace and Orchestration
Status. It shows the active project and instruction package, the current
inferred step plus durable delivered count, current phase/work/next action, the
durable managed LM Studio response and tool-transition feed, orchestration
events, and newest exact project/generation Rune Forge policy events. Detailed
activity text is loaded through authenticated
`GET /api/manager/operator/activity` with an exact run/project/generation
identity. The public snapshot preserves bounded, redacted mission and work-item
text plus non-sensitive state, identity, and event metadata for compatibility,
but omits current phase/next action, assistant/model-error/tool summaries, and
`managed_activity_*` rows.
Durable summaries are capped at 2 KiB and retained per run as at most 128
assistant plus 128 tool rows; the app applies an 8 KiB presentation cap while
retaining at most 100 rolling rows. Both native clients stream responses through
a 4 MiB ceiling. It is a turn-level operational view, not token streaming or a
second persisted full conversation transcript.

At normal widths, CPU shares a row with GPU and Storage shares an equalized row
with the compact Managed Activity frame; constrained widths stack those panels
vertically. The activity list scrolls internally so it does not lengthen the
entire Rig board.

The **Continuity** view leads with automatic protection for the selected task:
its plain-language state, most recent progress save, remaining working context,
and Forge's next automatic action. Active rollover activity keeps its event
timeline visible while operation identifiers, exact budget accounting, and
handoff checksums remain under **Technical details**. Routine use requires no
manual continuity action. **Optional manual actions** contains **Save progress
now** and **Start a fresh session and continue** for administrative recovery or
an intentionally early rollover.

Managed rollover handoffs retain the exact project generation, immutable
instruction-artifact hashes, bounded document catalog/read coverage, frozen
tool grant, automatic completion plan, evidence references, current open work,
and provider/adapter/model revisions. After a fresh provider root returns the
matching structured acknowledgement, Forge accepts one successor, fences the
predecessor, and automatically continues the retained assignment. Restart
recovery reuses those durable identities and does not grant a second successor.

Use the **Guided Mode** toolbar toggle to show or hide concise, state-aware
guidance in the current view. The setting persists across relaunch. The
question-mark toolbar button opens the complete offline guide for the selected
tab; help buttons inside Start Task, project registration, task capabilities,
completion checks, instruction queues, provider credentials, runtime jobs, and
project lifecycle controls open their more specific guides without changing the
underlying form or task state. The first-use setup guide remains a separate
onboarding index. See [Guided Mode](docs/GUIDED-MODE.md).

## Project lifecycle

The **Projects** tab exposes the complete registration lifecycle:

- **Register Project…** selects a folder with the native picker.
- **Enter Project Path…** accepts a validated absolute path.
- **Add Instructions…** accepts a file, folder, or bounded ZIP in its current
  format, shows
  converted document/byte counts, and prevents queue start when required source
  content remains unresolved.
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
| **FORGE RIG** | Bounded CPU, GPU, memory, disk, and model-load telemetry plus color/load status, durable instruction progress, and a redacted, exact-run Managed Activity projection for current work, managed responses, tool transitions, orchestration, and project-scoped policy events |
| **LM Studio MCP** | MCP deployment, role health, and host synchronization |
| **Projects** | Registration, removal, generations, memory, continuity, and instruction queues |
| **Rune Forge** | Native Development Policy source selection, a verbose bounded Policy Feed, violation/history inspection, delivery state, cached degraded operation, and atomic filtered policy-log export as JSONL, JSON, Markdown, or CSV |
| **Autonomy** | Manager-owned runs, selectable native completion checks, per-task failure/retry instructions, continuity, and confirmed deletion of settled task history |
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

The reconciled native design and current implementation boundary for Rune Forge
Development Policy and Stjornarvald are recorded in
[the Stjornarvald product record](docs/STJORNARVALD.md). The implementation is
complete under the package acceptance record. Its typed contracts,
fail-forward durable policy log, bounded
all-format source catalog, and pinned source-linked Raven rule projection are
now implemented. Bounded durable observation intake and single-lease native
evaluation also group repeats and append correction/reopen history. Managed
provider turns and ordinary MCP tool responses can now receive bounded additive
notices without changing canonical outcomes. The Manager now owns the single
restart-safe coordinator, typed health, bounded authenticated operations,
read-only snapshots and violation paging, retry-stable notice reservations, and
process-local observation outboxes. The native Rune Forge tab now accepts any
file or folder immediately, shows bounded sources, violations, occurrence
history, delivery state, and cached degraded information, and supplies complete
offline Guided Mode help. Its native save workflow writes filtered, bounded
JSONL, JSON, Markdown, or CSV snapshots with policy revisions, chronology,
integrity metadata, limitations, and retry-stable receipts. Product observation
hooks now emit bounded redacted post-commit observations for ordinary tools,
managed tools, completion claims, and Manager availability through a separate
durable client outbox. Delivery is nonblocking, bounded, restart-safe, and
outside authorization, completion, and canonical result paths. All 40
acceptance rows are [recorded individually](docs/RUNE-FORGE-STJORNARVALD-ACCEPTANCE.md):
39 are accepted and the accessibility row retains one explicit physical
VoiceOver validation limit. This is implementation acceptance, not a release or
shipment claim.

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

- [Adversarial pre-release audit](docs/AUDIT-2026-09-20.md)
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
