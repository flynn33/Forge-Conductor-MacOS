# Forge Conductor macOS — project roadmap

## Owner-defined shippable workflow — September 27, 2026

This is the complete current roadmap and acceptance authority. The existing
build is **not shippable**. Earlier roadmaps and Managed Run plans are history,
not product requirements, dispatch instructions, or acceptance evidence for
this workflow.

## Required user workflow

1. The user selects one or more project folders.
2. The user selects one or more instruction packages. The application presents
   the packages in an ordered frame and supports direct click-and-drag
   reordering and organization.
3. The user sets Development Policy in **Rune Forge** with an application
   control that accepts files or folders. Selected policy sources appear in an
   ordered frame and support direct click-and-drag priority reordering.
4. The user starts and conducts the model conversation in the **LM Studio chat
   interface**. Forge Conductor does not start the project through Managed Run.
5. In LM Studio the user asks for `get_forge_status`, then gives the model the
   task instructions. The model can query Forge for the selected instruction,
   project-file, and continuity locations.
6. **CLU** is the governance-enforcement agent. It monitors the model against
   the ordered Development Policy, retains a separate bounded log for each
   project, allows the user to export those logs, and notifies the model of a
   violation with the violated policy and the applicable policy content.
7. Continuity is automatic and is not initiated from the Continuity view. When
   the model saves a resume-ready handoff at context pressure, Forge starts a
   visible 30-second countdown. At expiry Forge uses a supported LM Studio host
   boundary to create a fresh chat, submits `get_forge_status` with
   `resume=true`, verifies that the successor consumed the exact handoff, and
   only then seals the predecessor. Crash recovery is idempotent.
8. The Continuity view is an operator data-management surface only. It always
   shows project IDs in a scrollable frame and supports selecting and copying
   IDs. Under the selected project it lists every actual continuity packet—the
   durable handoff/checkpoint rows consumed by continuity and `context_get`—with
   packet ID, type, and timestamp. **Delete** removes only the selected packet
   or multi-selection after one confirmation. **Reset** and **Clear Cache** stay
   on Continuity: Reset clears settled automatic continuity history without
   advancing the project generation, and Clear Cache removes only Forge's
   bounded disposable cache namespace. Neither deletes unrelated project files. It does
   not expose instruction-package controls, manual checkpoint, rollover, run
   selection, or operation-timeline controls.
9. Instruction-package selection, ordering, and **Delete Package** belong to
   Projects. Project reset and disposable-cache clearing may also remain there,
   but Projects is not a substitute for the required Continuity packet surface.
10. Same-host LM Studio connection, Advanced probe, MCP chat use, and automatic
    successor creation require no Forge-held LM Studio token, operator login, or
    local credential field. Authentication of Forge's own Manager remains a
    separate internal control boundary. Linked HTTPS providers may retain their
    separate credential path.

## Required repair and acceptance state

