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
| LM Studio provider | **Exact build-19 Desktop-candidate connection and ordinary-chat acceptance passed without a local credential; build-21 automatic successor acceptance uses the same GUI-hosted MCP channel.** The signed candidate discovered loaded model `qwen/qwen3.8-27b`; Connect and Check and Run Advanced Probe passed before and after exact-path relaunch. Manager readback was ready/contract-valid with `credential_configured=false`, and the UI exposed neither a token field nor a credential action for the loopback endpoint. A fresh foreground LM Studio GUI chat called the candidate's `get_forge_status`, `context_get`, and memory tools and returned the live Forge home, project root, project ID, and handoff ID. | Linked HTTPS provider credentials remain separate; the same-host path retains no operator-facing or Forge-held LM Studio credential. |
| Project selection | **Implemented and focused-tested.** Projects accepts multiple folders and exposes registered project context without starting a run. Selection establishes stable identity, generation, and the default working directory; it is not a filesystem access sandbox. | One or more selected project folders remain available to the LM Studio model through project-bound Forge tools without hiding native host paths. |
| Native tool access | **Build-22 source correction focused-tested.** Filesystem, search, PDF, Git, shell, and runtime paths are canonicalized but no longer confined to selected project roots or wrapped in Forge's per-command Seatbelt profile. macOS evaluates access for the responsible signed code objects in the actual launch chain; a parent grant alone is not proof. Runtime jobs retain a default 16-descendant budget, a 1,024-identity hard cap, typed overflow, and bounded cleanup debt. Local outside-project delete/move independently reconstructs protected roots and descriptor-rechecks the source identity at the mutation boundary. Tool grants, shell enablement, project binding/generation, time and output bounds, and durable result fencing remain. | An exact signed build-22 candidate must prove `/bin/ps`, protected-data access without content disclosure, external filesystem/Git work, every available runtime profile, descendant cleanup, and destructive-root refusal under the intended Full Disk Access grant. |
| Dashboard active project | **Build-22 source correction focused-tested.** Dashboard correlates live MCP presence with the active durable `mcp_client` binding, ordered by recent activity with heartbeat fallback. An exact nonterminal run is secondary evidence; registration alone is not active-project evidence. | The exact candidate must show the same project used by the active LM Studio MCP client, including a multi-project configuration. |
| Instruction packages | **Implemented and focused-tested.** Multiple packages can be selected, displayed, drag-reordered, removed with **Delete Package**, and discovered through project-scoped tools. | The complete selection, ordering, deletion, persistence, and LM Studio query flow passes in the current candidate. |
| Rune Forge policy | **Implemented and focused-tested.** Files and folders can be selected, persisted in priority order, drag-reordered, and queried with project isolation. | The complete selection, ordering, persistence, and model-query flow passes in the current candidate. |
| CLU governance | **Deterministic contract implemented; live-session acceptance open.** Notices carry the violated policy identity and full applicable policy statement; logs are project-isolated, bounded, and exportable. | CLU monitors model activity, preserves a separate log per project, exports it, and sends the active model a notice containing the exact violated policy and policy content. |
| Continuity automation | **Build-21 foreground-GUI implementation and live signed-candidate rollover passed.** The successor no longer calls `POST /api/v1/chat` or supplies an integrations array. After the 30-second boundary, the native host adapter activates LM Studio through its public macOS Accessibility surface, presses New, fills Chat input with `get_forge_status`, `resume=true`, the exact handoff ID, and a deterministic nonce, then presses Send. Disposable handoff `79474019-000f-4395-a593-cc74a6da2372` opened selected foreground tab `Forge Rollover Successor Proof`, visibly called `get_forge_status mcp/forge-conductor-fallback`, wrote the exact nonce-bound receipt, acknowledged logical successor `51a4567d-36f9-4d44-8a54-925f6e14a0f5`, and then sealed the predecessor. A delayed watchdog check retained exactly one successor record. Build 21 also accepts Electron's New accessibility name from title, description, or value after build 20 proved that the live control did not populate `AXTitle`; that failed dispatch remained at `intent` and opened no chat. | Owner inspection and shipment remain separate. Crash/restart recovery is deterministic-tested; the live host check proved repeated watchdog idempotency after submission and completion. |
| Continuity view | **Exact build-19 Desktop-candidate packet acceptance passed.** The signed candidate showed project `d2610542-b616-7e8f-ee36-ef902d6060e1` even with automation unavailable and rendered its real checkpoint/handoff rows with ID, type, source, and timestamp. Two disposable packets were selected and deleted through the native UI; all 73 pre-existing packet IDs remained unchanged. The exact-candidate surface test also found Copy, Delete, Reset, and Clear Cache visible and no instruction-package control. | Owner visual acceptance remains separate. Batch selection is deterministic-tested at the exact request boundary; no additional live packets are to be deleted merely to repeat that proof. |
| Reset / packet deletion / cache clearing | **Focused scope tests and live exact-packet deletion passed.** Exact packet deletion cannot reach project-wide clearing, task-owned ingress, instruction packages, or project files. Continuity Reset uses only project-scoped settled continuity-history clearing and does not advance the project generation; Clear Cache remains bounded to Forge's disposable cache directory. | Owner-machine Reset and Clear Cache mutation acceptance remains open because those controls were intentionally not run against live owner data. |
| Managed Run removal | **Removed from primary navigation and the current workflow.** Compatibility internals remain only where required to preserve stored data or reusable low-level services. | No current action, guide, status text, or continuity dependency directs the user to start project work through Managed Run. |

## Release boundary

The product remains unshippable until every row above has direct focused tests,
canonical workspace membership verification, an ordinary signed app build, and
current owner-machine runtime evidence for the installed LM Studio workflow. A
passing legacy Managed Run test is not acceptance evidence for this roadmap.

## Current correction evidence

Build-22 source removes the internal Seatbelt wrapper that denied native
commands such as `/bin/ps` even when macOS Full Disk Access was granted. The
complete focused `CoreTests` selection passed 49/49; the focused all-available-
runtime profile case passed with an external working directory, `/bin/ps`, and
inherited environment state. The complete runtime-job suite passed 103/103,
including an observed `setsid(2)` child, and secure-filesystem coverage passed
100/100. Dashboard operational-snapshot tests passed 23/23 in both SwiftPM and
the app-hosted Xcode target,
including live MCP binding preference and the requirement that registration
alone is not active-project evidence. Exact signed build-22 runtime and native
Dashboard acceptance remain open and are not inferred from these source tests.

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
aligned at `0.16.1 (22)`. The wiki and published revision must be verified as
part of direct publication. Historical evidence remains bound to the version it
actually exercised.

Historical build-16 candidate evidence remains available for comparison. Source revision
`f2cc6ca1dd70c5837f318cfb86381d5fcb8785dd` produced the universal Apple
Development-signed Desktop app and `.xcarchive` named `Forge Conductor 0.16.0
(16)-f2cc6ca`. Strict deep signature validation passed and the app reports
`0.16.0 (16)`. With `FORGE_DESKTOP_CANDIDATE_PATH` set to that exact app,
`testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch` executed one
test with zero failures and retained a Continuity screenshot plus accessibility
hierarchy showing the then-current controls. It is superseded for packet and
local-credential acceptance by build 17 and cannot close the current gate.
