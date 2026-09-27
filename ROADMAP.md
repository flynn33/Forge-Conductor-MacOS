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
| LM Studio provider | **Exact build-19 Desktop-candidate connection acceptance passed without a local credential.** The signed candidate discovered loaded model `qwen/qwen3.8-27b`; Connect and Check and Run Advanced Probe passed before and after exact-path relaunch. Manager readback was ready/contract-valid with `credential_configured=false`, and the UI exposed neither a token field nor a credential action for the loopback endpoint. | Ordinary LM Studio chat MCP and automatic successor creation must use the same tokenless local path; linked HTTPS provider credentials remain separate. |
| Project selection | **Implemented and focused-tested.** Projects accepts multiple folders and exposes registered project context without starting a run. | One or more selected project folders remain available to the LM Studio model through project-scoped Forge tools. |
| Instruction packages | **Implemented and focused-tested.** Multiple packages can be selected, displayed, drag-reordered, removed with **Delete Package**, and discovered through project-scoped tools. | The complete selection, ordering, deletion, persistence, and LM Studio query flow passes in the current candidate. |
| Rune Forge policy | **Implemented and focused-tested.** Files and folders can be selected, persisted in priority order, drag-reordered, and queried with project isolation. | The complete selection, ordering, persistence, and model-query flow passes in the current candidate. |
| CLU governance | **Deterministic contract implemented; live-session acceptance open.** Notices carry the violated policy identity and full applicable policy statement; logs are project-isolated, bounded, and exportable. | CLU monitors model activity, preserves a separate log per project, exports it, and sends the active model a notice containing the exact violated policy and policy content. |
| Continuity automation | **Deterministic host-boundary implementation and tests complete; live LM Studio acceptance open.** A resume-ready handoff starts the 30-second state machine, creates one stored LM Studio chat, submits `get_forge_status` with `resume=true`, requires exact handoff acknowledgement, and handles repeated watchdog ticks idempotently. | A current owner-machine flow proves durable handoff, the visible countdown, exactly one successor chat, bootstrap submission, exact acknowledgement, predecessor sealing, and crash recovery. |
| Continuity view | **Exact build-19 Desktop-candidate packet acceptance passed.** The signed candidate showed project `d2610542-b616-7e8f-ee36-ef902d6060e1` even with automation unavailable and rendered its real checkpoint/handoff rows with ID, type, source, and timestamp. Two disposable packets were selected and deleted through the native UI; all 73 pre-existing packet IDs remained unchanged. The exact-candidate surface test also found Copy, Delete, Reset, and Clear Cache visible and no instruction-package control. | Owner visual acceptance remains separate. Batch selection is deterministic-tested at the exact request boundary; no additional live packets are to be deleted merely to repeat that proof. |
| Reset / packet deletion / cache clearing | **Focused scope tests and live exact-packet deletion passed.** Exact packet deletion cannot reach project-wide clearing, task-owned ingress, instruction packages, or project files. Continuity Reset uses only project-scoped settled continuity-history clearing and does not advance the project generation; Clear Cache remains bounded to Forge's disposable cache directory. | Owner-machine Reset and Clear Cache mutation acceptance remains open because those controls were intentionally not run against live owner data. |
| Managed Run removal | **Removed from primary navigation and the current workflow.** Compatibility internals remain only where required to preserve stored data or reusable low-level services. | No current action, guide, status text, or continuity dependency directs the user to start project work through Managed Run. |

## Release boundary

The product remains unshippable until every row above has direct focused tests,
canonical workspace membership verification, an ordinary signed app build, and
current owner-machine runtime evidence for the installed LM Studio workflow. A
passing legacy Managed Run test is not acceptance evidence for this roadmap.

## Current correction evidence

Focused deterministic tests cover provider preparation convergence,
`get_forge_status`, registered-project and location discovery, multi-folder and
multi-package selection, drag ordering, package deletion, project reset,
disposable-cache clearing, ordered Development Policy sources, CLU notice
content, per-project log export, the Continuity project-ID and packet-management
surface, exact packet batch deletion, and the 30-second LM Studio successor state
machine. The complete Swift suite passed 1,902 tests with zero failures and 12
explicit environment-dependent skips. The current source also passed a native
LM Studio connection test before and after app relaunch against
`qwen/qwen3.8-27b` without `operator-unavailable`. A new ordinary-launch native
UI test retained screenshots and accessibility hierarchies for Projects,
Continuity, Rune Forge, and Provider, while five earlier focused tests proved
the Continuity list/copy/delete/reset/package/cache controls, project-ID
copy/deletion, and minimum-window instruction package reorder/deletion controls.
Both SwiftPM products and the canonical Apple Development-signed Debug app
build compile.

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
IDs and retained the unselected packet. Automatic successor acceptance remains
open rather than inferred from these results.

Historical build-16 candidate evidence remains available for comparison. Source revision
`f2cc6ca1dd70c5837f318cfb86381d5fcb8785dd` produced the universal Apple
Development-signed Desktop app and `.xcarchive` named `Forge Conductor 0.16.0
(16)-f2cc6ca`. Strict deep signature validation passed and the app reports
`0.16.0 (16)`. With `FORGE_DESKTOP_CANDIDATE_PATH` set to that exact app,
`testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch` executed one
test with zero failures and retained a Continuity screenshot plus accessibility
hierarchy showing the then-current controls. It is superseded for packet and
local-credential acceptance by build 17 and cannot close the current gate.
