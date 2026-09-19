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

Project-bound preparation now returns one manager-owned result envelope with
the required `ready`, `automatically_preparing`, `needs_choice`,
`needs_authorization`, `waiting_dependency`, and `failed` states, a bounded
plain-language explanation, and a typed recovery action. Only `ready` carries
an authority-bearing descriptor. The Start sheet remains enabled with Project
and Instructions when setup is incomplete, displays the exact result, and
routes recovery to Projects, Model connection, Advanced permissions, or a
manager refresh. No non-ready result reaches Start or creates a durable run.

## Implemented M2 slices

The optional Task capabilities editor now derives every item from the canonical
registered production catalog rather than a UI-owned tool-name list. It groups
plain-language names, descriptions, and technical identifiers into the current
catalog categories; search, individual and category checkboxes, mixed-state
**Allow all tools**, Select none, Restore recommended, selected/available
counts, and higher-impact labels are native controls. A narrow AppKit checkbox
bridge supplies deterministic mixed state and keyboard activation. Network
authority remains a separate Advanced control.

The Manager owns one bounded, owner-only project preference store with
optimistic revision checks. Recommended, all-eligible, and explicit modes are
distinct: explicit selections never widen when the catalog grows; all-eligible
is re-resolved only for a future preparation; and removed or policy-disabled
tools retain a visible reason without entering the effective grant. A stale
removed selection can still be unchecked. Select none remains an explicit
denial and therefore returns `needs_choice` / `review_permissions` instead of
silently restoring defaults.

Direct run preparation resolves omitted capability input from the selected
project preference, intersects it with current availability, and records that
exact effective grant plus the availability-aware catalog revision in the
prepared descriptor. Existing prepared and running descriptors are immutable,
so a later install, removal, or policy change cannot silently widen them.
Raw identifiers remain accepted at the versioned compatibility API boundary,
but are no longer exposed as ordinary Start Task fields.

## Revision-3 Autonomy and tool-selection refinement

The ordinary Start Task sheet now leads with project and instructions, then a
compact summary of the saved model, checkbox-selected tools, automatic
completion checks, and automatic continuity. **Customize** contains only an
optional human task label, a typed picker for the saved compatible model, and a
separate network-authority toggle. Provider ID, adapter ID, raw model strings,
capability-ID lists, and completion-gate-ID lists are not editable in this
workflow.

The registered-catalog checkbox UI is now the reusable
`ToolPermissionEditor`, presented from **Tools → Customize** and used as the
sole ordinary permission authority. A permission recovery opens that editor
directly. The completion summary is inspectable but manager-derived. The run
detail now presents mission, state, current work, recent model/tool activity,
automatic continuity, completion, and recovery before placing run, project,
provider, session, operation, and lease identifiers under **Technical
details**.

## Revision-3 instruction-artifact task source

Start Task now loads the selected project's imported instruction packages and
lets the operator choose one or more in their visible queue order. A single
selection binds the direct run to the package's existing immutable SHA-256; it
does not reopen the original source path. Multiple selections, plus an optional
new file/folder/ZIP or quick-text source, are integrity-checked and published as
one deterministic ordered composite snapshot. Package and aggregate bounds,
unresolved-document rejection, project/generation/run scoping, and catalog/read
tool contracts remain unchanged.

`AutonomyTaskDraft` is the typed presentation model for project identity,
ordered package identities, quick text or local import, optional task label,
network authority, and model choice. Only the selected project and at least one
instruction input are required. Quick text of every size is staged off the main
actor in an owner-only temporary directory and removed after import. A changed
project generation reassembles a still-valid local or quick-text artifact under
the same client run UUID before preparation is retried; a selected package from
an obsolete generation remains fenced rather than silently rebound.

## Revision-3 automatic completion — AC-01 through AC-04

The Manager now derives one bounded `AutomaticCompletionPlan` during the shared
direct and queued preparation path. The plan is deterministically identified
from the exact project identity/generation, immutable instruction digest,
reasoned obligation set, and whether an owner-selected custom policy is present.
It records typed evidence requirements and human-review state for build, test,
requested-output, artifact-registration, read-only-report, runtime-job,
unresolved-side-effect, and custom-native-policy obligation kinds.

The compiled resolver inspects the prepared instruction text and shallow native
project structure. A read-only analysis receives report evidence without a
mutation/build requirement; a repair in a SwiftPM or Xcode project receives the
available build and test obligations. Every plan requires exact prepared-source
registration and reconciliation of relevant unresolved effects. Custom native
gates enter the plan only when explicitly configured. The resolver reads only
bounded canonical instruction windows and never delegates approval of evidence
or hashes to the model.

The prepared descriptor and durable run specification both carry the same plan,
and run metadata records its ID and revision. The fields are optional when
decoding pre-r3 records, preserving existing durable runs. Start Task and run
detail expose the derived obligation titles and reasons. Signed custom native
policy import remains available only after expanding **Advanced controls**; it
is not part of the routine path.

