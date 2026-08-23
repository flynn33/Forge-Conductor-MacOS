# SwiftUI State and Observation

## Ownership

- app-wide service container at the app root;
- project-scoped state in a project context;
- session-scoped state in a session coordinator;
- window/scene state at the scene root;
- view-local interaction state in `@State`.

Pass narrow protocols/models to views. Do not inject one monolithic observable that makes every telemetry change invalidate the whole app.

## Observation fan-out

Audit all `@Observable`, `ObservableObject`, environment, and published values.

- split high-frequency telemetry from low-frequency project/session metadata;
- expose per-feature presentation models;
- avoid reading broad observable state high in the view tree;
- compute expensive derived data outside `body`;
- stabilize list identity;
- do not use `@State` as an arbitrary computation cache;
- batch related mutations.

Use SwiftUI Instruments to prove invalidation scope. `EquatableView` is not a blanket fix; equality must be cheaper and value semantics correct.

## Scenes

Model main, settings, utility, inspector, and menu-bar surfaces explicitly. Scene disappearance or project switching must call service stop/detach boundaries where lifetime ends.

Keep AppKit/Metal representables narrow. Coordinators own delegates and detach them explicitly.

## Gauge integration

SwiftUI owns labels, accessibility, selection, and layout. The renderer owns native draw resources. A value change invalidates the scheduler, not an independent endless animation clock.

## Tests

- observation update counts;
- selection/list identity;
- scene create/destroy loops;
- hidden view quiescence;
- multiple windows/projects;
- settings persistence;
- commands and keyboard routes;
- accessibility identifiers and semantic values.
