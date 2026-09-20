# Rune Forge Development Policy and Stjornarvald

This document is the current product record for the native **Development
Policy** feature, its **Rune Forge** operator surface, and the manager-owned
**Stjornarvald** policy engine. It records the reconciled implementation
boundary; unfinished work remains open in the [roadmap](../ROADMAP.md).

## Governing source

Raven Forge Development is governance and policy authority for this feature:

| Field | Bound value |
| --- | --- |
| Repository | `https://github.com/flynn33/raven-forge-development` |
| Version | `0.6.2` |
| Revision | `ed0028a46bac9c5b92876a6ad6589ca421fd9499` |
| Product baseline reconciled | `8c529924fb770b695b923f11eb5c29b26012db65` |
| Product repository | `https://github.com/flynn33/Forge-Conductor-MacOS` |

The policy repository is an external governance authority, not an application
dependency. No Raven repository, utility, example, test, or Python runtime is
copied, linked, vendored, or shipped. The product implements its own native
Swift realization and retains exact source revision, path, and locator
provenance for each built-in rule.

The Raven repository does not publish a system-realization profile for Raven
Forge Development itself. Consequently no profile-validator pass is claimed.
The issued implementation package instead supplies the pinned policy binding,
source roles, dependency prohibition, product-owned realization map,
non-interference invariants, and acceptance matrix used for this work.

## Settled behavior

- Selecting any file or folder creates an active durable policy-source identity
  before asynchronous interpretation. File type, size, encryption, or parser
  availability is never an acceptance predicate.
- Raven Forge Development remains the built-in governing policy. User-selected
  sources add project context without silently disabling it.
- A detected violation is source-linked, appended to dedicated immutable
  history, shown to the operator, and delivered as bounded additive context to
  the coding agent at a safe future boundary.
- Stjornarvald never authorizes or denies tools, changes canonical tool results,
  controls run admission or completion, stops a queue, cancels work, changes a
  project generation, or edits project source.
- Indexing, evaluation, notice delivery, mirroring, and export are bounded,
  recoverable side channels owned by the Manager. Their faults leave ordinary
  Forge startup and development operational.

## Current product-owned realization map

The package baseline predates newer instruction-artifact, completion-plan,
provider-readiness, and continuity work. The current owners below supersede any
stale patch location while preserving those newer contracts.

| Responsibility | Current owner / intended product-local change |
| --- | --- |
| Typed policy, observation, violation, notice, and export contracts | New focused files under `Sources/ForgeConductorCore/Domain/` |
| Dedicated policy database, JSONL mirror, source store, outboxes, exports, and staging | `AppPaths` plus new focused infrastructure owners |
| Process composition | `ForgeApp`; process clients may be composed here, but the manager remains the only evaluator owner |
| Manager lifecycle and single evaluator | `ManagerNode` plus a dedicated coordinator |
| Authenticated bounded operations | `ManagerRoutes`, typed operator wire models, and `OperatorManagerClient` |
| Managed coding-agent context and observations | `ManagedProjectRunStepExecutor` and post-commit `ToolInvocationBroker` seams |
| Ordinary MCP observations and notices | Post-result `ToolRouter` observation plus `MCPToolResponse` presentation decoration; canonical `ToolResult` stays unchanged |
| Operator navigation and workflow | `AppModel.AppTab`, `ContentView`, `AppSidebarView`, a dedicated view model/view, and Guided Mode |
| Build graph | Existing `ForgeConductorCore`, `ForgeConductorApp`, `ForgeConductorTests`, and app-test targets in `ForgeConductor.xcodeproj` and `Package.swift` |

## Preserved product surfaces

All 13 existing tabs, Guided Mode contexts, project generations, instruction
artifacts and queues, manager-owned autonomy, provider readiness, completion
plans, continuity, runtime jobs, telemetry, project memory, authorization,
replay, and secure-filesystem behavior remain available. Rune Forge is a new
fourteenth tab; it does not repurpose an existing destination.

## Reconciliation evidence

The September 20, 2026 reconciliation used the clean synchronized `main` source
at `8c529924fb770b695b923f11eb5c29b26012db65`, Xcode 27.0, and Apple Swift 6.4.

- `python3 scripts/validate_package.py --deep` passed all package checks: 54
  files, 11 acyclic work packages, 40 traced acceptance rows, schemas, SQLite
  append-only behavior, Swift contract type checking, and manifest integrity.
- `swift build --product forge-conductor` passed.
- `swift build --product forge-conductor-app` passed.
- `swift test --filter GuidedModeAppTests` executed 3 tests with 0 failures.
- `xcodebuild -scheme ForgeConductor -configuration Debug -destination
  'platform=macOS' build` completed with `** BUILD SUCCEEDED **` using the
  ordinary Apple Development signing identity.

This reconciliation changes documentation only. The canonical Xcode and
SwiftPM graphs are unchanged. It establishes no Stjornarvald implementation,
runtime, notice-delivery, export, or release claim by itself.

## Delivery sequence

Implementation proceeds in small tested vertical slices: typed contracts and
durable policy history; universal source catalog; pinned Raven rule adapter;
observation and violation lifecycle; managed and MCP notices; manager API and
recovery; Rune Forge UI and Guided Mode; four export formats; fault, bounds,
privacy, and performance proof; then integrated delivery acceptance.
