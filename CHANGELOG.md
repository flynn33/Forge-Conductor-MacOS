# Changelog

User-visible Forge Conductor changes are recorded here. Detailed test, signing,
artifact, and gate receipts belong in the
[roadmap](ROADMAP.md), [qualification status](docs/QUALIFICATION-STATUS.md), and
[functional-build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).

The version format is documented in [versioning policy](docs/VERSIONING.md).
Product versions do not by themselves claim shipment.

## [Unreleased]

### Current development line

- Version `0.14.0 (6)` is the current unreleased development identity. Its
  provider-integration, secure desktop attachment, native UI, and qualification
  changes are recorded in the development section below; no distribution or
  shipment is claimed.

### Fixed

- Fixed Swift 6 strict-concurrency diagnostics in desktop MCP tool-description
  construction and the Provider activation binding without changing the MCP
  schema, provider-selection behavior, or Xcode target membership.

## [0.14.0] — 2026-09-23 (development)

### Added

- Added mutually exclusive Provider activation for LM Studio, Claude Code
  Desktop, and Codex Desktop. LM Studio retains Forge-managed model turns;
  selectable desktop providers retain their host-selected model and session.
- Added a visible, non-selectable Grok Build compatibility card. Forge can
  inspect or remove its own staged artifacts, but does not advertise Grok as
  ready or admit Grok runs because the documented Grok startup/prompt hook
  outputs cannot deliver Forge's initial assignment context to the model.
- Added transactional Forge-owned desktop plugin, hook, skill, and MCP
  provisioning with ownership verification, compatible settings merges,
  supported-CLI JSON activation verification, rollback, repair, selective
  removal, restart reconciliation, cancellation, and a bounded redacted
  operation ledger. Generated hooks and MCP registrations share the same
  explicit Forge home.
- Made desktop removal fail closed at the host-registration boundary. When
  supported CLI/live inventory cannot verify unregister, Forge preserves its
  owned files and receipt, reports **Awaiting User Action**, and settles an
  idempotent retry only after host removal is verifiable.
- Added authenticated loopback Manager endpoints for provider snapshots,
  selection, operations, repair, removal, and bounded desktop hook events, plus
  the internal `provider-hook <provider-id> <event> --home <path>` bridge.
- Added provider-fenced desktop MCP launches and the `desktop_run_attach`
  bootstrap. Hook assignment context carries a five-minute, single-use
  capability bound to the exact provider, session, run, project generation,
  selection revision, and deployment; all other Forge tools fail closed until
  attachment, and session/run termination revokes the binding.

### Changed

- Bound Autonomy preparation and admission to the exact durable provider
  selection and verified deployment revision. Desktop runs record
  `desktop_plugin_pull` and `host-selected`; they do not activate LM Studio's
  managed-provider-push runtime or claim to own a private desktop conversation.
- Serialized provider mutations against run admission and reject selecting,
  deselecting, repairing, or removing a desktop provider until its nonterminal
  tasks are finished or cancelled, so its host hook path cannot be stranded.
- Reworked Provider into activation and operation cards while retaining LM
  Studio endpoint, model, credential, inventory, and contract-probe controls
  under **LM Studio Advanced**. Turning on LM Studio runs **Connect and Check**
  first and changes selection only after current readiness is verified.
- Made Dashboard and Guided Setup project the selected provider's readiness.
  Claude or Codex can report **HOST READY** independently of LM Studio health
  only when ready preparation, the current selection revision, and its verified
  receipt agree; stale, missing, or non-selectable evidence fails closed.
- Advanced the development identity from `0.13.0 (5)` to `0.14.0 (6)` for this
  backward-compatible provider-integration feature release. This is not a
  shipment claim, and live desktop-host acceptance remains separate.

## [0.13.0] — 2026-09-23 (development)

### Added

- Added an eight-step, state-aware **Guided Setup** wizard launched from the
  Dashboard title bar. It gives the setup order, current readiness, success
  criteria, launch choices, monitoring map, and issue-specific recovery routes
  for Manager, Provider, Projects, Autonomy, Continuity, Rune Forge, and
  Events & Evidence.
- Added bounded local LM Studio recovery to **Connect and Check**. For saved
  loopback configurations, Forge uses LM Studio's supported `lms` CLI to read
  or start the server, validates only the CLI-reported port through the normal
  authenticated inventory path, preserves explicit model and credential
  choices, and then runs the existing contract probe.
- Added current-build Doctor reporting for version/build and each LM Studio
  primary, fallback, and CLU plugin role. Stale plugin files remain visible as
  installed artifacts while Doctor offers **Deploy current build** to repair
  their executable binding.

### Changed

- Renamed the visible **Forge Rig** navigation and title surface to
  **Dashboard**, preserving its existing internal tab and accessibility
  identifiers for compatibility.
- Made Autonomy completion checks inline, selectable checkboxes. Built-in and
  preset checks now run through the manager's compiled automatic completion
  plan without an installed native policy; only instruction packages that
  explicitly declare a custom native gate use the signed-policy path.
- Preserved instruction-package tools and completion gates through single,
  imported, and ordered composite run artifacts, while merging only explicitly
  selected manager-owned automatic checks for direct runs.
