# Changelog

All notable changes to **Forge Conductor (macOS)** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for marketing versions (`MAJOR.MINOR.PATCH`).

Current product identity is marketing version **0.9.0**, build **1**. The work
under **Unreleased** is not a new qualified release.

## [Unreleased]

This is a 0.9.0 development snapshot, not a qualified release. Product version
surfaces remain 0.9.0 build 1. P10/G10, filesystem E2, production Settings shell
qualification, Developer ID Release/native lifecycle
validation, manager-owned
real-provider autonomous continuity, owner-deferred representative physical-
hardware qualification, and current G09-G12 remain open and release-blocking.
Provider settings now have native and manager save controls. Native onboarding and disposable Keychain tests have executed; final source,
installed-stack and complete production-feature acceptance remain separate gates.

### Verified current-source evidence

- The CLI `version` output reports marketing version **0.9.0**. The Swift
  runtime constants, the versioned Xcode configurations, and the built app
  bundle report marketing version **0.9.0**, build **1**.
- The Xcode unit-test target now consumes `ForgeFilesystemProtocol` through
  `ForgeConductorCore` instead of loading a second static copy. All seven
  focused protocol tests pass without duplicate-class or decode warnings.
- Persistent sidebar controls no longer rebuild for unrelated telemetry field
  publications. An earlier exact-revision Apple Development-signed native UI
  test completed 100 Rig-to-MCP and 100 MCP-to-Rig transitions with zero
  failures. That record is supporting evidence only because this Unreleased
  tree has since changed operator navigation and must be rerun from the final
  source checkpoint.
- Focused current-source protected-filesystem and managed-provider receipt/
  recovery regressions pass. These are supporting source tests, not the signed
  E2 matrix or real-provider rollover authority run; the final source matrix
  must be rerun after all Unreleased changes settle.
- The initial September 4 source baseline passed 1,001 SwiftPM tests in both
  Debug and Release, with five declared skips. Subsequent fixes add provider,
  startup, subprocess and gauge coverage. Exact checkpoint counts and source
  identities are retained in the shipping handoff; earlier results do not
  qualify later source changes.

### Changed

- Metal renderers now stop draw submission when their window or an ancestor
  is hidden and redraw pending values when shown. Native tests measure actual
  draws, static quiescence, resource reuse and repeated object release.
- Application startup, settings reads/writes, plugin status/deployment and
  diagnostics export use bounded background operations. Delayed settings
  responses preserve newer edits and update clients only after a committed save.
- Process execution owns nonblocking stdout/stderr drains directly, bounds each
  drain turn and final capture, and continues draining during termination. This
  removes the unbounded callback-shutdown wait while preserving output limits,
  process-group cleanup and cancellation behavior.
- The operator client router now forwards provider configuration methods across
  manager replacement, so the native Save and discovery controls reach the
  authenticated manager endpoints.
- The feature qualifier includes a reviewed installed CLI version/help scenario
  bound to its recorded ordinary build, actual installation, signatures and raw
  process observations. The complete production-feature matrix remains required.
- Gate discovery preserves the pinned historical inventory. Current package
  validation reports are written under the evidence state directory so recording
  a new check does not rewrite the original package report.

- Provider request admission now rejects overlapping work before queuing
  credential payloads. Unsaved provider edits must be saved before model refresh
  or probing, so connection results correspond to the displayed saved revision.
- The native Core test bundle uses the existing development signing identity to
  match its runtime launcher. An explicit live-test budget policy supports
  threshold qualification when a provider ignores its requested load context;
  ordinary runtime defaults, exact capacity and the recovery fence are unchanged.

- Filesystem recovery now rejects terminal receipts that contradict retained
  protected entries, avoids recapturing replacement data after an interrupted
  intent, and blocks fresh mutations while a prior effect is unresolved.
  Signed recovery qualification and parent-relocation containment remain open.

- Provider controls now persist endpoint/model settings and keep, replace or clear
  Keychain credentials through authenticated manager routes. Revision checks,
  active-run admission and recoverable credential updates protect saved state;
  model discovery and connection tests remain explicit actions.
- Native onboarding tests exercise the real folder picker, offline provider
  saves and rejection, manager process replacement, and optional live-provider
  discovery. They require actual Xcode execution before acceptance.

- The development build/run script rejects inconsistent build-number overrides,
  malformed identities and unsupported invocation modes before compilation. Its
  signed optimized mode requires Apple Development and the matching development
  trust policy; Developer ID distribution uses Xcode archive/export.
