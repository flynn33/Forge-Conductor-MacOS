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
8. The Continuity view is an operator data-management surface only. It shows
   project IDs in a scrollable frame, supports selecting and copying IDs, and
   deletes the selected project's continuity data through one clear **Delete**
   action. It does not expose manual checkpoint, rollover, run selection, or
   operation-timeline controls.
9. Project reset, selected instruction-package deletion, and disposable-cache
   clearing are present on the Projects surface.

## Required repair and acceptance state

| Area | Current state | Required acceptance |
|---|---|---|
| LM Studio provider | **Implemented; live source route verified; native candidate acceptance open.** Provider selection, **Connect and Check**, the Advanced connection check, and probe use one actionable preparation path. The current source passed the production preparation and probe routes against loaded model `qwen/qwen3.8-27b`. | Every native entry point reaches the same live LM Studio configuration and contract check, distinguishes Manager transport/authentication failures from LM Studio endpoint/model/tool-contract failures, and succeeds against the owner-selected loaded model. |
| Project selection | **Implemented and focused-tested.** Projects accepts multiple folders and exposes registered project context without starting a run. | One or more selected project folders remain available to the LM Studio model through project-scoped Forge tools. |
| Instruction packages | **Implemented and focused-tested.** Multiple packages can be selected, displayed, drag-reordered, removed with **Delete Package**, and discovered through project-scoped tools. | The complete selection, ordering, deletion, persistence, and LM Studio query flow passes in the current candidate. |
| Rune Forge policy | **Implemented and focused-tested.** Files and folders can be selected, persisted in priority order, drag-reordered, and queried with project isolation. | The complete selection, ordering, persistence, and model-query flow passes in the current candidate. |
| CLU governance | **Deterministic contract implemented; live-session acceptance open.** Notices carry the violated policy identity and full applicable policy statement; logs are project-isolated, bounded, and exportable. | CLU monitors model activity, preserves a separate log per project, exports it, and sends the active model a notice containing the exact violated policy and policy content. |
| Continuity automation | **Deterministic host-boundary implementation and tests complete; live LM Studio acceptance open.** A resume-ready handoff starts the 30-second state machine, creates one stored LM Studio chat, submits `get_forge_status` with `resume=true`, requires exact handoff acknowledgement, and handles repeated watchdog ticks idempotently. | A current owner-machine flow proves durable handoff, the visible countdown, exactly one successor chat, bootstrap submission, exact acknowledgement, predecessor sealing, and crash recovery. |
| Continuity view | **Implemented and focused-tested.** It is a scrollable project-ID list with selection, copy, and one confirmed selected-project **Delete** action. | Current-candidate UI evidence proves the exact reduced surface and durable deletion behavior. |
| Reset / package deletion / cache clearing | **Implemented and focused-tested.** Projects exposes confirmed reset, explicit package deletion, and disposable-cache clearing that preserves durable data. | Each action is discoverable, correctly scoped, durable across relaunch, and verified in the current candidate. |
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
content, per-project log export, the project-ID-only Continuity surface,
project-scoped continuity deletion, and the 30-second LM Studio successor state
machine. The complete Swift suite passed 1,902 tests with zero failures and 12
explicit environment-dependent skips. The current source also passed the two
live LM Studio production preparation/probe tests against
`qwen/qwen3.8-27b`, and five focused native UI tests proved the reduced
Continuity surface, project-ID copy/deletion, and minimum-window instruction
package reorder/deletion controls. Both SwiftPM products and the canonical
Apple Development-signed Debug app build compile.

These results prove only their tested boundaries. The roadmap remains open
until the current native candidate passes every Provider entry point and the
complete owner-machine LM Studio workflow proves CLU delivery and the automatic
handoff/countdown/successor/acknowledgement/sealing/recovery sequence.
Historical evidence remains available in Git history and dedicated evidence
documents; it is not part of this roadmap.