| Area | Current state | Required acceptance |
|---|---|---|
| Graphite Workbench UI/UX and Compute Cores | **0.17.0 (27): UI implementation and required QA complete.** | Shared native Graphite, Settings-first optional controls, aligned text and bounded exact-reference Compute Metal/fallback preserve current features. Source manifest 28548a73… covers 434 inputs and passed 15 checks; 116 distinct production tests in 140 executions and the separate 21-method/22-invocation native matrix passed, with all 463 selected view PNGs, 68 Compute layers and 20-frame MOV reviewed. The signed My Mac Debug candidate CDHash 1a36aa4d… passed four scoped ordinary workflows and actual Settings/Dashboard/restoration observations; cache/compositor/physical 1×/ordinary minimum limits remain explicit. [Graphite](docs/GRAPHITE-WORKBENCH.md), [Compute](docs/COMPUTE-CORES.md), [native QA](docs/GRAPHITE-NATIVE-QA.md) and [history](docs/COMPUTE-CORES-CHECKPOINTS.md) retain 62 criteria/18 capture scopes and failed checkpoints; owner source/wiki publication and synchronization are complete, with exact refs retained externally. The documentation-only status correction preserves all 434 tested inputs and the canonical Xcode graph; no installation, notarization or distribution was performed. |
| Installed 0.16.4 bootstrap, startup export, and Xcode distribution path | **0.16.5 (26) corrected project and isolated native paths verified.** E0: installed GUI/CLI signing rejection `-67050`, compiled development policy on Developer ID products, and stale archive daemon seals were reproduced/read. Release now signs all five products with Developer ID before sealing; Debug retains automatic Apple Development. Startup diagnostics survive failed/cancelled graph construction and export to a writable folder with unavailable-history disclosure. Canonical Debug build, 8 app-hosted bootstrap tests, universal Release archive and Developer ID export passed. The exported compiled policy passes; 215 identity checks confirm both-architecture app/CLI daemon seals before/after export. Exact exported GUI failure/healthy paths produced native-picker JSON/Markdown exports (23 file assertions); CLI bootstrap passed. Final `swift test` exited 0: qualification 30/30, Core 1,961 selected with 12 skipped and 0 failed. Both SwiftPM products compile. Ten native source/test memberships, resources, embedding, schemes, and non-configuration graph objects are unchanged; H0 remains SwiftPM-only. | Corrected project delivery is complete for the verified paths. UI XCTest initialization timed out before any test ran; direct CUA exercise is separate native evidence. Installation, notarization, distribution, skipped qualification paths, and full LM Studio workflow remain unperformed. The earlier native qualification preserved the installed 0.16.4 app and LM Studio registration; the later publication readback found the app absent, with the registration hash unchanged. Commands, artifact identities, initial failures, and limits are in `docs/QUALIFICATION-STATUS.md` and `/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-bootstrap-export`. Local/remote main publication uses the tested inputs; exact revision is retained in the delivery receipt without a self-referential source edit. |
| October 3 documentation and wiki alignment | **Historical 0.16.5 (26) identity alignment recorded.** At the October 3 checkpoint, active guides, README, Unreleased changelog, wiki and qualification summaries used that authoritative source identity. Historical receipts retain their observed versions and limits. The publication host readback is separately dated; it does not replace prior native evidence or attribute the absent app to a known cause. That documentation-only publication preserved the corrected canonical Xcode project and source/resource/test inputs from the tested `354c695842a4dde00d79f4ee946f35152de9d8df` implementation. | Documentation-only checks cover repository hygiene, focused version assertions, active-reference and wiki-link audits, unchanged product-input hashes, and clean local/remote synchronization. Exact repository/wiki revisions are recorded outside the source tree in `/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-docs-wiki-sync`. Installation, notarization, distribution, and full LM Studio qualification remain separate. |
| Diagnostic capture and six installed-alpha findings | **Historical 0.16.4 (25) source correction tested; installed-alpha outcome unverified.** The October 2 archive has 11,653 JSON records and a 2,000-row Markdown timeline without an omission notice (E0). Source inspection confirms pre-persistence/reload error redaction, `fs_read`'s unclassified `not_found` mapping, and returned search/shell detail loss (E1). Current source adds stable record and request identities, sanitized error and failure-stage fields, result and job outcomes, connection identity, and explicit export boundaries. The A–H writer/test map is in `docs/DIAGNOSTIC-CAPTURE-CONTRACT.md`; final-tree source and app-hosted results are recorded below. At that historical boundary, Xcode target memberships were unchanged and version/build settings were 0.16.4/25; current authorities are 0.17.0/27. | Verify the patched diagnostic stream and the original user-visible failure sequences on an installed candidate in a later owner-controlled run. The original exceptions for R11618/R11636, R11458's exact cause, R11579's exit, R11640's terminal state, and any Dashboard request association remain unknowable from the old archive. No package, deployment, or live fix is claimed for this source slice. |
| Downloadable alpha Xcode project | **The prior automatic-development Archive correction is superseded by the reproduced owner distribution failure above.** Debug keeps automatic Apple Development; Release uses Developer ID and the distribution peer policy before daemon sealing. The canonical workspace Debug build, universal Release archive, and manual Developer ID export all completed on this host; exported native startup and folder-picker export were exercised separately. | The corrected Xcode project and documented workflow are validated to archive/export and the isolated native paths above. Owner notarization, installation, and distribution remain separate. The prior project tests did not qualify those paths. |
| LM Studio provider | **Exact build-19 Desktop-candidate connection and ordinary-chat acceptance passed without a local credential; build-21 automatic successor acceptance uses the same GUI-hosted MCP channel.** The signed candidate discovered loaded model `qwen/qwen3.8-27b`; Connect and Check and Run Advanced Probe passed before and after exact-path relaunch. Manager readback was ready/contract-valid with `credential_configured=false`, and the UI exposed neither a token field nor a credential action for the loopback endpoint. A fresh foreground LM Studio GUI chat called the candidate's `get_forge_status`, `context_get`, and memory tools and returned the live Forge home, project root, project ID, and handoff ID. | Linked HTTPS provider credentials remain separate; the same-host path retains no operator-facing or Forge-held LM Studio credential. |
| Project selection | **0.16.3 CLI staging/deploy reconnect observed (E0); package-install acceptance open.** Archive creation time and Git reflog identify build-tree HEAD `b8a2c5dee546dff8d914405c2169a075bd0187e2`, whose product code matches `a54100b453ba8b1c1489ff09ac64dd6193fc1597`. The archive helper's `forge-conductor install` copied artifacts into `~/.forge-conductor`, not `/Applications` or LM Studio. The staged helper's `install-lmstudio-plugin` wrote revision `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db` to primary, fallback, and CLU `mcp.json` entries. The support, archive, and separately copied `/Applications` helpers match at SHA-256 `49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`. The old v0.16.2 app was stopped; the candidate was manually copied over `/Applications` for cold-start observation, not installed by the `.pkg`. LM Studio fallback PIDs `38508` and `38964` returned the same deployment client and attached Jamf-Technician generation 7. Filesystem, Git, Continuity, and catalog calls returned `ok: true`; the pasted compact catalog receipt was a later `limit: 1` page, while the full catalog response remains in the saved chat. The registration file was unchanged across GUI launches. GUI Deploy was **not** exercised; `AppModel.deployToLMStudio` supplies the running app executable, so CLI deployment does not qualify it. The Xcode graph is unchanged. | The observed CLI staging/deploy and hosted binding are accepted only for those paths. `.pkg` installation failed for lack of root; GUI Deploy, package installation, notarization, Gatekeeper, shipment, and other roadmap gates remain open. |
| Native tool access | **Build-22 source correction and exact exported-helper probes passed.** Filesystem, search, PDF, Git, shell, and runtime paths are canonicalized but no longer confined to selected project roots or wrapped in Forge's per-command Seatbelt profile. The directly launched signed MCP helper passed `/bin/ps`, a protected Mail-path read without content disclosure, inherited Git, outside-project filesystem/Git operations, and one native runtime job. macOS evaluates access for the responsible signed code objects in the actual launch chain; this does not establish the installed Forge or LM Studio-hosted chain. Runtime jobs retain a default 16-descendant budget, a 1,024-identity hard cap, typed overflow, and bounded cleanup debt. Local outside-project delete/move independently reconstructs protected roots and descriptor-rechecks the source identity at the mutation boundary. Tool grants, shell enablement, project binding/generation, time and output bounds, and durable result fencing remain. | The intended Forge/LM Studio launch chain must prove protected-data access, every runtime profile, descendant cleanup, and destructive-root refusal with the exact candidate. |
| Dashboard active project | **0.16.3 reconnect correction app-hosted tested.** `testRegisteredProjectBecomesTrackableOnlyAfterStatusBindingSurvivesReconnect` asserts a registered-only project is unbound, attaches through status on a primary server, changes the random process identity and role, and resolves the same durable project through the reconnect identity. | Accepted for the automated Dashboard boundary; registration alone remains insufficient evidence. |
| Instruction packages | **Build-23 live query accepted.** Multiple packages can be selected, displayed, drag-reordered, and removed with **Delete Package**. `get_forge_status` now returns the selected project's durable execution order with package IDs, names, positions, source paths, and snapshot hashes. The exact build-23 LM Studio fallback returned `Jamf-Technician-Continuation-Package-R1` at position 0 for the bound project. | Complete selection, reorder, deletion, and persistence remain covered by focused tests; the live query contract is accepted for the retained build-23 candidate. |
| Rune Forge policy | **Build-23 exact-candidate LM Studio acceptance passed.** Files and folders can be selected, persisted, and drag-reordered. `get_forge_status` returns the pinned governing identity, every active source path in durable priority order, supported read tools, and an explicit required action to read and follow all applicable policy before development changes. Policy remains visible when project selection is ambiguous. Revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4` produced the universal Developer ID candidate; the existing Jamf-Technician chat's final repeated call used fallback PID `12436` from that exact helper and returned `/Users/flynn/Projects/raven-forge-development-main` at priority 1 plus the required instruction, ordered package, prior locations, continuity, and resume data. Focused regressions, both SwiftPM products, and the canonical Debug workspace build passed. | The bootstrap contract is accepted for the retained candidate. CLU live-session violation-notice acceptance, notarization, Gatekeeper acceptance, and shipment remain separate open work. |
| CLU governance | **Deterministic contract implemented; live-session acceptance open.** Notices carry the violated policy identity and full applicable policy statement; logs are project-isolated, bounded, and exportable. | CLU monitors model activity, preserves a separate log per project, exports it, and sends the active model a notice containing the exact violated policy and policy content. |
| Continuity automation | **Build-21 foreground-GUI implementation and live signed-candidate rollover passed.** The successor no longer calls `POST /api/v1/chat` or supplies an integrations array. After the 30-second boundary, the native host adapter activates LM Studio through its public macOS Accessibility surface, presses New, fills Chat input with `get_forge_status`, `resume=true`, the exact handoff ID, and a deterministic nonce, then presses Send. Disposable handoff `79474019-000f-4395-a593-cc74a6da2372` opened selected foreground tab `Forge Rollover Successor Proof`, visibly called `get_forge_status mcp/forge-conductor-fallback`, wrote the exact nonce-bound receipt, acknowledged logical successor `51a4567d-36f9-4d44-8a54-925f6e14a0f5`, and then sealed the predecessor. A delayed watchdog check retained exactly one successor record. Build 21 also accepts Electron's New accessibility name from title, description, or value after build 20 proved that the live control did not populate `AXTitle`; that failed dispatch remained at `intent` and opened no chat. | Owner inspection and shipment remain separate. Crash/restart recovery is deterministic-tested; the live host check proved repeated watchdog idempotency after submission and completion. |
| Continuity view | **Exact build-19 Desktop-candidate packet acceptance passed.** The signed candidate showed project `d2610542-b616-7e8f-ee36-ef902d6060e1` even with automation unavailable and rendered its real checkpoint/handoff rows with ID, type, source, and timestamp. Two disposable packets were selected and deleted through the native UI; all 73 pre-existing packet IDs remained unchanged. The exact-candidate surface test also found Copy, Delete, Reset, and Clear Cache visible and no instruction-package control. | Owner visual acceptance remains separate. Batch selection is deterministic-tested at the exact request boundary; no additional live packets are to be deleted merely to repeat that proof. |
| Reset / packet deletion / cache clearing | **Focused scope tests and live exact-packet deletion passed.** Exact packet deletion cannot reach project-wide clearing, task-owned ingress, instruction packages, or project files. Continuity Reset uses only project-scoped settled continuity-history clearing and does not advance the project generation; Clear Cache remains bounded to Forge's disposable cache directory. | Owner-machine Reset and Clear Cache mutation acceptance remains open because those controls were intentionally not run against live owner data. |
| Managed Run removal | **Removed from primary navigation and the current workflow.** Compatibility internals remain only where required to preserve stored data or reusable low-level services. | No current action, guide, status text, or continuity dependency directs the user to start project work through Managed Run. |
| Distribution artifact | **Product code `a54100b453ba8b1c1489ff09ac64dd6193fc1597` is retained in the `0.16.3 (24)` archive built at HEAD `b8a2c5dee546dff8d914405c2169a075bd0187e2`.** Archive version/build, universal architectures, and strict deep signing passed; a signed `.pkg` was also built. At that historical checkpoint, `/Applications/Forge Conductor.app` was a manually copied candidate, not a package-installed app. `installer` returned `Must be run as root to install this package.` | Package installation, notarization, stapling, Gatekeeper acceptance, Apple upload, and shipment remain open. No package-install or public-release pass is claimed. |

## October 3 diagnostic correction evidence

The attached `forge-diagnostics-20261002-130456.json` has 11,653 records.
R11458, R11579, R11617/R11618, R11636, and R11639/R11640 match the reported
event types and missing fields. The archive cannot identify their discarded
exceptions or establish an outage, job reuse, search exit, or specific
Dashboard request. This is E0 evidence of lost capture and E1 source evidence
for the exporter, redaction, and `fs_read` mapping. No historical cause was
reconstructed.

On the final `0.16.4 (25)` source and test tree, `swift test` completed:
`Executed 1955 tests, with 13 tests skipped and 0 failures (0 unexpected)`.
The skipped cases retain their separate live-provider and environment-specific
qualification boundaries. The canonical Debug workspace command
`xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor
-configuration Debug -destination 'platform=macOS' -derivedDataPath
/tmp/forge-0164-debug-build build` ended `** BUILD SUCCEEDED **`.
The complete app-hosted target ran with a separate derived-data path and
`-only-testing:ForgeConductorAppTests`: `Executed 127 tests, with 0 failures
(0 unexpected)` and `** TEST SUCCEEDED **`. The source suite emitted a
nonfatal temporary diagnostic export-directory error; the app-hosted target
emitted a SQLite vnode-unlinked warning from a temporary Stjornarvald fixture.
Neither warning is assigned a production cause here. Repository hygiene and
`git diff --check` passed. Every edited Swift source and test remains in its
existing Xcode target; the project update changes version/build settings.

At the earlier source-test boundary, `/Applications` still held the 0.16.3
alpha. The later owner-installed 0.16.4 failure is recorded above. That source
correction was not then installed or deployed into LM
Studio, packaged, or exercised against the owner's original live failure
sequence. Source and app-hosted tests do not close that acceptance gate.

## Release boundary

Historical `0.16.3 (24)` source has a universal Developer ID app and `.xcarchive`
under `~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID`. A fresh
signed candidate was copied into `/Applications` for the CLI-deploy cold-host
check above, but its signed `.pkg` was not installed. No artifact is claimed notarized,
stapled, publicly shipped, or released. A passing
legacy Managed Run test is not acceptance evidence for this roadmap.

## Current correction evidence

The installed `0.16.2 (23)` fallback diagnostics provide **E0** evidence for
the reconnect defect: fallback PID `5210`, client `7A3301C0…`, exited; the same
deployment restarted as PID `6489`, client `E066BA6A…`. On that replacement
client, `get_forge_status` completed successfully, but the immediately following
`fs_list`, `instruction_catalog`, `bash.run`, `process.run`,
`continuity.status`, and `fs_read` calls all failed with
`project_context_required`. A later LM Studio reproduction observed PID
`8943` → `9656` and client `026B5AD2…` → `A800AC6E…`; even explicit
`get_forge_status(project_id)` did not attach the stable replacement client.
The 0.16.3 source correction makes status attachment idempotent, derives one
client ID per deployment across primary/fallback/CLU restarts, refuses to
reactivate reset-fenced rows, and exposes attachment state. Implementation
revision `a54100b453ba8b1c1489ff09ac64dd6193fc1597` contains the completed correction and
its exact sequence tests. The complete Core
selection passed 55/55, including the focused status and reconnect cases;
ten project-context integration cases, twenty MCP protocol and diagnostics
cases, the replay catalog case, two version-alignment cases, and the Dashboard
resolver case also passed. The same Dashboard case executed and
passed in the signed app-hosted Xcode test target. Both SwiftPM products and the
canonical Debug workspace app build succeeded; repository hygiene and
whitespace checks passed. The source produced a universal Developer ID app and
archive whose exact version/build and five shipped code-object signatures pass
the Release privileged-bundle inspection. The cold hosted-session receipt and
path reconciliation are published in the wiki at
`e615c2405a094b43f9ebb4794ba0676c86ae38bd`.

Build-22 source removes the internal Seatbelt wrapper that denied native
commands such as `/bin/ps` even when macOS Full Disk Access was granted. The
complete focused `CoreTests` selection passed 49/49; the focused all-available-
runtime profile case passed with an external working directory, `/bin/ps`, and
inherited environment state. The complete runtime-job suite passed 103/103,
including an observed `setsid(2)` child, and secure-filesystem coverage passed
100/100. Dashboard operational-snapshot tests passed 23/23 in both SwiftPM and
the app-hosted Xcode target,
including live MCP binding preference and the requirement that registration
alone is not active-project evidence. One exact signed-candidate native runtime
job passed; signed-candidate all-profile and descendant-cleanup runtime
acceptance plus live multi-project Dashboard UI acceptance remain open and are
not inferred from the source tests.

Native runtime ownership is finite rather than open-ended: the normal
descendant budget is 16, retained start identities are capped at 1,024, and an
overflow produces a typed failed job. Sticky capacity evidence does not create
immortal liveness after all retained identities exit. Persistent termination
failure becomes bounded cleanup debt with one identity-fenced startup retry.
Local outside-project delete/move reconstructs the protected-root set independently at
execution and compares descriptor-pinned source identity against each protected
root and ancestor again immediately before mutation, closing the authorization-
to-dispatch rename window without reintroducing project-path confinement.

Focused deterministic tests cover provider preparation convergence,
`get_forge_status`, registered-project and location discovery, multi-folder and
multi-package selection, drag ordering, package deletion, project reset,
disposable-cache clearing, ordered Development Policy sources, CLU notice
content, per-project log export, the Continuity project-ID and packet-management
surface, exact packet batch deletion, and the 30-second LM Studio successor state
machine. The complete Swift suite passed 1,933 tests with zero failures and 12
explicit environment-dependent skips. The current source also passed a native
LM Studio connection test before and after app relaunch against
`qwen/qwen3.8-27b` without `operator-unavailable`. A new ordinary-launch native
UI test retained screenshots and accessibility hierarchies for Projects,
Continuity, Rune Forge, and Provider, while five earlier focused tests proved
the Continuity list/copy/delete/reset/package/cache controls, project-ID
copy/deletion, and minimum-window instruction package reorder/deletion controls.
Both SwiftPM products and the canonical Apple Development-signed Debug app
build compile.

A fresh foreground LM Studio GUI chat then called `get_forge_status` through
`mcp/forge-conductor-fallback`, followed by `context_get`, `memory_list`,
`memory_search`, and `fs_read`. Its visible response identified project
`Jamf-Technician`, root `/Users/flynn/GitHub/Jamf-Technician`, project ID
`d2610542-b616-7e8f-ee36-ef902d6060e1`, Forge home
`/Users/flynn/.forge-conductor`, and resume-ready handoff prefix `fdb9130a`.
The live Provider UI test now captures and restores the operator's Forge-owned
LM Studio registration inputs; the exact `mcp.json` and six
manifest/bridge-definition checksums were unchanged after the rerun.

These results prove only their tested boundaries. The roadmap remains open
until the current native candidate passes every Provider entry point and the
complete owner-machine LM Studio workflow proves CLU delivery and the automatic
handoff/countdown/successor/acknowledgement/sealing/recovery sequence.
Historical evidence remains available in Git history and dedicated evidence
documents; it is not part of this roadmap.

Build-19 correction evidence on the current source inputs: the packet store and
wire-contract test, populated Continuity packet-row UI test, confirmed exact
packet-delete UI test, and local-credential migration/rejection test each
executed with zero failures. A signed build-17 candidate exposed an additional
Release-only packet decoder defect: its embedded helper wrote valid packets but
returned an empty inventory. The focused optimized decoder test now passes and
the repaired Release helper reads all durable packets from the live store.
`swift build --product forge-conductor-app` and the canonical signed Debug
workspace build passed. Candidate revision `868645e85ce44b50b159136f3b56758a4f489c12`
produced the universal Apple Development-signed Desktop app and archive
`Forge Conductor 0.16.0 (19)-868645e`. Strict deep signature verification and
the privileged-filesystem bundle check passed. The exact candidate passed the
ordinary owner-surface UI case, including all required Continuity identifiers,
and the real-provider connection/probe case with `credentialConfigured=false`.
Two live disposable packet deletes reduced the inventory from 75 to 73; the
removed IDs were exactly `708cbe57-06b4-4cf3-85f8-75c458966b81` and
`60f7f1be-636c-443d-9cae-2c1fd5a6fc85`, with no additions or unexpected
removals. The focused multi-selection case issued one request for two selected
IDs and retained the unselected packet. The later build-21 automatic successor
acceptance is recorded independently rather than inferred from packet UI tests.

Build-21 source replaces the rejected LM Studio REST integrations successor in
`LMStudioRESTClient.createInteractiveSuccessor` / `LMStudioInteractiveSessionTransport`
with `LMStudioGUIChatDriver.submitSuccessor`. The replacement uses the running
LM Studio app's exposed macOS Accessibility controls and accepts only an exact
`get_forge_status(resume=true)` receipt bound to the handoff ID and rollover
nonce. The signed build-20 host attempt proved the 30-second countdown but also
proved LM Studio exposes its `New` button name outside `AXTitle`; build 21
matches the public accessible name across title, description, and value. Its
focused Swift selection executed 35 tests with one explicit live-provider skip
and zero failures. The signed build-21 candidate then completed handoff
`79474019-000f-4395-a593-cc74a6da2372` in selected foreground LM Studio tab
`Forge Rollover Successor Proof` through `get_forge_status mcp/forge-conductor-fallback`, exact
nonce receipt, logical successor `51a4567d-36f9-4d44-8a54-925f6e14a0f5`, and
predecessor sealing. No shipment claim is made.

Build-22 publication inputs: `VERSION`, `BUILD_NUMBER`, the compiled filesystem
protocol constants, all Xcode build configurations, current README/user/Xcode
and supporting documentation, and the focused version-contract assertion are
aligned at `0.16.1 (22)`. Implementation revision
`91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`, tree
`08e021b375fb8a998f06d9e81a10e3fffddd21f0`, is published on `main`. Its
universal Developer ID archive and export are retained under
`~/Desktop/Forge Conductor 0.16.1 (22)-91ad90e-DeveloperID`. Strict signing
passes for all five shipped code objects. The exported MCP helper passed the
protected-path, `/bin/ps`, inherited Git, outside-project filesystem, exact
project-binding, and runtime-job probes without Forge sandboxing or path
confinement. Gatekeeper exits 3 with `source=Unnotarized Developer ID`, so
notarization, stapling, Gatekeeper acceptance, live multi-project Dashboard UI
observation, and shipment remain open. The wiki is published at revision
`a8359d47623e7cf23ef58db762c6262e056b4ade`. Historical evidence remains bound
to the version it actually exercised.

Historical build-16 candidate evidence remains available for comparison. Source revision
`f2cc6ca1dd70c5837f318cfb86381d5fcb8785dd` produced the universal Apple
Development-signed Desktop app and `.xcarchive` named `Forge Conductor 0.16.0
(16)-f2cc6ca`. Strict deep signature validation passed and the app reports
`0.16.0 (16)`. With `FORGE_DESKTOP_CANDIDATE_PATH` set to that exact app,
`testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch` executed one
test with zero failures and retained a Continuity screenshot plus accessibility
hierarchy showing the then-current controls. It is superseded for packet and
local-credential acceptance by build 17 and cannot close the current gate.