- Xcode installation instructions now select one explicit build directory and
  use the supported transactional installer for the complete matching app, CLI,
  runtime launcher and framework, followed by installed-manager readback.
- Added native source-integrity, Debug/Release Swift regression and native
  app/CLI compilation CI. Documentation validation now reads the selected Git
  snapshot and rejects removed or nonregular required documents, including when
  a recreated working-tree file would otherwise conceal a staged deletion.

- Manager project and run responses now use complete shared read-model
  projections. Project bind and run start authority is limited to roots
  configured by the operator. Provider probes execute outside dashboard
  serialization with bounded admission; after a timeout, admission remains
  fail-closed until the exact provider task exits so a cancellation-ignoring
  provider cannot accumulate work. Feature operability and native
  qualification remain open.
- Added a dedicated app-hosted Xcode contract-test target and isolated shared
  scheme. It exercises the production operator client and view-model module
  boundary without changing the existing main Xcode test scheme.

- Product staging and runtime launch now enforce an explicit Security.framework
  requirement for every signed app, manager CLI, filesystem daemon, runtime
  launcher, and core framework. Team `9AQ2C2838M` is accepted only with the
  Apple Development certificate class; team `2Y25RTLZET` is accepted only with
  the Developer ID Application certificate class. The outer bundle checker
  applies the same identifier, team, Apple anchor, and certificate-class policy
  across every architecture. This closes the signer-class admission gap but
  does not establish whole-product rollback freshness or pass Developer ID,
  native lifecycle, notarization, P10, or E2 qualification.
- Added nonshipping, non-archived signed qualification-harness and adversary
  targets plus a fail-closed H0 readiness runner. H0 binds repository, recorder,
  signing, live-process, command-result, and local-APFS inode/change-time facts,
  but exercises no production mutation: all 57 E2 rows and all 12 formal
  predicates remain unexecuted and unproven. The path-replacement check is a
  local-APFS mitigation, not elimination of same-UID interference.
- Fresh configurations enable project shell tools by default. Migration enables
  schema-v1 configurations whose disabled value had no provenance; schema-v1
  could not distinguish the shipped default from a user-chosen false value.
  Explicit schema-v2 user opt-outs remain disabled. The persisted policy is exposed in the
  native Project shell settings.
- `shell_exec` retains its registered MCP name, synchronous `/bin/bash -lc`
  execution, authorization requirements, 120-second ceiling, cancellation
  behavior, and established result contract. Clean-profile `bash.run` remains a
  separate additive durable-job tool.
- Filesystem destructive paths use descriptor-relative checks plus bounded
  quarantine-and-verify around direct deletion, same-volume publication,
  cross-volume staging publication, and post-copy source removal. This is a
  mitigation, not elimination of substitution races. Rollback refuses a
  quarantine occupant that no longer matches the recorded identity. Presence
  inspection failures use JSON `null` plus a `*_presence_known=false` marker;
  conservative cleanup requirements remain Boolean. A committed publication
  whose requested namespace becomes unstable while durability is unconfirmed
  returns its live receipt as required ledger recovery, merging any additional
  retained staging-cleanup receipt into the same result.
  The move and recursive-directory paths are hardened internal implementations
  exercised by adversarial tests only in this snapshot. Production `fs_move`
  and recursive directory `fs_delete` remain unavailable until an additive
  signed-helper protocol and its recovery matrix are implemented and qualified.
- The partial privileged leaf-delete boundary now uses protocol v5 and binds
  the daemon requirement to exact per-architecture CodeDirectory hashes sealed
  into each signed caller. The app-scheme build produces one matching
  app/embedded-CLI/standalone-CLI/daemon artifact set, and app-origin manager
  installation stages only the embedded CLI plus its signed framework. Missing,
  symlinked, mismatched, or independently cross-paired artifacts fail closed.
- Protocol v5 makes successful `renameatx_np(..., RENAME_EXCL)` capture the
  mutation linearization point and records a canonical request digest plus an
  explicit `currentEntry`, `namespaceVersionExact`, or `contentVersionExact`
  contract. Production `fs_delete` uses `currentEntry`; namespace-exact recovery
  disposes only a matching captured identity; and content-exact requests fail
  closed because an existing writable descriptor, mapping, or hard link prevents
  an exclusive-writer proof. Capture mismatch and post-capture metadata changes
  enter durable protected quarantine instead of being described as eliminated.
