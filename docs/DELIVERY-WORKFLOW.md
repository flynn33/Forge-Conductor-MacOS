# Local-first project delivery

## Authority and evidence

The owner authorizes continuous completion toward a fully functional, feature-complete, shippable build. Work remains small, coherent, tested, and local-first. The owner will ship the final build. The canonical record is [ROADMAP.md](../ROADMAP.md); its phase/milestone rows track outcomes and do not dispatch tasks. The earlier [functional development build](FUNCTIONAL-DEVELOPMENT-BUILD.md) is historical scope, not the current acceptance target.

“Implemented” means code exists. “Fixture verified” means the selected deterministic test executed. “Native executed” means the intended real app path ran. “Live provider verified” requires actual provider responses and consumed ordinary work. None alone implies full distribution or desktop qualification. A deferred requirement is not complete.

## Before each direct update

Confirm the exact repository and `main` revision. Preserve unrelated or uncommitted work. Fetch the verified remote and safely fast-forward clean local `main` before new work. The owner requests no pull requests and no stray branches. Never reset/stash/discard owner work or force-push. Make and test product edits locally before publishing them through the owner's GitHub account.

Read only relevant source and tests. Reuse native modules and existing focused checks. Make a small evidence-supported repair or record verified existing behavior without unnecessary source changes. Use direct native tools and inspected narrow build/test/evidence utilities; do not create or revive task selectors or broad archived gate runners. Existing repository CI and internal build phases remain intact.

Run `script/check_repository_hygiene.sh` before publication. Product versions
follow the [versioning policy](VERSIONING.md): `VERSION`, `BUILD_NUMBER`, native
runtime constants, Xcode settings, the changelog, and current guides advance
together. Historical receipts keep their tested identity.

## Xcode synchronization on every source update

The canonical entry is `ForgeConductor.xcworkspace`, containing the existing `ForgeConductor.xcodeproj`. `Package.swift` describes overlapping native products; it is not a substitute for Xcode target membership or bundle layout.

For changed/added/renamed Swift sources, tests, resources, helpers, or build files, verify the correct target Sources, Resources, Copy Files, dependency, and scheme memberships. A navigator entry alone is insufficient. Update the existing project only when membership actually changes. Preserve configured signing, deployment settings, and product identities. Do not regenerate or duplicate the project.

For documentation-only updates, verify the graph was not changed and record that fact; do not manufacture a project edit or rerun the app. Native source/resource/graph changes require the appropriate workspace build and relevant focused test. Use separate ordinary app and test output directories: test-only entitlements or instrumented products must not become the installable candidate. Keep the working orchestration installation separate from candidate builds.

## Direct publication and roadmap update

Every direct update, including documentation and blocker-status updates, updates the affected roadmap row. Record phase/milestone, behavior changed or verified, actual evidence, and limitation/blocker. Historical PR links remain evidence for their original revisions. Avoid duplicate progress ledgers and invented issue or milestone numbers.

Publish only tested, explicit intended paths directly to `main` under the owner's GitHub identity, using an existing authorized signing or owner web-commit route. Verify the published file content and remote revision, then safely synchronize local `main`. The owner authorizes the repository's existing Admin Role bypass if needed, but a bypass does not turn a failed check into a pass. Preserve contribution and identity rules. An unavailable owner publishing or signing capability blocks publication, not local build/test/implementation work, and is not an invitation to create credentials or install an API wrapper.

At meaningful checkpoints, verify local `main`, remote `main`, and the tested-source inputs agree. Retain the tested-source identity when only documentation follows a test. Do not make self-referential commit hashes trigger endless edits.

Report actual check results. A zero-test selection, skipped test, timeout, queued workflow, or incomplete output is not a pass. Do not disable failed assertions, signing, or required repository checks. A source change after a test requires an affected rerun; a pure link update does not require an identical full build.

A blocker-status update may contain only reviewed documentation, not staged untested production work. Its milestone remains blocked and its description must not call it an implementation completion.

## Acceptance

The owner authorizes direct `main` updates without a pull request. Continue independent authorized completion work while CI or a release capability is pending. A published update is source delivery, not feature or release qualification; actual runtime, signing, recovery, and distribution evidence determine acceptance.

Reconcile stale ready/merged wording in the next affected roadmap update. Keep historical PR records tied to their original revisions.

## After each direct update

Confirm the exact published files and owner-authored remote revision. Preserve local work, fetch, and safely synchronize local `main`; confirm local `main` matches remote `main`. Check the canonical workspace and any newly incorporated source/resource/build changes. No separate synchronization-only assignment is required.

Reuse the prior result only when the relevant source/build inputs are identical. Check changed inputs with their smallest affected build/test. Record local/remote `main` identity, workspace/membership result, actual or reused evidence, and unresolved items in the affected roadmap row or build record. Do not silently claim full synchronization.

No constant polling, custom synchronization script, or second checkout is needed.

## Phase closeout

The closing direct update for each phase must update `README.md`, the existing Unreleased section of `CHANGELOG.md`, the roadmap, and the affected current documents. Examples include the build guide for changed native build behavior, the user guide for new UI behavior, and continuity documentation for a changed handoff contract. Review relevant documents; do not touch unrelated files just to increase the count.

Record completed scope, actual evidence/revisions, what did not run, and remaining requirements. Use “verified” rather than “fixed” when no production defect was repaired. Keep historical release text and product identity unchanged. A separate small documentation-only closeout is permitted. A phase is accepted only after its required milestones and documentation are accepted; unfinished work remains open.

Independent milestones inside the current completion scope may proceed while another gate is blocked. For example, an open desktop attachment requirement does not prohibit a manager-owned API experiment, but that experiment cannot close desktop attachment.

## Enforcement boundary

These are operator delivery obligations. They do not install or claim automatic CI enforcement of roadmap edits or local Mac synchronization. Existing repository checks remain authoritative for what they actually test. No additional automation is required to follow this workflow.
