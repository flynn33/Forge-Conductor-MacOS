# Guided Setup and Guided Mode

Guided Mode provides optional, offline explanations for the part of Forge
Conductor currently in use. It does not connect to the model, change project or
provider configuration, start work, or perform recovery actions.

## Using Guided Mode

Use the **Guided Mode** toolbar control to show or hide the concise guidance
banner above the selected view. This preference persists across app relaunches.
The banner explains the purpose of the view, its current state when one is
available, and the next ordinary action when one is needed.

Use the question-mark toolbar button for the complete guide to the selected
tab. Guides describe:

- what the view is for;
- what Forge handles automatically;
- the visible controls and their effects;
- status meanings;
- the normal workflow and expected result;
- troubleshooting steps;
- advanced details and related guides.

The first-use setup experience and the persistent contextual guides have
different jobs. **Guided Setup** is the ordered project-run wizard; question-
mark actions explain only the current view or control.

## Guided Setup wizard

Open **Dashboard** and choose **Guided Setup** in its title bar. The wizard also
opens on first use and remembers the selected step across relaunches. Its eight
steps are the supported operating order:

1. **Confirm Forge is ready** — verify Manager is running.
2. **Select and verify the provider** — start LM Studio, Claude Code Desktop,
   or Codex Desktop and choose that card's **Connect and Check** action. For an
   inactive provider, the action performs the manager-owned provision,
   inspection, readiness, and selection workflow; for an active desktop
   provider, it verifies or repairs the integration. Complete only an exact
   reload, activation, or trust action reported by the host.
3. **Register the project** — select the exact repository; normal registration
   authorizes that folder without a separate parent-root setup step.
4. **Add and order instructions** — import packages, review their capabilities
   and package-owned completion requirements, and arrange execution order.
5. **Review automation behavior** — confirm tools, automatic completion checks,
   failure handling, and continuity behavior.
6. **Start the automated run** — launch the ordered queue from Projects or one
   direct task from Autonomy.
7. **Monitor the run** — use Dashboard for live state, Autonomy for exact run
   control, Continuity for rollover, Rune Forge for policy observations, and
   Events & Evidence for durable audit detail.
8. **Resolve issues and continue** — follow the current issue's owning-view
   action without deleting or duplicating the durable run.

Every step states its readiness condition, ordinary actions, recovery guidance,
and links to the owning view. **Next required step** uses current Manager,
Provider, project, package, and run state to recommend a step. It is navigation
guidance only: it does not change configuration, start a run, or approve
completion evidence; those remain explicit controls in their owning views.

The review step distinguishes selectable built-in evidence checks from
instruction-package requirements. Package requirements are read-only in Forge
configuration and remain part of the bound instruction artifact.

Only one provider can be selected. Desktop-host activation may transactionally
install or update Forge-owned plugin, hook, skill, and MCP files, but the wizard
does not approve host permissions. Claude and Codex can require a user trust
review; any remaining host action stays visible in Provider. LM Studio uses a
Forge-managed session, while desktop providers retain their model and
conversation and exchange orchestration context at the hook boundary. A
desktop provider with unfinished tasks cannot be selected, deselected,
repaired, or removed until those tasks are finished or cancelled through
Autonomy.

Grok Build remains visible in Provider but is non-selectable in 0.14.2. Its
documented startup and prompt hook outputs cannot deliver Forge's initial
assignment context to the model, so Guided Setup never treats Grok package
presence as readiness and cannot advance a Grok run.

## Context inside sheets and focused controls

Important sheets and controls expose their own question-mark buttons. Start
Task and Register Project use nested guide presentation owned by the active
sheet, so opening and closing help retains entered text and selections. More
specific guides are available for:

- adding and ordering instruction packages;
- relinking, resetting, and clearing project content;
- Start Task and task-capability selection;
- automatic completion checks;
- save-progress and fresh-session continuity actions;
- runtime jobs;
- provider credentials.

Closing a guide returns to the same application surface. Guide presentation is
read-only; buttons that perform an actual navigation or retry remain explicit
product controls rather than hidden guide side effects.

## State-aware guidance

Autonomy guidance distinguishes loading, missing project, provider action, and
task-ready states. Continuity explains whether operations exist and the state of
the selected operation. Provider guidance distinguishes the durable selection,
provisioning operation, remaining desktop-host action, verified deployment,
repair/removal availability, and LM Studio's unsaved or unverified advanced
connection settings. Runtimes guidance reports the selected job state or that
no runtime job needs attention.

Dashboard guidance explains the bounded, coalesced Managed Activity projection,
including its current inferred instruction step, durable delivered count,
rolling durable managed-response/tool/orchestration/project-policy rows,
authenticated exact run/project/generation boundary, explicit source
availability, five-second view-owned refresh, 100-row presentation bound,
128-assistant plus 128-tool per-run retention, 2 KiB durable event, 8 KiB
presentation, and 4 MiB streamed-response bounds, and the explicit boundary
that it is not token streaming or a second full transcript.
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

Native UI acceptance covers all 14 primary-tab routes, Start Task's more-specific
guide, preservation of the entered task draft while help opens and closes,
persisted Guided Mode preference, keyboard dismissal, and the reusable native
tool-permission checkboxes. These behaviors are also backed by app-hosted
catalog and route tests, so an unavailable UI-automation host is recorded as a
test-environment limitation rather than silently treated as a pass.