- Protocol v5 retains terminal committed, restored, rejected, and conflicted transactions in
  32 fixed root-owned slots until durable exact acknowledgement. The additive,
  pathless `fs_delete_recovery` tool queries, resumes, or acknowledges the
  original transaction under its requester/project/generation/root authority;
  a bounded owner-only caller ledger is durable before XPC submission. Existing
  `fs_delete` and `shell_exec` contracts are unchanged.
- Privileged rollback no longer restores a captured leaf through a source-parent
  descriptor because a same-UID process can relocate that directory after it is
  validated. The daemon durably enters rollback and retains the leaf in its
  protected slot for explicit recovery. Project-generation reset now holds the
  caller-ledger lock across checks before and after entering the resetting state
  and through generation advance, failing closed when old-generation authority
  is visible. Delete retention revalidates the current project generation while
  holding that same lock, so a request delayed behind reset fails before caller
  record publication or XPC dispatch. A failed reset cancellation is surfaced
  as a distinct operator recovery error instead of being suppressed.
- Crash recovery no longer depends on reopening a user-controlled source parent
  after a protected capture exists. Persisted v5 records must recompute to their
  canonical request digest from an explicit schema-3 protocol and digest-
  canonicalization version; mixed legacy/v5 record shapes fail closed. A valid
  transaction-bound pending capture-identity receipt is published on recovery
  instead of discarded. Documented atomic-capture errors that leave both names
  unchanged, including immutable/no-unlink denial and an unrenameable mount,
  become durable rejected outcomes instead of indefinitely occupying a slot.
  A legacy
  rollback reports restored only when the source still has the exact recorded
  identity, while an absent v5 protected capture or unprovable legacy restore
  becomes a durable conflict.
- Accepted managed-provider receipts survive manager restart. An unresolved
  provider-response crash is fenced for 660 seconds before retry. LM Studio
  exposes no request-ID receipt lookup, so one retry can create at most one
  duplicate model inference per attempt and repeated operator or recovery
  retries can repeat inference. Manager reconciliation prevents duplicate tool
  execution. This mitigates the race; it does not eliminate it.
- Project registration and relink now stage bounded, owner-only recovery intents
  before control-plane mutation. A dedicated bounded
  `project_transition_authority` row, not diagnostic audit events, binds the
  exact operation, generation, root, repository identity, and directory
  device/inode in the same transaction as control state. Registration and
  relink publish aliases only after that authority is accepted, activate only
  the exact staged operation, and remove the intent only after active,
  published authority is reverified. Lost native-client responses receive one
  bounded retry using the same encoded body and captured authorization header;
  exact concurrent registration requests converge on one durable project
  identity. Restart and crash-boundary regressions cover control commit, alias
  publication, activation, response loss, intent cleanup, and two concurrent
  callers. A bounded top-level operator projection now reconstructs an exact
  registration request after a crash between intent persistence and the first
  control-plane row; it returns at most 100 intents and fails closed after a
  4,096-entry project-directory scan. Same-UID mutation of the owner-only
  recovery files or SQLite store remains outside this integrity boundary. A
  same-UID writer can also remove or coherently replace an intent, or inflate
  the directory to deny the operator snapshot. Signed native UI execution is
  still required before shipment.
- The project build entrypoint now builds and stages the manager CLI at
  `Contents/Helpers/forge-conductor`, signs it before the enclosing app, and
  performs strict signature verification of the CLI, runtime launcher,
  filesystem daemon, and app bundle. Source and focused product-path tests are
  green; an exact current-source installed, signed bundle execution remains an
  open qualification step.

### Open qualification and security boundaries

- A same-user writer can still substitute the source before exclusive capture
  or relocate the validated source parent outside the authorized root before
  capture. The latter race can make one eligible regular file or symbolic link
  outside the configured root be deleted; that file can contain unbounded
  bytes. An ineligible captured directory can quarantine an unbounded subtree.
  A same-user writer can also alter ACL/BSD authorization metadata between
  final verification and root `unlinkat`. A winning terminal race can delete
  the one captured expected regular file or symbolic link after its metadata
  changed; a regular file can
  contain an unbounded number of bytes. A pre-capture substitution can make one
  entry temporarily unavailable or recovery-required; an unsupported directory
  can represent an unbounded subtree but is not eligible for terminal deletion.
  Writable descriptors and hard links retain content residuals. The full signed
  distinct-process atomic-swap, every-durable-phase crash, recovery, volume,
  lifecycle, hard-link, and writable-descriptor matrix remains unexecuted, so
  E2 remains mandatory and release-blocking. This is mitigation, not elimination.
