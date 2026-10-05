# Guided Setup and Guided Mode

The native Graphite UI implementation and required QA are complete for
0.17.0 (27). Persistent main-window shortcuts are removed; their actions remain
in Settings and menus, with six independently enabled optional view controls.
Current production checks, normal/minimum native view fixtures and signed
ordinary workflows passed in their named scopes. Earlier failed and passing
checkpoints retain their original inputs and results in
[Graphite Workbench](GRAPHITE-WORKBENCH.md). Exact owner publication/readback/
synchronization refs are retained externally.

Guided Mode provides optional, offline explanations for the part of Forge
Conductor currently in use. It does not connect to the model, change project or
provider configuration, start work, or perform recovery actions.

## Graphite presentation

The current native guide banner, help sheets and Guided Setup use the shared
graphite panel and control treatment. Their routes and readiness actions remain
owned by the existing model. Provider row inspection is separate from its
explicit activation controls; selecting a visual row does not complete setup.
The [Graphite Workbench record](GRAPHITE-WORKBENCH.md) retains the earlier
native visual, guide persistence/Escape and wizard scroll/progress checkpoints.
The current normal/minimum native matrix passed shared guidance, all eight
Wizard steps, registration and full Advanced content; its selected image layers
were individually reviewed. The signed ordinary candidate has separate
Settings/Dashboard and runtime observations. Cache/compositor limitations and
earlier failed checkpoints remain explicit in the phase record.

## Using Guided Mode

Use **Show contextual Guided Mode** in **Settings → Workbench** or **Guided
Mode** in the **Guide** menu to show or hide the concise guidance banner above
the selected view. This shared preference applies immediately and persists
across app relaunches. Its optional view toggle appears only when enabled under
**Settings → Workbench → Optional view controls**.
The banner explains the purpose of the view, its current state when one is
available, and the next ordinary action when one is needed.

Use **View Guide** in Workbench Settings or the **Guide** menu for the complete
guide to the selected tab. The optional **Guide** shortcut can also be enabled
in Settings. Guides describe:

- what the view is for;
- what Forge handles automatically;
- the visible controls and their effects;
- status meanings;
- the normal workflow and expected result;
- troubleshooting steps;
- advanced details and related guides.

The first-use setup experience and the persistent contextual guides have
different jobs. **Guided Setup** prepares Forge for normal LM Studio chat work;
question-mark actions explain only the current view or control.

## Guided Setup wizard

Choose **Guided Setup** in Workbench Settings or the **Guide** menu; an optional
view shortcut can be enabled in Settings. The wizard does
not cover the app at launch; it opens only on explicit request and remembers the
selected step across relaunches. Its eight steps are the supported operating
order:

1. **Confirm Forge is ready** — verify Manager is running.
2. **Select and verify the provider** — start LM Studio, Claude Code Desktop,
   or Codex Desktop and choose that card's **Connect and Check** action. For an
   inactive provider, the action performs the manager-owned provision,
   inspection, readiness, and selection workflow; for an active desktop
   provider, it verifies or repairs the integration. Complete only an exact
   reload, activation, or trust action reported by the host.
3. **Register the project** — select the exact repository; normal registration
   authorizes that folder without a separate parent-root setup step.
4. **Add and order instructions** — import one or more packages and drag them
   into the priority order the model should follow.
5. **Review project inputs** — confirm provider readiness, instruction order,
   and Development Policy priority in Rune Forge. Choose the registered
   project in the wizard's **Project to review** panel, then use **Confirm Review
   and Continue** when the current inputs are ready.
6. **Start in LM Studio** — open a normal LM Studio chat, call
   `get_forge_status`, then give the model the task.
7. **Monitor governance and continuity** — use Dashboard for the automatic
   rollover countdown, Rune Forge for CLU policy observations/log export, and
   Events & Evidence for durable audit detail. Continuity manages project-ID
   copy plus exact packet deletion, reset, and disposable-cache
   clearing without initiating rollover.
8. **Resolve issues and continue** — follow the current provider, package,
   policy, or continuity action without switching to Managed Run.

Every step states its readiness condition, ordinary actions, recovery guidance,
and links to the owning view. **Next required step** uses current Manager,
Provider, project, package, and run state to recommend a step. It is navigation
guidance only: it does not change configuration, start a run, or approve
completion evidence; those remain explicit controls in their owning views.