The built-in validator now traverses durable tool history in 128-record keyset
pages, retaining only bounded latest evidence for each obligation and rejecting
more than 65,536 records. Failed attempts remain durable history, but the latest
relevant build or test result determines its obligation: a later pass can repair
an earlier failure, and a later failure invalidates an earlier pass. A successful
read is relevant only to a plan-derived read-only report obligation. Intent,
executing, or ambiguous invocations and pending run intent block completion.

Evidence remains bound to the exact run, project, generation, registered source
digest, deterministic plan identity/revision, and integrity-checked result. The
existing native completion receipt also binds the full run specification and
expected final run revision; repository acceptance rechecks that exact run and
active project generation before completion. Legacy runs without a plan retain
their compatible bounded latest-success behavior. Obligation kinds not yet
generated by the compiled resolver fail closed rather than receiving inferred
evidence.

## Implemented M3 artifact-storage slice

Instruction import no longer concatenates source bodies into the 32 KiB run
mission. Schema-2 snapshots retain each original at its source-relative path,
store separately normalized canonical UTF-8 text with hashes and converter
identity, and publish a complete paged catalog before the compact queue record.
The mission is now only a bounded bootstrap naming the immutable snapshot and
requiring a package-level catalog pass before mutation.

Single files are inspected without an extension admission whitelist. Plain and
structured text decode as UTF-8 or BOM-marked UTF-16; native PDFKit and AppKit
adapters extract PDF, DOCX, RTF, and HTML text. Folder enumeration includes
hidden configuration/instruction files. Empty selections report a specific
no-instructions error. Opaque, malformed, encrypted, or image-only content is
retained byte-for-byte and reported unresolved rather than silently omitted or
misrepresented as understood; an unresolved next package cannot start.

ZIP containers are inspected before extraction. Import rejects unsafe or
duplicate paths, links and unsupported filesystem entries, encryption,
unsupported compression, excessive entry/expanded size or expansion ratios,
and local/central header disagreement. The native macOS `ditto` facility runs
only after preflight under a bounded deadline, and Forge compares the extracted
file inventory and sizes with the inspected container. Nested ZIPs are retained
unresolved for separate bounded import rather than recursively expanded.

The registered read-only `instruction_catalog` and `instruction_read` tools
require the active project, generation, and run identity. Catalog results page;
document reads use bounded byte windows, validate hashes and UTF-8 cursor
boundaries, and reassemble canonical content exactly after the original source
is moved or deleted. Import conversion and immutable staging occur outside the
queue mutation lock; atomic publication precedes the compact queue link, failed
links remove only unreferenced new snapshots, and restart removes only
UUID-named abandoned staging directories.

Queue metadata migrates transactionally from schema 1 or 2 to schema 3 while
the immutable snapshot/catalog format remains schema 2. New optional records
keep legacy package identities, ordering, active run linkage, and snapshots
intact. The fixed 512-snapshot admission count is removed in
favor of reference-aware removal. The current explicit safety budgets are
4,096 source files, 128 MiB per file, 512 MiB per import, 4,096 queue rows,
4,096 direct-run artifacts, 64 MiB queue metadata, and 64 KiB per delivery
window; these are resource
backpressure limits rather than instructions-authoring limits.

Autonomy now gives typed/pasted instructions, selected project packages,
selected files/folders/ZIPs, and dropped sources the same artifact semantics as
queue import. Pasted text of every size
is staged off the main actor in a fresh owner-only directory and removed after
the authenticated import response. Each direct artifact is durably bound to its
exact project, generation, and run UUID without entering or reordering the
package queue. Preparation and Start carry only the compact bootstrap and
snapshot digest; the scoped readers reject every other run identity.

This slice closes the artifact-backed text/rich-document and bounded ZIP storage,
direct input-surface parity, and scoped-retrieval foundation of M3. Durable
delivery progress and token-aware planning, catalog/history paging
beyond the transitional queue metadata budget, and decisive non-text asset
representation remain open before M3 can be declared complete.

The original revision-2 focused contracts completed M1 shared preparation and
M2 native tool selection and began M3. Revision 3 has since supplied contextual
Guided Mode and the AC-01 through AC-04 automatic-completion implementation
described above. This still does not claim live provider lifecycle automation,
whole-journey acceptance, source-bound candidate qualification, distribution,
or shipment; their current state remains in `ROADMAP.md`.

## Verification

- AC-01 through AC-04 verification covers deterministic replay, read-only versus repair
  classification, SwiftPM build/test detection, explicit custom-policy
  obligations, direct and queued persistence, exact source/project/generation
  binding, outcome supersession, unrelated-read rejection, wrong-scope and stale
  source rejection, tampered plan identity, 300-record bounded aggregation, and
  legacy decoding without the optional plan fields. The first full
  queue run retained three failures because substring matching treated
  “implementation” as the mutation verb “implement”; exact normalized token
  matching corrected the classifier. The first AC-02 UI run then failed because
  its new completion-plan fixture used the descriptor's scalar project wire
  shape inside the typed plan; the corrected wrapper shape reached the intended
  run detail. The next run showed SwiftUI's generated disclosure action was not
  reliable through accessibility, so the collapsed Advanced control became an
  explicit native toggle. The identical focused UI test then passed. The final
  queue suite passed 24/24, the focused prepared-run projection test passed, both
  SwiftPM products passed, and the canonical Apple Development-signed Debug
  Xcode build passed. Project-file lint, whitespace, and repository hygiene also
  passed; all edited source and test files were already in the canonical graph.
