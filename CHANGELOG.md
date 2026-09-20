# Changelog

User-visible Forge Conductor changes are recorded here. Detailed test, signing,
artifact, and gate receipts belong in the
[roadmap](ROADMAP.md), [qualification status](docs/QUALIFICATION-STATUS.md), and
[functional-build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).

The version format is documented in [versioning policy](docs/VERSIONING.md).
Product versions do not by themselves claim shipment.

## [Unreleased]

### Added

- Added bounded product-event integration and RF-SJ-09 non-interference
  qualification for Stjornarvald. Ordinary tool completions, managed tool
  completions, deterministic completion claims, and Manager availability now
  emit redacted post-commit observations through one capped asynchronous queue
  and a distinct owner-only restart-safe client outbox. Manager outages,
  saturation, shutdown deadlines, and observation faults remain outside
  authorization, completion, canonical tool results, and managed run outcomes.
- Added four-format Stjornarvald policy-log export. Rune Forge now presents a
  native save panel for JSON Lines, JSON snapshots, Markdown reports, and CSV;
  exports support bounded project, generation, run, session, client, date,
  rule, state, source, event, notice, and confidence filters. Files are staged,
  synchronized, atomically installed with owner-only permissions, and paired
  with durable retry-stable receipts and explicit integrity and limitation
  metadata. Cancellation and export failure do not mutate policy history.
- Added the native Rune Forge operator workflow and Guided Mode coverage.
  Operators can select any local file or folder without a content-type
  allowlist, see the source immediately while Manager confirmation is pending,
  inspect bounded source, violation, occurrence, and notice-delivery details,
  refresh or remove sources, schedule a scan, and retain cached information
  during Manager outages. The export menu now opens the RF-SJ-08 native
  four-format save workflow.
- Added the manager-owned Stjornarvald lifecycle and typed bounded API. One
  restart-safe coordinator indexes policy sources and evaluates observations,
  while authenticated mutations, read-only snapshots and violation paging,
  durable notice reservations, process-local observation outboxes, typed
  health, and explicit degraded state keep policy faults outside ordinary
  Forge bootstrap and development control.
- Added bounded, source-linked Stjornarvald notices for managed provider turns
  and ordinary MCP tool responses. Durable delivery snapshots and receipts make
  retries stable, corrections supersede stale pending guidance, and delivery
  faults leave canonical tool results, run outcomes, and authorization unchanged.
- Added the manager-owned Stjornarvald observation and evaluation core:
  bounded idempotent observations, durable fail-forward intake, an expiring
  process/boot evaluator lease and cursor, isolated detector faults,
  condition-stable violation grouping, and automatic repeat, correction, and
  reopen history that never controls development execution.
- Added the pinned Raven Forge Development rule projection: 15 native,
  source-linked rules retain exact repository revision, policy path, and heading
  provenance; deterministic precedence records material ties as explicit
  ambiguity; the initial native-stack detector reports aligned, violation,
  ambiguous, and corrected states; and optional parity-utility failure is
  durably observed without suspending the built-in policy.
- Added the native all-format Development Policy source catalog. Every selected
  file, folder, bundle, package, archive, executable, link, zero-byte file, or
  special filesystem entry receives a durable active identity before bounded,
  restart-safe interpretation; unsupported, encrypted, partial, and
  metadata-only inputs remain cataloged instead of being rejected.
- Added the native Stjornarvald contract and persistence foundation: typed
  policy/observation/violation identities, deterministic violation grouping,
  immutable SQLite events, a digest-chained recoverable JSONL mirror,
  owner-only storage, and bounded outbox/in-memory fallback that never controls
  ordinary Forge development.
- Established the pinned Raven Forge Development 0.6.2 policy binding and
  current-source realization record for the in-progress Rune Forge Development
  Policy and Stjornarvald feature. The record fixes native ownership,
  all-format source acceptance, additive violation reporting, dedicated policy
  history, and strict non-interference boundaries without claiming runtime
  implementation.
- Added manager-owned automatic completion plans bound to the exact project
  generation and immutable instruction source. Direct and queued runs now
  persist typed, reasoned obligations for available builds/tests, read-only
  reports, artifact registration, unresolved work, and explicitly selected
  custom native policies.
- Added direct Start Task selection of existing project instruction packages,
  including ordered multi-package composition that remains usable after the
  original import paths are removed.
- Added persistent contextual Guided Mode with complete offline help for all 13
  application tabs and typed guides for Start Task, task capabilities,
  completion checks, project registration/import/queue/relink/reset/clear,
  continuity actions, runtime jobs, and provider credentials.