- Terminal-outcome receipts are not yet reconciled against every possible
  crash/corruption mismatch in the physical protected leaf. A committed,
  restored, rejected, or conflicted receipt paired with a retained leaf, or a
  quarantined receipt whose leaf is absent or has the wrong identity, must not
  be treated as truthful closure. Defining and qualifying those repair
  transitions remains release-blocking.
- Disabling automatic privileged restore prevents the known out-of-root write
  path, but it increases bounded slot availability impact: one captured entry per
  affected transaction can remain unavailable, up to the 32 protected slots per
  volume. A captured entry can be a directory substituted immediately before
  capture, so one occupied slot can isolate an unbounded subtree; the 32-slot
  limit is not a byte or descendant bound. There is not yet an independently
  authorized restore/release/purge disposition, so repeated conflicts can
  exhaust the slots and disable later protected deletes. The reset fence and
  in-lock generation check reject normal delayed
  retainers, but the caller ledger remains same-UID-owned. Hostile removal or
  relocation of an already-retained caller record can hide the sole handle from
  reset while its daemon transaction remains, allowing generation advance while
  old authority can still complete. A same-UID process can also replace the
  locked inode after a retainer validates but before slot publication, splitting
  retention from reset and permitting stale dispatch. Maximum post-reset impact
  is up to 32
  captured or terminally deleted expected leaves per protected volume; each
  regular file can contain unbounded bytes. Both rows require signed adversarial
  execution and remain part of open E2.
- The shell policy, migration, MCP registration, execution, compatibility
  contract, and restart paths pass current-source Debug and Release regressions.
  Developer Mode is enabled and Apple Development signing uses James Daley on
  team `9AQ2C2838M`. A bounded current-source signed Release installed-app run
  corrected the false-success LaunchAgent fallback and passed clean-install
  enablement, accidental legacy-disabled migration, explicit opt-out and denial,
  `tools/list`, established login-Bash/result compatibility through both the app
  and installed raw CLI, app relaunch, and installed-manager PID replacement
  with predecessor exit. The guarded run deliberately did not invoke System
  Events and restored the prior manager job, plist, command link, and launchd
  enablement state exactly. Its result remains partial: native Settings control
  and post-Settings re-enable are blocked for the Xcode XCUI lane. The installer
  now stages, signs, verifies, and commits
  the runtime launcher transactionally beside the raw CLI, embeds it in synthesized
  app layouts, and fails closed on missing or symlinked launcher payloads. A
  current-source Apple Development-signed Release smoke run also passed
  installed raw-CLI `version`, `status`, and `doctor`. Production Settings UI,
  exact current-source P10
  qualification, production folder-panel observation, privileged-service lifecycle,
  release signing, and notarization also remain deferred and release-blocking.
- Exact caller-sealed helper identity prevents helper-only substitution against
  a current caller, but it does not establish whole-product rollback freshness.
  A monotonic root-owned receipt is not implemented; a rolled-back allowlisted
  daemon retains its full bounded root mutation authority and its vulnerabilities.
  Distinct installed signed app/manager/CLI XPC, stale-helper, wrong-signer,
  approval/update/restart, and crash-recovery matrices remain unexecuted.
- An interrupted managed query/resume/acknowledge call is left ambiguous and
  blocked from replay if its exact result cannot be reconciled. Explicit
  transaction recovery remains available. An interrupted `fs_delete` whose
  previously existing path is now absent also remains ambiguous; pathname
  absence is not converted into synthetic success and the mutation is not
  redispatched. Automatic post-broker durable acknowledgement and discovery are
  not implemented. The caller recovery ledger remains under same-UID-owned
  application storage, so another same-UID process can rename or remove the
  only caller handle without gaining daemon authority. Up to 32 lost handles per
  protected volume can strand normal recovery and then make later mutations
  fail closed on capacity. This availability risk remains part of open E2.
- Historical G09 evidence covers an exact-revision, directly invoked live
  provider adapter. Current autonomous-continuity authority still requires one
  manager-owned, threshold-forced real-provider rollover proving exact successor
  acknowledgment, predecessor fencing and idempotent sealing, automatic
  continuation, GUI-closed operation, and recovery from every durable crash
  state. Unit and synthetic-host tests do not satisfy this gate.
