# Changelog

User-visible Forge Conductor changes are recorded here. Detailed test, signing,
artifact, and qualification receipts belong in the
[roadmap](ROADMAP.md), [qualification status](docs/QUALIFICATION-STATUS.md), and
[functional-build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).

The version format is documented in [versioning policy](docs/VERSIONING.md).
Product versions do not by themselves claim shipment.

## [Unreleased]

Current source identity: `0.16.3 (24)`. Source
`a54100b453ba8b1c1489ff09ac64dd6193fc1597` produced a universal Developer ID
app and `.xcarchive`. A fresh archive was built from HEAD
`b8a2c5dee546dff8d914405c2169a075bd0187e2` for a CLI staging and LM
Studio deploy check. The signed package was built but **not installed** because
macOS required root. The `/Applications` app is a manual copy of the candidate,
not a package installation; notarization, stapling, shipment, and release
remain open.

### Added

- Added stable diagnostic record and process-instance IDs, request correlation,
  sanitized error type/domain/code and failure-stage details, and explicit JSON
  and Markdown export counts, history scope, and timeline omission notices.
  Failed search and shell diagnostics now retain returned execution or durable
  job outcomes; continuity and Dashboard failures retain available operation
  and connection identities. The installed alpha has not exercised this source.
- Produced the `0.16.3 (24)` universal Developer ID app and `.xcarchive` under
  `~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID`. The app,
  framework, CLI, runtime launcher, and filesystem daemon pass the strict
  Release privileged-bundle inspection. On October 1 a fresh candidate from
  synchronized `main` was installed by its own `forge-conductor install` and
  `install-lmstudio-plugin` commands. The former copied the helper and app to
  `~/.forge-conductor`, not `/Applications`; the latter wrote LM Studio's
  registration. The stopped `/Applications` `0.16.2 (23)` copy was backed up
  and manually replaced with a copy of the signed `0.16.3 (24)` candidate for
  the cold-start check. The CLI-deployed primary, fallback, and CLU
  entries all name the helper that matches the candidate's embedded helper at
  SHA-256 `49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
- Prepared the retained `22e7443d13496b3cc08b6e98366bb6d2332e3fd4`
  universal Developer ID Release archive and export as the shippable
  `0.16.2 (23)` owner-notarization set. The Desktop set now includes the app,
  `.xcarchive`, notary-submission ZIP, Developer ID Installer package,
  `HASHES.txt`, and command-only `OWNER-NOTARIZE.txt`. All five shipping code
  objects passed strict signing, hardened-runtime, secure-timestamp,
  architecture, entitlement, and Release privileged-bundle checks. The set is
  ready for owner notarization and Apple upload; it is not notarized, stapled,
  installed, shipped, or released.
- Replaced automatic LM Studio REST successor creation with a visible
  foreground-chat driver. After the existing 30-second countdown, Forge uses
  LM Studio's public macOS Accessibility controls to open **New**, fill
  **Chat input** with `get_forge_status`, `resume=true`, the exact handoff ID,
  and a deterministic nonce, then press **Send**. The installed GUI MCP tool
  must write the exact nonce-bound receipt before the predecessor is sealed.
- Added first-class Continuity packet inventory grouped by project ID. Packet
  rows expose the durable checkpoint/handoff ID, type, source, and timestamp,
  and support exact single or multi-selection deletion after one confirmation.
- Kept **Copy Project ID**, **Reset**, and **Clear Cache** directly on
  Continuity. Reset now clears only project-scoped settled continuity history;
  it no longer delegates to the Projects generation reset. Instruction-package
  selection and deletion remain on Projects.

### Fixed

- Corrected `fs_read` so only an observed missing-file POSIX error returns
  `not_found`; permission, nonregular-file, invalid-text, and unclassified
  failures retain distinct codes and their original error identity.
- Corrected the diagnostic export that declared all selected records while
  silently rendering only the last 2,000 Markdown rows. Earlier rows are now
  counted and disclosed, and existing redaction markers survive reload.
- Fixed LM Studio project tools becoming unusable after an MCP helper restart.
  `forge_status` and `get_forge_status` now idempotently attach an unseen MCP
  deployment to an explicit `project_id`, or to the sole active project when
  selection is unambiguous, and report the result in `project_context`.
  Primary, fallback, and CLU helpers share a bounded deployment-scoped client
  identity instead of minting an unbounded UUID per process, so filesystem,
  instruction, shell, Git, runtime, memory, and continuity tools retain their
  durable binding across reconnects. Deliberately invalidated generation-reset
  bindings remain fenced and multi-project selection remains explicit. The
  Dashboard tracker consumes the same restored binding. Instruction catalog
  and read access now accept that project-generation binding directly instead
  of incorrectly requiring an unrelated Managed Run. The working LM Studio
  primary, fallback, and CLU registrations now target the installed v0.16.3
  helper under revision `6b6aa0b4-c3bd-454b-96e4-1273abf390f1`. After a cold
  Forge and LM Studio restart, a new LM Studio chat launched hosted fallback
  PID `33715`; its first `get_forge_status(project_id)` reported v0.16.3 and
  `project_context.attached == true` for deployment-scoped client
  `lm-studio:12ec4eaf…`. Its next four calls—`fs_list`, `git_status`,
  `instruction_catalog`, and `continuity.status`—all succeeded without a
  second bind or `project_context_required` response. The registered project
  alias and Git both resolve Jamf-Technician to
  `/Users/flynn/GitHub/Jamf-Technician`.
  A subsequent CLI staging/deploy run, not a `.pkg` installation, produced revision
  `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`. After the copied candidate app
  and LM Studio cold-started, hosted fallback PIDs `38508` and `38964`
  reported the same client `lm-studio:faf23139…` with an attached project.
  The replacement process's filesystem, Git, instruction, and Continuity calls
  each returned `ok: true` without a manual rebind. The registration file was
  unchanged by either GUI launch. GUI Deploy was not exercised and its source
  prefers the running app executable; the signed `.pkg` was not installed.
  Neither path is qualified by the CLI receipt, and no notarization or
  public-release acceptance is implied.
- Corrected ordinary LM Studio bootstrap so `get_forge_status` returns the
  pinned Development Policy identity, every active Rune Forge source path in
  durable priority order, the supported read tools, and an explicit required
  action to read and follow all applicable policy requirements before making
  development changes. The additive response preserves existing project,
  instruction, continuity, and resume fields. The status now also returns the
  bound project's durable instruction-package execution order with package
  IDs, display names, source paths, positions, and immutable snapshot hashes.
  Policy location and the mandatory action remain visible when project
  selection is ambiguous. The live Jamf-Technician LM Studio chat consumed the
  Developer ID build-23 candidate through final repeated fallback PID `12436` and returned
  the complete contract. That retained candidate identity is `0.16.2 (23)`.
- Restored native host access for filesystem, search, PDF, Git, shell, and
  runtime tools by removing Forge's per-command Seatbelt wrapper and
  project-root path confinement. Selected project folders now provide durable
  identity, generation, and the default working directory. macOS evaluates
  TCC, POSIX, and SIP access for the responsible signed code objects in the
  actual launch chain; an exact signed-candidate protected-path probe is the
  required Full Disk Access proof. Tool grants, the shell enable switch, canonicalization, deadlines,
  output bounds, durable result fencing, and destructive-root protections
  remain enforced.
- Added a bounded, start-identity-fenced descendant tracker for native runtime
  jobs. It observes and terminates children that leave the launch process group
  with `setsid(2)` or `setpgid(2)`, while retaining the existing launch gate,
  process-group cleanup, deadline, and output limits. The ordinary per-job
  descendant budget is 16 and retained identities have an absolute 1,024-entry
  cap; either budget overflow becomes a typed terminal failure. Capacity
  overflow remains explicit evidence but cannot keep a job artificially live
  after every retained identity exits. An unconfirmed termination persists a
  bounded cleanup debt with one identity-fenced startup retry, and PID reuse is
  never treated as authority to signal the replacement process. Public macOS
  process snapshots are not atomic, so adversarial same-user code that forks,
  reparents, and exits entirely between observations remains part of the
  explicit native shell trust boundary rather than a claimed sandbox guarantee.
- Hardened native local `fs_delete` and `fs_move` root protection against same-user
  rename races. The execution boundary independently rebuilds the protected
  filesystem, mounted-volume, user-home, Manager-home, and workspace-root set,
  pins the source by descriptor identity, and rechecks that identity against
  every protected root and ancestor immediately before namespace mutation.
  Blank operands, case aliases, changed parents, and inspection failure all
  fail closed without turning ordinary outside-project paths into a sandbox.
- Corrected Dashboard project tracking to resolve live MCP presence through its
  active durable `mcp_client` binding. Recent live activity wins when more than
  one client is connected, a matching nonterminal run is only a fallback, and
  a merely registered project is no longer presented as active.
- Aligned the root version authorities, compiled protocol constants, all Xcode
  configurations, and current user/developer documentation at `0.16.1 (22)`.
  Historical evidence retains the version and build it actually tested.
- Advanced the candidate identity to `0.16.0 (21)`. Durable GUI dispatch state
  records `intent` before any host effect and `submitted` after Send, so retry
  and Manager restart reuse one logical successor instead of opening a stack.
  Electron accessibility-name mapping accepts the observed New button through
  title, description, or value.
- Advanced the candidate identity to `0.16.0 (19)`. Same-host LM Studio now
  rejects new Forge credential values, automatically removes any legacy local
  Keychain reference, and hides credential controls for the local endpoint.
  Linked HTTPS provider credentials remain supported.
- Corrected packet JSON encoding so `project_id` is a UUID string at the
  Manager boundary instead of a synthesized nested value.
- Corrected optimized Release packet decoding so the signed app and its
  embedded LM Studio MCP helper list the same durable checkpoint/handoff rows
  that Debug builds expose. Packet IDs retain their strict bounded ASCII
  alphabet and malformed JSON scalar/container types remain rejected.
- Kept registered projects visible on Continuity when automatic continuity is
  idle or unavailable, because durable packets remain operator-manageable after
  the automation state that created them is no longer active.
- Preserved the operator's existing Forge-owned LM Studio `mcp.json`, manifest,
  and bridge-definition inputs around live-provider UI tests so a disposable
  test home cannot remain registered after success or assertion failure.

### Verification

- The Development Policy bootstrap selection executed 86 Forge tests plus one
  filesystem version-contract test with zero failures. The canonical Xcode
  Core target executed the exact status regression 1/1; both SwiftPM products
  and the ordinary signed Debug app build passed. A direct build-23 Debug
  candidate-helper probe against the live Jamf Technician binding returned the
  active priority-1 policy path
  `/Users/flynn/Projects/raven-forge-development-main`, governing revision,
  supported read tools, and required read/follow instruction. A prior
  app-hosted filter selected zero tests and is not counted. Fresh LM Studio
  model acceptance with the published build-23 helper remains open.
- The complete focused `CoreTests` selection executed 49 tests with zero
  failures. Dashboard operational-snapshot tests executed 23 tests with zero
  failures, including live-binding preference and the registered-only negative
  case. The 103-test runtime-job suite exercised every available runtime profile
  with an external working directory, `/bin/ps`, inherited environment state,
  and cleanup of an observed `setsid(2)` child. The 100-test secure-filesystem
  suite also passed, including blank destructive-path rejection and native
  outside-project delete/move behavior. The final integrated SwiftPM suite
  executed 1,933 tests with 12 explicit environment-dependent skips and zero
  failures; both SwiftPM products, the app-hosted 23-test Dashboard selection,
  and the canonical Debug workspace build also passed.
- Exact implementation revision `91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`
  produced the retained universal Developer ID candidate `Forge Conductor
  0.16.1 (22)-91ad90e-DeveloperID`. Strict nested signature validation passed
  for the app, CLI, runtime launcher, Core framework, and filesystem daemon;
  every code object carries team `9AQ2C2838M`, hardened runtime, a secure
  timestamp, and no App Sandbox entitlement. The candidate MCP helper reported
  `filesystem_sandbox_mode=none` and
  `filesystem_path_confinement=false`, read a protected Mail path without
  disclosing its content, executed `/bin/ps`, Git, outside-project filesystem
  operations, and a runtime job, and returned the exact bound project from
  `get_forge_status`. Gatekeeper assessment exited 3 with
  `source=Unnotarized Developer ID`; notarization, stapling, Gatekeeper
  acceptance, and shipment therefore remain open. The working installation
  was not replaced.
- Developer ID-signed Desktop candidate `Forge Conductor 0.16.0
  (21)-a540670.app` completed one live disposable rollover. Handoff
  `79474019-000f-4395-a593-cc74a6da2372` showed the 30-second countdown, opened
  selected foreground tab `Forge Rollover Successor Proof`, submitted the exact bootstrap, and
  visibly called `get_forge_status mcp/forge-conductor-fallback`. Exact receipt
  nonce `517cbb4f-f1bd-cc69-e1df-f14ffc7f5f9c` acknowledged at
  `2026-09-28T10:06:48Z`; logical successor
  `51a4567d-36f9-4d44-8a54-925f6e14a0f5` reached `acknowledged`, and the seal
  ledger then recorded the handoff once. A delayed watchdog check retained one
  successor record. No `/api/v1/chat` integrations request participated.
  The live chat's already-running fallback MCP child came from the compatible
  build-20 registration; after the proof, the supported installer synchronized
  primary, fallback, and CLU registrations to the exact build-21 candidate.
- Focused tests execute the packet store's list and exact batch-delete behavior,
  packet wire format, populated native packet rows, and confirmed packet-only
  deletion. Provider configuration tests execute local credential migration and
  rejection. The universal Apple Development-signed build-19 Desktop candidate
  passed its exact-path owner-surface test and real-provider test: same-host
  Connect and Check plus Run Advanced Probe succeeded before and after relaunch
  with `credentialConfigured=false`, with no loopback token field or credential
  action. Two exact-candidate UI runs deleted only two disposable packets from
  the live 75-packet inventory and retained all 73 pre-existing packet IDs. A
  focused multi-selection case deleted exactly two selected IDs in one request
  and retained the unselected row. Automatic LM Studio rollover acceptance
  remains required before shipment. A fresh foreground LM Studio GUI chat did
  successfully call `get_forge_status`, `context_get`, and memory tools through
  the candidate registration without a Forge-held LM Studio credential and
  returned the live project and continuity locations.

## [0.16.0] — 2026-09-27 (build 15 owner-workflow correction)

### Added

- Replaced the primary Managed Run workflow with ordinary LM Studio chat use:
  `get_forge_status` now accepts `project_id`, lists registered projects without
  a run binding, and returns project-file, instruction-store, continuity-store,
  and query-tool locations.
- Added automatic ordinary-chat continuity. A resume-ready handoff publishes a
  visible 30-second Dashboard countdown, then creates one stored LM Studio chat
  through `/api/v1/chat`, enables `mcp/forge-conductor`, submits
  `get_forge_status` with `resume=true`, verifies the exact handoff ID, and
  reuses the durable host-adapter ledger across retries.
- Added multi-folder project selection, multi-source instruction import,
  drag-and-drop package ordering, explicit **Delete Package**, project reset,
  and disposable **Clear Cache** controls.
- Added multi-file/folder Development Policy selection and durable drag-priority
  ordering in Rune Forge, plus per-project policy-log export. CLU notices now
  identify the violated policy and include its bounded redacted policy content.

- Advanced the product identity to `0.16.0 (15)` across repository authorities,
  runtime constants, tests, and every Xcode build configuration.

### Fixed

- Kept Projects folder/package/reset/cache actions, the Continuity project-ID
  list/copy/delete actions, and Provider Advanced/connection/probe actions in
  persistent visible regions. Continuity retains its controls in the empty
  state, and the staged application bundle now includes both SwiftPM resource
  bundles and must remain alive for three seconds before smoke verification
  succeeds.

- Unified LM Studio selection, **Connect and Check**, the Advanced connection
  check, and provider probe on the same actionable Manager preparation path so
  they no longer fall through the obsolete run-resumption path and report a
  misleading `manager unavailable` result.
- Replaced the Continuity operator UI with a scrollable registered project-ID
  list plus **Copy Project ID** and project-scoped **Delete**. Manual checkpoint,
  rollover, run selection, timelines, and old-item cleanup controls are no
  longer part of that view.
- Removed Managed Run launch instructions and labels from current Guided Setup,
  Dashboard, Projects, Provider, Rune Forge, and Continuity guidance. Retained
  low-level run services remain compatibility-only.

- Removed the documented app-hosted Thread Performance Checker inversions by
  matching diagnostic delivery, shutdown, and project-context waiter QoS to
  their bounded callers. Authenticated operator credential file work also now
  leaves the main actor before request construction.
- Restored usable Projects instruction-package controls in constrained window
  geometry. Explicit earlier/later and **Delete Package** buttons remain
  distinct controls, and stale background snapshots cannot roll back a newer
  persisted package order.
- Limited provider-repair auto-resume to the active project generation, so a
  durable historical run cannot abort recovery of current-generation work.
- Retained 1,024 bounded managed-provider receipts—two complete windows for the
  maximum 16 concurrent runs and 32 tool rounds—so a current run can reconcile
  its first turn after a durable yield without unbounded storage.
- Preserved the original checkpoint observation when a context-budget request
  escalates to rollover or emergency, while still applying the request's newer
  severity. A valid escalation no longer appears as V2 identity drift.
- Quarantined the exact project-local continuity operation when its owning run
  is cancelled. Recovery also removes a legacy stranded operation only after
  proving that its owning control-plane run is terminal.

### Verification

- An ordinary Apple Development-signed app launch passed
  `testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch`, retaining a
  screenshot and accessibility hierarchy for Projects, Continuity, Rune Forge,
  and Provider. The versioned source also passed
  `testRealProviderModelDiscoveryAndConnectionFromSavedNativeConfiguration`
  against loaded model `qwen/qwen3.8-27b`; **Connect and Check** succeeded before
  and after relaunch without `operator-unavailable`. Final Desktop-candidate
  archive, exact-binary UI rerun, Advanced-probe rerun, and ordinary LM Studio
  chat acceptance remain open, so this is not a shipment claim.

- The September 27 owner-workflow correction passed the complete 1,902-test
  Swift suite with 12 explicit environment-dependent skips and zero failures;
  both SwiftPM products and the canonical Apple Development-signed Debug app
  built. Two current-source production Manager routes passed against loaded LM
  Studio model `qwen/qwen3.8-27b`: live **Connect and Check** readiness reuse
  and the live provider probe. Five focused native UI tests passed for the
  project-ID-only Continuity surface, ID copy, project-scoped deletion, and
  minimum-window instruction package reorder/deletion. Current native-candidate
  Provider-button, CLU-delivery, and full automatic rollover acceptance remain
  open; these results do not claim shipment.
- Product source `849b87953b4420f07a629fdcd29ecf0d58216756`
  passed the complete 1,890-test Swift suite with 12 explicit skips and zero
  failures and the complete 111-test app-hosted suite with zero failures. The
  exact Desktop app at `/Users/flynn/Desktop/Forge Conductor 0.15.0
  (14)-849b879.app` reported `0.15.0 (14)`. Against the Mac's stored Continuity
  data, **Clear Selected** removed
  `c36460fe-05ae-b00c-8aae-100209600137` from 24 visible IDs; **Clear All Old**
  then reduced the remaining 23 IDs to none, and none returned after Refresh or
  exact-app relaunch. The matching `.xcarchive` remains beside the app and the
  working installation was not replaced. Developer ID distribution,
  notarization, owner acceptance, and shipment remain separate.
- Candidate source `74ead97e0b4d2116e80e8482d5736afc94e16372`
  passed all 37 instruction-queue tests and all 18 Projects view-model tests.
  A new integration case started a real run-owned `sleep 30` runtime job,
  stopped its queue, verified job/run cancellation and terminal package state,
  then removed the unlocked package.
- The Apple Development-signed native minimum-window UI case clicked **Stop
  Active Work**, Move later, and **Remove**, observed persisted state through a
  later two-second poll, and passed. The separate signed real-Manager UI case
  imported two packages, persisted reorder, removed one, and passed. Both
  SwiftPM products built, and a strict-signature-verified universal Debug app
  plus `.xcarchive` were created outside `/Applications`.
- A signed owner-machine acceptance test attached to Desktop candidate
  `/Users/flynn/Desktop/Forge Conductor 0.14.7 (13)-74ead97.app`. At normal
  size it started LM Studio run `450f1a7f-8f49-4d78-bd7d-1e97c94f6273`,
  clicked **Stop Active Work**, observed the run/package `cancelled` and Remove
  enabled, persisted an earlier move through Refresh, and persisted removal.
  At the 1100×788 minimum window it repeated the live flow with run
  `850f0576-225f-4b04-a4ff-a5d43471494d`, clicked the hittable Stop, Move
  later, and Remove controls, and verified reorder/removal after Refresh. The
  pinned `qwen/qwen3-coder-30b` model was `IDLE` after Stop. The retained
  `.xcresult` executed 1 test with zero skips and zero failures. No shipment
  claim is made.
- Published ordered-readiness/receipt repair
  `675d267fdd2f45cd412e5398a04a2321bfe51def`, budget-escalation repair
  `f39c79ad0e60259d7a02ba0361825e5b6940c136`, and cancellation-authority
  repair `101c3d44f80c689c428e255f4578d88c54f40c16`. The final complete
  SwiftPM regression passed 1,879 tests with 12 explicit skips and zero
  failures; both SwiftPM products and the canonical Debug workspace app built.
  Focused regressions cover unloaded-pin admission before mutation,
  current-generation-only resume, 33-turn restart replay, 1,024-record
  compaction, checkpoint escalation, and cancellation quarantine.
- Installed the repaired Apple Development-signed app at
  `/Applications/Forge Conductor.app`. Its exact native UI passed two cases:
  launch without automatic Guided Setup and selectable Provider cards with the
  LM Studio no-resume/repair/resume transaction. The installed manager returned
  HTTP 200 for the owner's same project/package **Start Ordered Work** request.
  Final live run `6573026b-35f1-47b8-a0c6-6b4df226eed7` completed 50 LM Studio
  turns, 41 tools, and 18 automatic rollovers without the LM Studio
  configuration, receipt-reconciliation, identity-drift, or stranded-operation
  failures found during repair. It then paused at its separate package
  completion gate because project-build and project-tests evidence was absent.
- Strict deep signing passes for the installed development build. Gatekeeper
  distribution assessment rejects it because it is not a notarized Developer
  ID artifact; no public-distribution or shipment claim is made.

## [0.15.0] — 2026-09-27 (build 14 continuity retention controls)

### Added

- Added confirmed Continuity cleanup controls for deleting one selected old
  item or every old item across registered project generations. Old means a
  terminal command or a missing/terminal owning run. Cleanup retires stale
  nonterminal project state and removes Continuity operation, handoff,
  transition, repair, and rebuildable projection data plus its visible list
  root. A genuinely live item remains visible with its exact blocker and
  recovery action. Ordinary project memory, tasks, runs, credentials, project
  files, and unrelated project data remain unchanged.

### Changed

- Advanced the development product identity to `0.15.0 (14)` across repository
  authorities, runtime constants, tests, and every Xcode build configuration.
  This identity change makes no shipment claim.

### Fixed

- Removed app-hosted priority inversions in diagnostic delivery, shutdown, and
  project-context waiting, and moved authenticated operator credential I/O off
  the main actor before constructing loopback requests.

### Verification

- Product source `849b87953b4420f07a629fdcd29ecf0d58216756`
  passed the complete 1,890-test Swift suite with 12 explicit skips and zero
  failures and the complete 111-test app-hosted suite with zero failures. The
  exact Desktop `0.15.0 (14)` app cleared one of 24 live stored Continuity IDs,
  cleared the remaining 23, and retained an empty list across Refresh and
  relaunch. Its matching archive is staged beside it outside `/Applications`.
  Distribution, notarization, owner acceptance, and shipment remain owner
  actions.

## [0.14.7] — 2026-09-26 (build 13 identity correction)

### Changed

- Corrected the product version and build identity for the product commits that
  landed after `0.14.6 (12)`. This identity change makes no shipment claim.

## [0.14.6] — 2026-09-26 (build 12 development repair candidate)

### Fixed

- Kept exactly one execution provider active in the native Provider UI. Clicking
  the active selector no longer submits a second deactivation that can leave
  ordered-run admission without a provider; selecting another provider performs
  the existing readiness-fenced switch.
- Made LM Studio activation supersede a replaceable background Provider snapshot
  load. An enabled LM Studio selector can no longer silently ignore the user's
  **Connect and Check** action during view startup.
- Preserved the no-resume preparation request through the app's manager-client
  router. Retained provider-wait runs now stay quiescent until integration
  repair completes and the required post-repair preparation succeeds.
- Stopped presenting Guided Setup automatically when Forge Conductor launches.
  The wizard remains available from Dashboard and the title bar and retains its
  saved step between explicit uses.

### Verification

- The complete SwiftPM regression passed 1,875 tests with 12 explicit
  environment/helper skips and zero failures. The focused Provider suite passed
  27/27 and Guided Setup progress passed 4/4.
- Four exact app-hosted Xcode regressions passed. Signed native UI passed the
  launch-without-wizard case and the Provider selection/LM Studio transaction,
  including the exact no-resume/repair/resume request order.
- Both SwiftPM products and the canonical Apple Development-signed Debug
  workspace app built. Repository hygiene and exact `0.14.6 (12)` identity
  checks passed. Prior live-provider, installed-build, and distribution evidence
  is not inherited.

## [0.14.5] — 2026-09-26 (build 11 development repair candidate)

### Added

- Added the first Forge Link foundation for a future remote LM Studio endpoint:
  a versioned local-or-linked provider mode, strict transport-neutral discovery,
  pairing, health, capability, control, and role contracts, plus an owner-only
  revision-checked paired-node registry. Existing provider data migrates to
  local mode. This slice does not expose discovery, pairing, a network listener,
  or a remote endpoint in the UI and does not claim live GB10 qualification.

### Fixed

- Made a folder package runnable whenever it contains at least one readable
  instruction document. Every source is still retained and catalogued, but an
  unsupported attachment such as `.DS_Store` or an opaque binary no longer
  blocks the readable instructions beside it.
- Kept package intake and ordering available while ordered work is running;
  adding or rearranging pending packages does not replace the active run.
- Consolidated instruction selection, ordered execution, direct task creation,
  and run controls under **Projects**. The redundant top-level Autonomy tab is
  removed; **Run Details…** opens the retained run inspector and controls.
- Moved the macOS toolbar into dedicated AppKit chrome so project headings and
  controls remain below the title bar at minimum window size.
- Combined CPU logical-core and GPU core/engine presentation in one
  **COMPUTE CORES** telemetry frame. The operator has accepted this frame.
- Kept Continuity's managed-run contract directed at automatic session handoff:
  durable save, fresh successor creation, exact acknowledgment, predecessor
  fencing, and automatic continuation remain one recoverable flow.
- Preserved an already loaded LM Studio model while deploying an unchanged,
  synchronized Forge MCP configuration. Routine setup no longer relaunches LM
  Studio merely because its MCP child processes are waiting for lazy chat
  activation.
- Restored a current provider-readiness projection from the durable exact-model
  receipt after app and Manager relaunch, so setup status does not regress to an
  unverified placeholder before the next explicit probe.
- Made the Codex package executable from the installed desktop host by including
  the bounded signed runtime closure, retaining the host-compatible manifest,
  and registering the MCP command through the app's signed helper path.
- Made successful trusted Codex `PostToolUse` events durable, bounded completion
  evidence. Read-only automatic tasks can now satisfy their compiled completion
  plan after a successful allowed Forge tool call and an exact completion marker.
- Updated the production onboarding fixture for immutable artifact bootstrap and
  canonical completion gates without weakening production validation.

### Verification

- Passed the complete SwiftPM regression: 1,872 tests executed, 13 explicit
  environment/helper skips, and zero failures. The skips are not counted as
  passes.
- Passed all 36 instruction-queue tests, all 15 operator-project contract tests,
  and three signed native UI cases covering primary navigation,
  Projects-to-Run-Details task entry, and minimum-window toolbar clearance.
- Built both SwiftPM products and the canonical Apple Development-signed Debug
  workspace app. Strict deep-signature verification and exact bundle/CLI
  identity checks passed for `0.14.5 (11)`.
- Live LM Studio and Codex execution has not yet been repeated for this exact
  identity. The live receipts recorded under `0.14.4 (10)` remain historical and
  are not used to call `0.14.5 (11)` shippable.
- Autonomy removal passed operator review. Mixed-folder package import,
  Projects-owned ordered LM Studio execution, and automatic Continuity handoff
  are implemented pending owner live review; no acceptance or shipment claim is
  made for those three items.

## [0.14.3] — 2026-09-25 (development)

### Fixed

- Made project setup transactional around LM Studio integration deployment.
  **Connect and Check** now keeps retained provider waits quiescent until the
  integration operation finishes, then re-probes the provider and resumes the
  exact retained runs. A bounded Manager fallback performs the same recovery if
  the Provider view closes before observing the terminal operation.
- Moved provider readiness ahead of instruction-artifact import during
  **Start Task**, so a missing model or unavailable provider no longer leaves
  an orphan immutable setup artifact. Deterministic non-retryable Manager
  conflicts now surface as configuration errors instead of triggering an
  inapplicable lost-response reconciliation.
- Corrected release-contract tests that still asserted `0.14.1 (7)` after the
  prior version advance, and advanced this backward-compatible repair to
  `0.14.3 (9)`.

### Verification

- Built both SwiftPM products and the signed canonical Debug app; the full
  SwiftPM suite completed 1,848 tests with 12 explicit environment/helper skips
  and zero failures. Separate zero-skip live LM Studio checks passed provider
  preparation plus fresh-root acknowledgement and automatic continuation.
- Passed signed native UI registration through both an absolute path and the
  macOS folder picker, including Manager readback, allowed-root persistence,
  and relaunch. The onboarding harness now isolates completed Guided Setup
  state so the intentional first-run sheet cannot mask unrelated controls.

### 0.14.2 (8) operability repair

- Managed model task prompts now identify instruction snapshots and explicitly
  direct catalog/document paging before execution. Unread instruction packages
  retain their known progress totals instead of reporting zero documents.
- Repeated completion requests with identical validation evidence now obey the
  saved failure/retry policy. The no-progress count survives activation/restart;
  exhausted retries preserve the run in a paused state instead of looping.
- Autonomy opens new-task completion checkboxes expanded and links to that
  setup from the existing task's read-only evidence record. This does not permit
  manually marking unproven evidence as passed or changing an active contract.
- Rune Forge shows bounded durable policy evaluation activity separately from
  violation events and states the current detector coverage limitation.
- GPU Cores is below CPU Cores. Compact Storage and Orchestration frames leave
  additional horizontal space for Managed Activity.

### Prior development line

- Version `0.14.3 (9)` was the preceding unreleased development identity. Its
  guided setup, Autonomy, Continuity, provider-recovery, desktop-integration,
  native UI, and qualification changes are recorded in the development section
  below; no distribution or shipment is claimed.

## [0.14.1] — 2026-09-23 (development)

### Added

- Added the persistent eight-step **Guided Setup** wizard to the Dashboard title
  bar. It walks through Manager readiness, provider readiness, project
  registration, instruction packages, Autonomy choices, review/start
  confirmation, monitoring, and issue recovery while preserving the current
  step.
- Added universal **Connect and Check** actions to selectable provider cards.
  An inactive card performs the complete manager-owned provision, inspection,
  readiness, and selection flow; an active desktop card verifies or repairs its
  installed integration.

### Changed

- Made completion ownership explicit: Forge configuration exposes only its
  built-in evidence checkboxes, while an instruction package remains the sole
  owner of any additional completion requirement. Package requirements are
  displayed read-only and evaluated by the Manager from durable run evidence.
  Unknown configuration-owned completion identifiers are rejected.
- Restored Continuity's complete operation/history/detail behavior in an
  adaptive layout that stays below the toolbar and removes the unused middle
  frame when no operation is selected. Protection and recovery states now name
  the retained condition and, when operator intervention is required, the
  owning action; automatic recovery is stated directly when no action is needed.
- Removed the remaining instruction-queue path that converted a transient
  pre-run creation failure into a configuration block. Forge now retains the
  exact durable run identity and retries it automatically through the existing
  Manager watchdog; paused runs keep their package linkage without creating a
  separate queue blocker.
- Kept **Managed Activity** compact beside Storage at normal Dashboard widths;
  the rolling response, tool, orchestration, and project-policy feed remains
  bounded and expands only where the available width requires it.
- Updated Settings Doctor guidance to report the running version/build and all
  current LM Studio roles, including CLU, and to offer current-build deployment
  for stale or missing owned registrations.
- Advanced the development identity from `0.14.0 (6)` to `0.14.1 (7)` for this
  backward-compatible operability correction. This is not a shipment claim.

### Fixed

- Fixed Swift 6 strict-concurrency diagnostics in desktop MCP tool-description
  construction and the Provider activation binding without changing the MCP
  schema, provider-selection behavior, or Xcode target membership.
- Fixed Xcode 27's no-AppIntents metadata phase so it produces its intended
  empty output without emitting missing-framework warnings or adding an
  AppIntents dependency.
- Fixed LM Studio discovery on a second Mac by checking the supported system,
  per-user, symlink, Homebrew, and `PATH` CLI locations; accepting bounded
  status wrappers and string ports; starting the local server when needed; and
  polling readiness before the normal authenticated inventory and contract probe.
- Fixed Autonomy so completion checkboxes are selectable and retained run states
  show a specific recovery explanation based on the owning project, provider,
  or package requirement. Legacy configuration states recover automatically
  without additional Forge configuration or an environment reset.
- Fixed desktop provider activation so nonzero CLI results are accepted only for
  narrowly recognized already-installed outcomes followed by live inventory
  verification. Codex packages now carry the portable MCP schema, and Grok
  packaging follows its documented passive event set without making Grok
  selectable.
- Fixed Continuity title, refresh, selected-operation, and empty-state geometry
  so content no longer runs beneath the top bar and no supported detail surface
  is removed.
- Verified the final source with 1,844 SwiftPM tests (13 explicit skips, zero
  failures), both SwiftPM products, a warning-free arm64 Xcode Debug build, and
  native UI coverage for the full eight-step wizard, provider controls,
  Autonomy recovery, Continuity detail/title-bar clearance, Dashboard panel
  geometry, and every primary view at minimum and normal window sizes.

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
  plan; the bound instruction package exclusively supplies any additional
  completion requirements.
- Preserved instruction-package tools and `completion_gates` schema values
  through single,
  imported, and ordered composite run artifacts, while merging only explicitly
  selected manager-owned automatic checks for direct runs.
- Reworked Autonomy failure guidance and Continuity protection states to show
  the exact retained condition and route recovery to Provider or Autonomy.
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
  reports, artifact registration, and unresolved work; instruction packages
  exclusively supply any additional completion requirements.
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
