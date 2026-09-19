# Changelog

User-visible Forge Conductor changes are recorded here. Detailed test, signing,
artifact, and gate receipts belong in the
[roadmap](ROADMAP.md), [qualification status](docs/QUALIFICATION-STATUS.md), and
[functional-build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).

The version format is documented in [versioning policy](docs/VERSIONING.md).
Product versions do not by themselves claim shipment.

## [Unreleased]

### Added

- Added persistent contextual Guided Mode with complete offline help for all 13
  application tabs and typed guides for Start Task, task capabilities,
  completion checks, project registration/import/queue/relink/reset/clear,
  continuity actions, runtime jobs, and provider credentials.
- Added state-aware Autonomy, Continuity, Provider, and Runtimes guidance plus
  optional inline help that remains non-blocking and non-mutating.

### Changed

- Changed the persistent question-mark toolbar action from the generic setup
  slideshow to the current tab or active sheet guide while retaining the
  first-use setup guide as onboarding.
- Restored the Start Task mission field's stable accessibility identity by
  separating it from the file/folder/ZIP drop-target annotation.
- Refined Start Task into a compact project-and-instructions flow with plain
  summaries for the saved model, checkbox-selected tools, automatic completion
  checks, and automatic continuity. Raw provider, adapter, model-string,
  capability-ID, and completion-gate editors are no longer ordinary controls;
  an optional task label, typed saved-model picker, and network toggle live
  under **Customize**.
- Extracted the registered tool checkbox catalog into one reusable native
  permission editor and moved run/provider/session identifiers behind
  **Technical details** so active work, progress, continuity, completion, and
  recovery lead the run view.

- Simplified configured Autonomy start to Project and Instructions by applying
  manager-owned saved-model, registered-tool, completion-check, and continuity
  defaults; typed task-label, saved-model, and network choices remain available
  under **Customize**.
- Preserved selected run defaults across refresh and completed-run reset instead
  of requiring repeated raw tool and completion-gate entry.
- Unified direct and queued technical preparation in the Manager. Configured
  starts now omit unchanged provider/model/tool/gate/network fields, while
  explicit typed choices remain exact and fail closed when invalid.
- Added provider-configuration and canonical tool-catalog revision fencing to
  run preparation. Stale previews create no durable run and refresh automatic
  values without erasing explicit typed choices.
- Added a versioned project-bound prepared-run descriptor for direct and queued
  starts. Its revision covers the source snapshot and document references,
  provider/model configuration, exact grants, completion checks, automatic
  continuity, and project-scoped resource budget; Start revalidates it before
  durable creation and preserves exact-identity replay after a lost response.
- Added project-bound `ready`, `automatically_preparing`, `needs_choice`,
  `needs_authorization`, `waiting_dependency`, and `failed` preparation
  results with typed recovery actions. Ordinary Start now needs only Project
  and Instructions even when setup is incomplete; non-ready results submit no
  run and route recovery to the relevant native surface.
- Combined Projects registration with durable authorization of the exact
  selected canonical folder. Existing roots are preserved, parent authority is
  not widened, and legacy registration-only API requests keep their behavior.
- Replaced routine raw capability entry with a searchable registered-catalog
  editor containing native individual/category checkboxes, mixed-state **Allow
  all tools**, Select none, Restore recommended, counts, technical identifiers,
  higher-impact labels, and explicit unavailable reasons. Network authority
  remains a separate **Customize** control.
- Added owner-only saved project capability defaults with revision-checked
  updates. Explicit denials survive catalog expansion, removed or disabled tools
  are explained without being granted, Allow all follows the eligible catalog
  only for future preparations, and every run freezes its exact resolved grant.
- Replaced concatenated instruction missions with schema-2 immutable source and
  canonical-text catalogs plus bounded `instruction_catalog` and
  `instruction_read` delivery. Imports now accept content-aware UTF-8/UTF-16
  text regardless of suffix, inventory hidden files, and use native PDFKit and
  AppKit adapters for PDF, DOCX, RTF, and HTML while retaining every original.
- Raised the old 32 KiB/1 MiB/8 MiB/64-item authoring boundaries into separate
  bounded bootstrap, delivery, and import resource budgets. Opaque, malformed,
  or encrypted content remains preserved with an actionable unresolved state
  that prevents execution; legacy queue metadata migrates without losing
  package identity, ordering, or snapshots.