- The managed-provider receipt fence does not prove exactly-once inference.
  Accepted receipts are restart-durable and reconciled tool effects are not
  executed twice, but an unresolved response has no LM Studio request-ID lookup.
  Retrying after 660 seconds can repeat one inference per attempt; repeated
  recovery attempts can therefore repeat inference.
- Current G09-G12 remain nonpassing. Historical compatibility, direct-adapter,
  build, unit, synthetic-host, or simulator evidence does not replace the
  current-source parity, signed native, real-provider continuity, and
  owner-deferred physical-hardware evidence required by those gates.

## [0.9.0] — 2026-08-23

### Added

- **Project-scoped memory MCP tools** — initialize, remember, batch, search, get,
  update, forget, recent-list, link, export, import, and status operations backed
  by independently managed SQLite stores.
- Checksummed project-memory import/export, deterministic bounded pagination,
  optimistic record versions, tombstones, typed links, and repository identity.
- A serialized continuity coordinator with durable checkpoints, handoffs, session
  lifecycle transitions, and a native session-host adapter plug-in.
- Resource-policy tiers, runtime diagnostics, signposts, release stress coverage,
  bounded latest-value telemetry mailboxes, and shared Metal gauge resources.
- Recovery, migration, architecture, security, and qualification evidence for the
  complete runtime repair program.

### Changed

- Marketing version **0.8.0 → 0.9.0** across the Swift runtime, Xcode targets,
  acceptance tests, README, user guide, and current architecture/status documents.
- Workspace and session paths may narrow authorization but can no longer create
  new trusted authorization roots.
- `shell_exec` is disabled by default, requires trusted local configuration when
  enabled, rejects invalid timeouts, and enforces a 120-second maximum.
- Filesystem listing is capped at 1,000 sorted entries with truncation metadata;
  text edits retain the existing 2 MiB file ceiling.
- Telemetry, process readers, dashboard connections, persistence, UI observation,
  and Metal resources now have explicit bounded ownership and shutdown behavior.

### Fixed

- Continuity rollover and restart races that could lose or duplicate transitions.
- Telemetry and gauge update paths that could retain work or perform excess
  observation/render activity.
- Persistence migration and project-memory recovery behavior under interruption,
  concurrency, corrupt input, and import/export round trips.
- Primary/fallback MCP process lifecycle and native host-adapter parity.

### Qualification

- Swift package, strict-concurrency, and Xcode unit/integration matrices each
  passed 269 tests with two intentional environment skips and no failures.
- Five native UI tests passed, including 100 navigation cycles; unsigned and
  local ad-hoc Xcode Release builds also passed.
- Address and Thread Sanitizer hosts built, but the installed platform runtime
  blocked entry into product tests, so no sanitizer pass is claimed.
- Developer ID signing, notarization, and distribution remain operator-owned.

## [0.8.0] — 2026-08-14

### Added

- **Hard context budget** — after auto-handoff (20 progress tools) or a hard identical-call loop, further filesystem/shell/git tools on that MCP client return `context_budget_exceeded` until `context_get`. Writes `memory/NEXT-CHAT.md`. LM Studio has no API to open a GUI chat; this is the enforcement.
- **Runtime continuity** — Forge checkpoints and handoffs from tool progress.
  The model no longer has to remember `session_checkpoint` / `session_handoff`.
  Default: checkpoint every 5 progress tools, handoff every 20 or 12 minutes.
- **Workspace resume** — latest handoff `cwd` / `key_files` become implicit roots.
  `context_get` adopts them for the calling client.
- **Home read-only paths** — `fs_list` / `fs_read` / `fs_glob` / `search_text` may
  read under the interactive user's home (excluding Library, ssh, and similar).
- Idle MCP **presence heartbeat** every 10s so a quiet serve stays live on the dashboard.
- Snapshot now reports real `presence` rows and `primary_alive` / `fallback_alive`.
- `shell_exec` failures persist `exit_code` / stderr in the audit error field.

### Changed

- Implement playbook includes continuity and memory tools.
- Manager heartbeat age is 0 while the manager process is alive (no longer the
  stale `manager-state.json` mtime capped at 120s).
- Soft auto-checkpoints no longer change a model packet's source, status, or
  client id, and no longer append diagnostic lines to the narrative.
- MCP server cards omit LM Studio host helpers and model backends.

## [0.7.0] — 2026-08-01

### Added