- AU-01 focused verification covers exact-hash selection after deleting the
  original source, ordered multi-package composition, idempotent run binding,
  authenticated package-ID transport, concise quick-text artifact publication,
  selected-file import, preparation-before-start ordering, stale-generation
  reassembly, and exact lost-response replay. The full 20-test instruction
  queue suite and 10-test operator contract suite pass; the authenticated
  manager route case also passes. Three focused signed native UI cases pass:
  an existing package alone enables Start through a native checkbox, ordinary
  Start retains its compact typed surface, and uncertain Start reuses its exact
  client run identity. Both SwiftPM products and the canonical Apple
  Development-signed Debug Xcode build pass. Exact receipts and the retained
  non-passing UI attempts are recorded in the roadmap.
- Four focused signed native UI cases verify that ordinary Start has no raw
  technical editors, Customize exposes only typed task/model/network controls,
  the reusable permission editor retains mouse/keyboard/mixed-state and relaunch
  behavior, uncertain Start replays one byte-identical prepared request, and
  nested Guided Mode help preserves the instruction draft. The focused
  `OperatorProjectContractTests` passed 9/9; both SwiftPM products and the
  canonical Apple Development-signed Debug app build also passed.
- The configured-start reproducer now passes with only its project and
  instructions supplied by the user fixture.
- The real manager/provider configuration test passes and verifies that the
  published defaults contain only registered tools, the saved model, the native
  host adapter, the built-in completion check, and no network grant.
- The configured app request encodes no provider, adapter, model, tool, gate, or
  network key when manager defaults are unchanged; changed typed values are
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
- The project-bound readiness regression exercises all six required states and
  their exact typed recovery actions. The native client regression separately
  proves a missing saved model returns `waiting_dependency` with
  `configure_provider`, keeps minimal Start enabled, and submits no run.
- The stale-generation client regression proves `automatically_preparing`
  returns the committed generation, performs one bounded automatic
  re-preparation, and submits exactly one Start with that refreshed generation.
- The queue regression verifies that queued work persists the same descriptor,
  provider/catalog/budget revisions, continuity mode, and immutable package
  snapshot hash. The storage regression independently hashes the accepted
  owner-only document after the original source changes.
- Nineteen instruction-store/queue tests cover the 1/32,767/32,768/32,769-byte
  boundaries and a 1.1 MiB file, a 66-document folder above 8 MiB including a
  hidden file, UTF-16 and multi-scalar seven-byte delivery windows, exact
  reassembly, native RTF/HTML/DOCX conversion, malformed PDF and opaque-binary
  unresolved states, bounded ZIP import including hidden/native documents,
  traversal/encryption/link/expansion rejection, nested-ZIP retention,
  project/generation/run isolation, schema-1 queue migration, immutable
  originals, ordering, restart, and completion advance behavior.
- Seven catalog, ten provider/preparation, nine operator-contract, and 122
  Manager tests passed after the scoped readers entered the production catalog;
  Manager retained two explicit environment/helper skips. Both SwiftPM products
  and the canonical Apple Development-signed Debug Xcode build passed. The
  matching Xcode app-hosted test passed with multi-megabyte pasted instructions
  and selected/drop-source artifact semantics.
- The authenticated project-registration regression first failed because the
  new authorization field was rejected. It now proves that one request retains
  an existing root, adds only the selected canonical directory, persists the
  result across reload, and rejects a non-Boolean authorization value without
  changing settings.
- The registration transport regression proves that a lost response replays
  the byte-identical body and credential, including the explicit project-root
  authorization. Native picker and direct-path UI coverage now read back the
  authorized root, including after relaunch.
- Seven catalog tests verify durable explicit denials, add/remove/disable
  reconciliation, current eligible Allow all behavior, unavailable explanations,
  revision fencing, and the existing production catalog contract.
- Nine provider-configuration tests include authenticated project-preference
  read/update routes, exact project/generation binding, saved-grant preparation,
  and fail-closed Select none behavior.
- The focused signed native UI test verifies individual mouse and Space-key
  interaction, mixed and checked states, category/all controls, Select none,
  Restore recommended, update counts, and preference recovery after relaunch.
- Eight operator-project/app-contract tests, nine provider-configuration tests,
  seven catalog tests, seven dashboard-security tests, and 122 Manager tests passed.
  The Manager class retained two explicit environment/helper skips and had zero
  failures.
- Both SwiftPM products and the canonical `ForgeConductor` Debug Xcode scheme
  built successfully. Repository hygiene and `git diff --check` passed.
- Unexecuted revision-2 acceptance tests remain `not_run`; this record does not
  promote them to passing.