- Added bounded ZIP instruction import. Forge inventories the central directory,
  rejects traversal, links, encryption, unsupported compression, excessive
  expansion, and mismatched extraction results before accepting content, and
  retains nested archives without recursively expanding them.
- Unified large paste, file selection, drag/drop, and ordered-queue instruction
  admission on the immutable artifact importer. Direct artifacts are bound to
  the exact project generation and run; prepare and Start receive only a compact
  bootstrap and digest, and protected instruction reads remain run-scoped.

### Pending qualification

- Rebuild and qualify the `0.10.0 (2)` native product set.
- Complete the remaining privileged-service, notarization, Gatekeeper,
  public-download, and hardware gates recorded in the roadmap.

## [0.10.0] — 2026-09-19 (development)

### Added

- Added a visible **Remove Selected Project…** action below the Projects list.
- Added project-row context-menu removal with the same destructive confirmation.
- Added a native UI regression that registers, removes, relaunches, and confirms
  that the registration remains absent.
- Added root `VERSION` and `BUILD_NUMBER` authorities.
- Added a documented `<release>.<feature release>.<patch or hotfix>` policy.
- Added repository hygiene and version-alignment checks to local tooling and CI.
- Added a curated documentation index separating current guides from retained
  historical evidence.

### Changed

- Advanced the development product identity from `0.9.0 (1)` to `0.10.0 (2)`.
- Reworked the README into a concise product overview, setup path, project
  lifecycle, architecture map, and verification boundary.
- Reduced the changelog to user-visible changes and links to detailed evidence.
- Made the root version files drive the standalone app build script and reject
  drift from compiled or Xcode product identity.
- Kept the runtime-launch signing gate compatible with the current and legacy
  SwiftPM XCTest product identifiers without widening accepted products.
- Updated isolated build-entrypoint fixtures to exercise the root version and
  build-number authorities and reject missing or drifting values.

### Preserved behavior

- Project removal still fences the selected generation and preserves durable
  memory and historical evidence for later re-registration.
- Removal still requires an exact selected project and generation plus explicit
  operator confirmation.
- Existing project registration, relink, reset, content clearing, memory,
  continuity, and instruction-package contracts remain available.

## [0.9.0] — 2026-08-23

### Added

- Durable project-scoped memory with bounded search and migration support.
- Continuity checkpoints, handoffs, successor acknowledgement, and recovery.
- Native manager-owned autonomy, provider configuration, and runtime jobs.
- Privileged filesystem protocol and signed-helper qualification surfaces.
- Metal-backed gauges and bounded telemetry delivery.

### Changed

- Consolidated the native app, CLI, runtime launcher, Core framework, and
  filesystem daemon into one coordinated product identity.
- Expanded project generation, binding, reset, relink, and content-clear
  contracts.
- Added native completion policy and signed XCTest gate support.

### Qualification boundary

- Historical `0.9.0 (1)` build, test, signing, archive, and notarization evidence
  remains in the repository's evidence documents.
- Those receipts apply only to the exact source and artifact identities named in
  each record; they do not qualify `0.10.0 (2)`.

## [0.8.0] — 2026-08-14

### Added

- Managed runtime ownership and native host-adapter foundations.
- Project-aware filesystem, shell, memory, and continuity controls.
- Recovery-oriented diagnostics and evidence retention.

## [0.7.0] — 2026-08-01

### Added

- Native dashboard, telemetry, gauges, and manager console expansion.
- LM Studio primary and fallback MCP registration.
- Bounded process execution and audit logging improvements.

## [0.6.0] — 2026-07-31

### Added

- Durable storage, agent sessions, and continuity packet foundations.
- Native application and CLI integration.

## [0.5.3] — 2026-07

### Added

- Initial native MCP server, project tools, and LM Studio deployment path.

## Maintenance rules

- Keep one `Unreleased` section at the top.
- Record user-visible behavior, compatibility changes, migrations, and release
  boundaries; do not paste terminal transcripts into this file.
- Move detailed evidence to the roadmap or a focused document and link it here.
- Update `VERSION`, `BUILD_NUMBER`, runtime constants, Xcode settings, README,
  and active guides in the same change.
- Never rewrite a historical receipt to imply it tested a newer version.
