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

The versioned preparation projection now includes the opaque saved-provider
configuration revision and the canonical production tool-catalog SHA-256. The
app echoes those revisions without exposing them as routine inputs. Start
compares both values before persisting a run; a changed provider or catalog
returns typed `run_preparation_stale`, leaves the requested run identity
unpersisted, and causes Autonomy to refresh manager defaults while retaining
explicit Advanced overrides. Project generation remains independently fenced by
the existing exact-generation admission contract.

Project registration now carries an explicit native-operator authorization
request. The Manager canonicalizes the selected directory and durably merges
that exact root with the latest configured roots under the existing
interprocess configuration lock before repository registration begins. It does
not grant the parent directory, `/`, a missing directory, or any new root for
legacy callers that omit the additive request field. The same encoded request
and bearer credential are reused by the bounded lost-response retry, so replay
is idempotent. The Projects sheet explains that Register authorizes the selected
folder; the normal workflow no longer requires entering the same path in
Manager first.

The Manager now builds a versioned, project-bound prepared-run descriptor for
both direct and queued admission. Its canonical revision covers the exact
project and generation, assignment, inline or package source snapshot,
content-addressed document references, saved provider revision and model,
production tool-catalog revision and effective grant set, completion plan,
automatic continuity mode, project-scoped budget selection, network authority,
and inline output boundary. Presentation text and readiness wording are excluded
from the authority hash.

Autonomy obtains that descriptor immediately before Start and submits its
revision with the same durable run UUID. Start reconstructs the descriptor from
current manager state and rejects any mismatch before durable creation. A
double-click cannot dispatch a second request while the first is active; a lost
reply retains the exact prepared body and run UUID for explicit reconciliation.
The core admission path accepts an exact duplicate as the same durable run.
Instruction-queue admission calls the same descriptor builder and inventories
the owner-only content-addressed package snapshot rather than the mutable
original source path.

This is a narrow M1 slice, not completion of M1 or the overall remediation.
Project-bound non-ready results still need to return every required typed
readiness and recovery state instead of relying on route errors for all missing
dependencies. That remaining readiness work keeps M1 open.
Native catalog checkboxes and saved project preferences remain M2;
document-backed format-neutral import remains M3; automatic task-aware
completion remains M4; provider lifecycle, continuity presentation, and
contextual Guided Mode remain M5; whole-journey acceptance and the source-bound
candidate remain M6 and M7.

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
- A second authenticated HTTP integration changes the provider configuration
  after preview and supplies a stale catalog hash. Both starts return the typed
  stale-preparation result before durable creation; the same run identity is
  then accepted with refreshed revisions and the new saved model.
- The app regression verifies that stale rejection triggers preparation refresh,
  clears duplicate-start reconciliation, and preserves explicit model, tool,
  gate, and network overrides.
- Direct and queue construction both use `ManagerRunPreparationResolver`; its
  focused test covers defaults, exact overrides, and explicit-empty rejection.
- The project-bound descriptor regression verifies exact project/generation,
  inline source hash and document reference, saved provider revision/model,
  catalog and grant selection, completion plan, automatic continuity, and the
  project-scoped budget. A changed source is rejected before persistence; an
  exact duplicate run UUID resolves to the same durable run.
- The native client regression verifies prepare-before-start, double-click
  suppression, one preparation request, and byte-identical replay of the same
  prepared run UUID after a lost Start reply.
- The queue regression verifies that queued work persists the same descriptor,
  provider/catalog/budget revisions, continuity mode, and immutable package
  snapshot hash. The storage regression independently hashes the accepted
  owner-only document after the original source changes.
- The authenticated project-registration regression first failed because the
  new authorization field was rejected. It now proves that one request retains
  an existing root, adds only the selected canonical directory, persists the
  result across reload, and rejects a non-Boolean authorization value without
  changing settings.
- The registration transport regression proves that a lost response replays
  the byte-identical body and credential, including the explicit project-root
  authorization. Native picker and direct-path UI coverage now read back the
  authorized root, including after relaunch.
- Six operator-project/app-contract tests, seven provider-configuration tests,
  six queue tests, seven dashboard-security tests, and 122 Manager tests passed.
  The Manager class retained two explicit environment/helper skips and had zero
  failures.
- Both SwiftPM products and the canonical `ForgeConductor` Debug Xcode scheme
  built successfully. Repository hygiene and `git diff --check` passed.
- Unexecuted revision-2 acceptance tests remain `not_run`; this record does not
  promote them to passing.
