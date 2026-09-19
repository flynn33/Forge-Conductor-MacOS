# Automation and usability remediation

This record tracks implementation of the September 19, 2026 revision-2
automation and usability plan. The controlling product outcome is a normal
workflow that needs only a project location and instruction packages while
Forge owns application preparation, bounded instruction handling, completion,
continuity, and contextual help.

The plan package was integrity-checked before implementation. Its three files
matched `SHA256SUMS`; the full plan hash is
`858bc672895e564662ce1355c5ab4c591055648e2696dcffaac46f6373549255`.
The package's inspected source, local `main`, and `origin/main` were all
`0fdaf3f3abc06a4616bfb9820fe7c316417457ef` with zero divergence when work
started. The requested `/Users/flynn/...` machine path was absent; the verified
checkout at `/Users/jimdaley/GitHub/Forge-Conductor` has the exact requested
`flynn33/Forge-Conductor-MacOS` fetch and push remote.

## M0 baseline

The current source reproduced the plan's three primary defect families:

- Autonomy required raw provider, adapter, model, comma/newline tool, and
  completion-gate fields before Start became available.
- Instruction ingestion retained its extension filter and fixed 32 KiB mission,
  1 MiB document, 8 MiB aggregate, 64-document, 256-package, 512-snapshot, and
  4 MiB reload boundaries.
- The toolbar question mark opened the generic setup tutorial without a typed
  current-view or active-sheet context.

Both SwiftPM products built successfully at the baseline. The six existing
`ProjectInstructionQueueTests` passed. A new configured-start reproducer then
failed with three assertions: manager defaults left the allowed-tool list empty,
left the completion check empty, and kept Start disabled after the user selected
the project and entered instructions. This is E0 for the first M1 correction.

## Implemented M1 slices

The manager operator snapshot now publishes one bounded `run_preparation`
projection. It derives the ordinary tool grant from the intersection of the
queue's established default profile and the exact registered production tools,
uses the saved provider/model configuration, supplies the existing built-in
completion check, keeps network authority off, and reports whether the saved
provider is ready, being prepared, or waiting on an external dependency.

Autonomy applies these defaults once. A later refresh does not overwrite an
explicit edit, and completing one run no longer erases the selected tool and
completion defaults. The ordinary start sheet now presents Project and
Instructions first, with preparation state summarized and technical overrides
collapsed under Advanced. The protected custom validation importer remains
available as an advanced action.

Direct HTTP admission and instruction-queue admission now call the same typed
manager resolver for provider, adapter, model, registered tools, built-in
completion, and network defaults. A configured Autonomy request omits those
technical keys entirely when the displayed values still match the manager
projection. Explicit Advanced changes remain exact request values and are
validated rather than silently replaced. The authenticated manager route now
accepts the minimal request, rereads the saved provider configuration at
admission, resolves only omitted fields, validates the effective production
tool catalog, and persists the resolved run contract.

This is a narrow M1 slice, not completion of M1 or the overall remediation.
Durable prepared descriptors, stale-preparation receipts, and combined folder
grant/registration remain open in M1. Native catalog checkboxes and saved
project preferences remain M2; document-backed format-neutral import remains
M3; automatic task-aware completion remains M4; provider lifecycle, continuity
presentation, and contextual Guided Mode remain M5; whole-journey acceptance
and the source-bound candidate remain M6 and M7.

## Verification

- The configured-start reproducer now passes with only its project and
  instructions supplied by the user fixture.
- The real manager/provider configuration test passes and verifies that the
  published defaults contain only registered tools, the saved model, the native
  host adapter, the built-in completion check, and no network grant.
- The configured app request encodes no provider, adapter, model, tool, gate, or
  network key when manager defaults are unchanged; changed Advanced values are
  retained exactly.
- An authenticated HTTP integration starts and persists a run with every
  technical field omitted, then reads back the saved model, registered ordinary
  tools, and built-in completion gate from the durable run.
- Direct and queue construction both use `ManagerRunPreparationResolver`; its
  focused test covers defaults, exact overrides, and explicit-empty rejection.
- Five operator-project/app-contract tests, four provider-configuration tests,
  the focused HTTP runtime-control test, six queue tests, and 121 Manager tests
  passed. The Manager class retained two explicit environment/helper skips and
  had zero failures.
- Both SwiftPM products and the canonical `ForgeConductor` Debug Xcode scheme
  built successfully. Repository hygiene and `git diff --check` passed.
- Unexecuted revision-2 acceptance tests remain `not_run`; this record does not
  promote them to passing.
