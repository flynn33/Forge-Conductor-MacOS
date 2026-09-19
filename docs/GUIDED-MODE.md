# Guided Mode

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

The first-use setup guide remains an onboarding index. It is separate from the
persistent question-mark action, which is contextual after first launch.

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

Unavailable or disconnected provider state does not prevent the bundled guide
catalog from opening.

## Accessibility and compatibility

Every guide has a heading, reachable Close control, semantic sections, and
stable accessibility identifiers for referenced controls. The catalog is
validated against the app-owned identifier list and fails tests if a primary
tab or typed guide context is omitted. Guided Mode does not intercept ordinary
screen interaction when its inline banner is visible.