The review step distinguishes selectable built-in evidence checks from
instruction-package requirements. Package requirements are read-only in Forge
configuration and remain part of the bound instruction artifact.

Project review reads the registered project identity, generation, instruction
queue and provider revision before a model chat is started. It does not require
an active MCP project binding, make that project Dashboard's active project,
activate a provider or dispatch work. The wizard remembers the reviewed project
choice independently. A changed project generation, instruction queue or
provider configuration requires a new review. Seven app-hosted review
regressions, native review confirmation/persistence and final wizard scroll/
progress captures passed. Exact verification is recorded separately in
[Graphite Workbench](GRAPHITE-WORKBENCH.md).

Only one provider can be selected. Desktop-host activation may transactionally
install or update Forge-owned plugin, hook, skill, and MCP files, but the wizard
does not approve host permissions. Claude and Codex can require a user trust
review; any remaining host action stays visible in Provider. LM Studio work
begins and remains in the ordinary LM Studio interface. After a durable
handoff, Forge uses the app's public macOS Accessibility controls to create the
visible successor and the installed GUI MCP tool to acknowledge it; it does not
use the REST integrations array.

Grok Build remains visible in Provider but is non-selectable in current source 0.17.0. Its
documented startup and prompt hook outputs cannot deliver Forge's initial
assignment context to the model, so Guided Setup never treats Grok package
presence as readiness and cannot advance a Grok run.

## Context inside sheets and focused controls

Important sheets and controls expose their own question-mark buttons. Current
project-management sheets use nested guide presentation owned by the active
sheet, so opening and closing help retains entered text and selections. The
retained Start Task guide context does not introduce a live Start Task route.
More specific guides are available for:

- adding and ordering instruction packages;
- relinking, resetting, and clearing project content;
- provider connection and project selection;
- Development Policy source ordering and log export;
- automatic continuity and project-ID data management;
- runtime jobs;
- provider credentials.

Closing a guide returns to the same application surface. Guide presentation is
read-only; buttons that perform an actual navigation or retry remain explicit
product controls rather than hidden guide side effects.

## State-aware guidance

Project guidance distinguishes loading, missing project, provider action, and
LM Studio-ready states. Continuity explains project-ID copying, exact packet
deletion, reset, and cache clearing; it exposes no manual checkpoint
or rollover action. Provider guidance distinguishes the durable selection,
provisioning operation, remaining desktop-host action, verified deployment,
repair/removal availability, and LM Studio's unsaved or unverified advanced
connection settings. Runtimes guidance reports the selected job state or that
no runtime job needs attention.

Dashboard guidance explains the bounded, coalesced Forge Activity projection
and the visible automatic LM Studio successor countdown. The activity view is
not token streaming or a second full transcript.
Its provider step and Dashboard card use the same selected-provider projection:
Claude or Codex can report **HOST READY** independently of LM Studio health only
when ready preparation, the matching selection revision, and a verified receipt
agree. Missing, stale, in-flight, or non-selectable evidence fails closed and
keeps the Provider step actionable.

Rune Forge guidance explains Development Policy source selection, immediate
acceptance, bounded interpretation states, violation and occurrence history,
delivery status, the verbose newest-first Policy Feed, cached degraded behavior,
scanning, removal, and the current four-format export workflow. It also states
the non-interference boundary: Stjornarvald
reports guidance but does not authorize tools, admit runs, or decide completion.

Unavailable or disconnected provider state does not prevent the bundled guide
catalog from opening.

## Accessibility and compatibility

Every guide has a heading, reachable Close control, semantic sections, and
stable accessibility identifiers for referenced controls. The catalog is
validated against the app-owned identifier list and fails tests if a primary
tab or typed guide context is omitted. Guided Mode does not intercept ordinary
screen interaction when its inline banner is visible.

Earlier native UI acceptance covers all 13 primary-tab routes, live project
sheet guide presentation and draft preservation, persisted Guided Mode
preference, keyboard dismissal and the retained component checks. Start Task
and the reusable tool-permission component retain compatibility guide contexts;
this phase adds no production route to either. App-hosted catalog and route
tests cover their typed mappings. The final native capture and interaction
results remain separate evidence in the Graphite record; an unperformed or
failed check is never counted as a pass.