- Added state-aware Autonomy, Continuity, Provider, and Runtimes guidance plus
  optional inline help that remains non-blocking and non-mutating.

### Changed

- Preserved model-explicit starts for statically registered provider adapters
  that do not expose the saved Provider-settings surface, while ordinary
  minimal-input starts still require the manager-owned saved configuration and
  its revision fencing.
- Renamed the former mission-size limit as a compact bootstrap-summary budget;
  32,767-, 32,768-, 32,769-byte, multi-megabyte, and multi-document instruction
  sources remain artifact-backed rather than rejected or truncated.
- Made `instruction_read` page size responsive to the provider-reported
  remaining context and durable inline-result envelope while retaining 64 KiB
  only as an upper transport bound. Accepted catalog/read coverage continues
  through restart and managed rollover.
- Added stable-revision paging for large instruction queues and client-side page
  reconciliation, complementing the existing paged document catalog and
  completion-evidence history.
- Added explicit `unrepresented_visual_structural` accounting, page-mapped PDF
  text, native Vision OCR fallback for supported images and scanned PDFs, and
  distinct malformed-versus-encrypted conversion reports. Unsupported content
  remains preserved and prevents false ready state.
- Made bounded ZIP extraction observe task cancellation while retaining path,
  link/device, duplicate, compression, expansion-ratio, total-byte, deadline,
  staging-cleanup, and extracted-inventory protections.
- Replaced the Provider setup sequence with one cancellable, manager-owned
  **Connect and check** workflow shared by ordinary task preparation and the
  Provider view. It preserves explicit model pins, selects only a sole loaded
  compatible model automatically, performs the contract probe, persists a
  bounded revision-matched readiness receipt, and returns one typed recovery
  action when external work is required.
- Redesigned Provider to lead with model-connection readiness and moved endpoint,
  exact model, credential, inventory, and probe internals under **Advanced
  connection settings**.
- Added task-oriented runtime requirements with explicit required, optional, and
  not-needed reasons. Runtime availability now distinguishes available, not
  installed, disabled by the application-wide policy, unauthorized, failed
  probe, and unknown; job purpose and result precede technical identifiers.
- Corrected the runtime shell-policy label from project-scoped to
  application-wide, matching the persisted Manager setting it actually changes.
- Redesigned Continuity around automatic task protection. The primary view now
  shows the task, plain-language protection state, relative last-save time,
  working-context availability, and next automatic action; technical operation,
  budget, session, and handoff identities remain collapsed.
- Moved manual continuity requests under **Optional manual actions** and renamed
  them **Save progress now** and **Start a fresh session and continue** while
  preserving the existing typed manager commands and eligibility checks.
- Added a bounded project/run-scoped manager readiness projection covering
  monitoring, progress save, rollover, restore, continuation, provider wait,
  recovery, external-host limitation, and blocked states.
- Added bounded instruction-delivery state to managed continuity handoffs,
  including immutable artifact hashes, catalog coverage, byte cursors, compact
  completed-document coverage, the exact grant and completion plan, evidence,
  open work, and provider configuration revisions.
- Completed the managed successor lifecycle with strict fresh-root
  acknowledgement reconciliation, one accepted successor, predecessor fencing,
  automatic continuation, provider-exact tool fencing at rollover, and durable
  restart replay without duplicate successor effects.
- Replaced the built-in instruction-run perfect-history completion rule with
  outcome-aware obligation evidence. Corrected build/test passes supersede older
  failures, later regressions invalidate earlier passes, unrelated reads cannot
  satisfy repair work, and unresolved effects remain fail-closed.
- Paged durable completion evidence in 128-record keyset windows with a bounded
  65,536-record validation ceiling, removing the former 256-record task-failure
  limit without retaining an unbounded run history.
- Showed automatic obligation titles and reasons in Start Task and run detail,
  and moved signed custom completion-policy import behind collapsed
  **Advanced controls** so routine tasks require no policy package.
- Changed every quick-text task input, including short paste, to publish through
  the same immutable run-artifact pipeline as files, folders, ZIPs, and selected
  project packages before preparation or Start.
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
- Made prepared-run revisions cover the deterministic automatic completion plan
  and persist its ID/revision in durable run metadata. Older run and preparation
  records without the new optional plan fields remain decodable.
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

### Fixed

- Corrected integrated rollover acceptance so the sealed predecessor cannot
  issue a new tool request under rollover pressure; the acknowledged successor
  now reissues the exact pending read, records its result, and completes on the
  following provider turn.
- Updated runtime-discovery acceptance to retain an immutable configured
  executable candidate when its probe fails, reporting `probe_failed` and
  unavailable instead of erasing its path.

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