- Reworked Autonomy failure guidance and Continuity protection states to show
  the exact retained condition and route recovery to Provider or Autonomy. The
  UI no longer asks users to install an unspecified gate policy or restore an
  unspecified environment.
- Removed Continuity's nested navigation container so its heading and refresh
  control stay below the toolbar and the empty operation state no longer leaves
  an unused middle frame.
- Advanced the development identity from `0.12.0 (4)` to `0.13.0 (5)` for this
  backward-compatible setup and operability feature release. This is not a
  shipment claim.

## [0.12.0] — 2026-09-23 (development)

### Added

- Added a bounded, redacted, coalesced **Managed Activity** projection directly
  below the Rig's Load Trace and Orchestration Status. It identifies the active
  project and instruction package, current inferred step and durable delivered
  count, current phase/work/next action, durable managed-model responses and
  tool transitions, orchestration events, and the newest exact
  project/generation-scoped Rune Forge policy events. Detailed activity text
  comes from an authenticated endpoint fenced by exact run, project, and
  generation. The public operator snapshot preserves bounded, redacted mission
  and work-item text plus non-sensitive state, identity, and event metadata,
  but omits current phase/next action, assistant/model-error/tool summaries,
  and managed activity rows.
  Durable activity summaries are capped at 2 KiB and retained per run as at
  most 128 assistant plus 128 tool rows. Each rolling row is independently
  content-hashed and excluded from the append-only non-activity audit lineage,
  so retention cannot create an audit-chain gap. Both native clients stream
  responses through a strict 4 MiB ceiling. The existing view-owned five-second
  refresh keeps at most 100 app-local rolling rows with an 8 KiB presentation
  cap; this surface is not token streaming and does not create a second full
  conversation transcript.
- Added a verbose **Policy Feed** to Rune Forge so operators can follow the
  newest bounded violation, repeat, evidence-update, correction, reopen, and
  interpretation events without opening each violation. Policy reporting
  remains additive and does not authorize, pause, or alter development work.
- Rebalanced the Rig so CPU/GPU and Storage/Managed Activity occupy aligned,
  equalized two-column rows at normal widths, with a compact 130-point rolling
  activity region and a vertical fallback at constrained widths. MCP,
  agent/process, Manager, Autonomy, Continuity, and Rune Forge controls now use
  adaptive layouts to avoid clipping and make better use of available space.

### Changed

- Advanced the development product identity from `0.11.0 (3)` to `0.12.0 (4)`
  for the backward-compatible Managed Activity, Policy Feed, and responsive
  primary-view layout feature release. This is not a shipment claim.

## [0.11.0] — 2026-09-21 (development)

### Added

- Added a compact Rig orchestration-status cluster beside a shortened Load
  Trace. Color and load indicators now distinguish headless LM Studio Provider
  reachability, Autonomy service activity, automatic Continuity state/context
  pressure, and selected/indexed Rune Forge policy observation. The bounded
  Manager refresh runs only while Rig is visible and Rune Forge remains
  explicitly non-interfering.
- Added confirmed deletion of one settled Autonomy task. Completed, cancelled,
  and terminally failed runs can be removed from run history through an exact
  authenticated run/project/generation request; nonterminal or unsettled work
  fails closed and project files remain unchanged.
- Added a selectable native Completion Checks catalog for buildable project,
  build errors, build warnings, tests, complete instruction delivery, and
  unresolved operations. Preset identifiers compile into typed native
  obligations; they are not treated as external executable policies.
- Added per-task failure handling for pause-for-review, bounded automatic retry,
  or terminal stop, plus bounded custom failure instructions delivered to the
  managed model. Retry exhaustion pauses for review instead of looping.
- Added a Rig project-progress indicator based on durable instruction-document
  delivery and completed instruction packages, with running, queued, complete,
  and attention states.
- Completed RF-SJ-10 integrated delivery acceptance and handoff for Rune Forge
  Development Policy and Stjornarvald. All 40 issued acceptance rows now have
  current evidence or an explicit limit; 39 are accepted, while a human
  physical VoiceOver listening session remains unperformed. Full SwiftPM,
  app-hosted, native UI, canonical Xcode build, signing, membership,
  documentation, privacy, non-interference, and repository checks are retained
  without claiming release or shipment.
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

- Advanced the development product identity from `0.10.0 (2)` to `0.11.0 (3)`
  for the backward-compatible Rig operability and Autonomy lifecycle features.
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

- Started the durable Autonomy watchdog when the Manager is hosted by the
  native GUI. The GUI previously recovered and reported the service started but
  omitted the watchdog that rediscovers yielded durable work.
- Hardened the loopback control plane after an adversarial pre-release audit.
  Session prune/close and visible Manager controls now require a per-server
  256-bit browser capability, while native clients retain the owner-only bearer
  path and the durable bearer never enters page content.
- Reclassified pending Stjornarvald notice reservation as an authenticated
  mutation because it durably changes delivery state.
- Removed an unbounded `lsof` wait/pipe-drain ordering hazard from dashboard
  port inspection and replaced it with the shared deadline- and output-bounded
  process runner.
- Hardened shipped Release targets against injected base entitlements and
  removed Release testability from the Core framework, with an Xcode graph
  regression covering every shipped Release target.
- Escaped dynamic dashboard status text, removed session identifiers from
  inline JavaScript, and made all non-2xx control responses visible as errors.
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