- **Context and agent continuity MCP tools** on the existing stdio server:
  - `session_checkpoint` — soft-save task context while work continues
  - `session_handoff` — finalize a resume-ready packet for a new chat
  - `context_get` — load the latest or a selected handoff packet
  - `context_list` — list recent handoff packets
- SQLite `context_handoffs` storage as the authoritative handoff record, with
  rebuildable JSON, `LATEST`, and `current-task.md` projections.
- Transactional durable-memory pointers at `continuity/latest` and
  `continuity/resume_ready`; these internal keys are hidden from default memory
  list, search, and count results.
- Agent-session snapshots and compare-and-swap reattachment so an open durable
  run can transfer safely to the resumed MCP client.
- Repeated-call context budget: the fourth identical non-continuity call writes
  a soft resume-ready handoff; the ninth is blocked after persisting the handoff.
- Process-level deployment verification for the complete continuity and durable-
  memory product tool surfaces.
- Continuity integration, recovery, multi-process, MCP, loop-budget, and
  new-chat process tests.

### Changed

- `fs_read` supports 1-based `offset` plus `length`/`limit` pagination and returns
  line-window metadata to prevent accidental full-file reread loops.
- `forge_status` reports continuity state while retaining `memory_note_count`.
- Tool auditing redacts continuity narrative, resume, decision, blocker, and
  working-set fields in addition to durable-memory bodies.
- Marketing version **0.6.0 → 0.7.0**.

### Notes

- Continuity uses the same primary/fallback mcpBridge deployment path as the
  existing tool packs; it does not add an HTTP service or sidecar.
- Opening a new LM Studio chat remains an operator/host action. The handoff
  packet and returned resume seed provide the Phase 1 bootstrap.
- Durable `memory_*` tools and their 0.6 behavior remain intact.

## [0.6.0] — 2026-07-31

### Added

- **Durable memory MCP tools** for cross-session continuity in LM Studio:
  - `memory_set` — upsert a key/value note (optional tags)
  - `memory_get` — read a note by key
  - `memory_list` — list notes (prefix/tag filters; hides agent system keys by default)
  - `memory_delete` — delete a note by key
  - `memory_search` — substring search over key, body, and tags
- SQLite-backed note storage in `memory_notes` under `FORGE_CONDUCTOR_HOME`
  (default `~/.forge-conductor/store.sqlite`)
- `MemoryNote` domain type and store list/search/count APIs
- `MemoryToolPack` wired into the tool router, authorization lifecycle allow-list,
  MCP schemas/descriptions, and telemetry pack map
- `forge_status` now reports `memory_note_count`
- Documentation: [`docs/DURABLE-MEMORY.md`](docs/DURABLE-MEMORY.md)
- Unit tests: `MemoryToolTests`

### Changed

- Marketing version **0.5.3 → 0.6.0** (minor bump for a new MCP tool surface)
- Xcode project includes `MemoryToolPack.swift` and `MemoryToolTests.swift` in the
  native targets (SwiftPM already discovered them)

### Notes

- Memory tools work **without** an active agent session and remain available
  **during** agent runs.
- Internal keys `agent_run/*` and `agent_active/*` are hidden from list/search
  unless `include_system` is true.
- Note bodies are redacted in audit logs.

## [0.5.3] — 2026-07

### Summary

- Swift control plane and MCP server for local models in LM Studio
- Primary + fallback MCP deploy path (`Deploy to LM Studio`)
- Specialist agent playbooks and durable agent sessions
- Filesystem, shell, git, search, and PDF tool packs
- Native SwiftUI + Metal rig / dashboard and LaunchAgent manager
- Apache 2.0 license and closed contribution policy

See [`docs/AUDIT-2026-07-27.md`](docs/AUDIT-2026-07-27.md) and related audits for
0.5.x verification evidence.

[0.9.0]: https://github.com/flynn33/Forge-Conductor-MacOS/compare/f47dae3...main
[0.8.0]: https://github.com/flynn33/Forge-Conductor-MacOS/commit/f47dae3354101bde0a7f0365e2ba058b18cc2c78
[0.7.0]: https://github.com/flynn33/Forge-Conductor-MacOS/compare/6fe03e0...f47dae3
[0.6.0]: https://github.com/flynn33/Forge-Conductor-MacOS/commit/6fe03e0626273ced4211ed4e1bbef8c70cfb36b8
[0.5.3]: https://github.com/flynn33/Forge-Conductor-MacOS/commit/90fc5757dbf7acf629e16184c5347760dbff4a47
