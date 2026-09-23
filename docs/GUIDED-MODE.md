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
2. **Connect the model provider** — load a tool-capable model in LM Studio, then
   use Provider's single **Connect and Check** action.
3. **Register the project** — select the exact repository; normal registration
   authorizes that folder without a separate parent-root setup step.
4. **Add and order instructions** — import packages, review their capabilities
   and gates, and arrange execution order.
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
guidance only: it does not change configuration, start a run, or approve a gate.

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
the selected operation. Provider guidance distinguishes unsaved settings,
verified readiness, and connection/setup work. Runtimes guidance reports the
selected job state or that no runtime job needs attention.

Dashboard guidance explains the bounded, coalesced Managed Activity projection,
including its current inferred instruction step, durable delivered count,
rolling durable managed-response/tool/orchestration/project-policy rows,
authenticated exact run/project/generation boundary, explicit source
availability, five-second view-owned refresh, 100-row presentation bound,
128-assistant plus 128-tool per-run retention, 2 KiB durable event, 8 KiB
presentation, and 4 MiB streamed-response bounds, and the explicit boundary
that it is not token streaming or a second full transcript.

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
