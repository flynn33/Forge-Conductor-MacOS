# Local-first project delivery

## Authority and evidence

The owner authorizes one small slice. The canonical record is [ROADMAP.md](../ROADMAP.md); its phase/milestone rows track outcomes and do not dispatch tasks. Historical plans remain evidence, not competing instructions.

“Implemented” means code exists. “Fixture verified” means the selected deterministic test executed. “Native executed” means the intended real app path ran. “Live provider verified” requires actual provider responses and consumed ordinary work. None alone implies full distribution or desktop qualification. A deferred requirement is not complete.

## Before each PR

Confirm the exact repository and current branch. Preserve unrelated or uncommitted work. For a new authorized slice, confirm the preceding PR merged, fetch the verified remote, fast-forward clean local main, and create a new branch. Never reset/stash/discard owner work, force-push, or make product-file commits only on GitHub.

Read only relevant source and tests. Reuse native modules and existing focused checks. Make a small evidence-supported repair or record verified existing behavior without unnecessary source changes. Use direct native tools, no new helper scripts or task selectors. Existing repository CI and internal build phases remain intact.

## Xcode synchronization on every PR

The canonical entry is `ForgeConductor.xcworkspace`, containing the existing `ForgeConductor.xcodeproj`. `Package.swift` describes overlapping native products; it is not a substitute for Xcode target membership or bundle layout.

For changed/added/renamed Swift sources, tests, resources, helpers, or build files, verify the correct target Sources, Resources, Copy Files, dependency, and scheme memberships. A navigator entry alone is insufficient. Update the existing project only when membership actually changes. Preserve configured signing, deployment settings, and product identities. Do not regenerate or duplicate the project.

For documentation-only PRs, verify the graph was not changed and record that fact; do not manufacture a project edit or rerun the app. Native source/resource/graph changes require the appropriate workspace build and relevant focused test. Use separate ordinary app and test output directories: test-only entitlements or instrumented products must not become the installable candidate. Do not replace the working orchestration installation during development.

## Publication and roadmap update

Every PR, including documentation, verification-only, corrective, and blocker-status PRs, updates the affected roadmap row. Record phase/milestone, behavior changed or verified, actual evidence, limitation/blocker, and the real PR link. Avoid duplicate progress ledgers and invented issue or milestone numbers.

Commit tested changes locally with existing owner identity/signing, stage only explicit intended paths, then push the slice branch. Create one PR to main with the actual exposed GitHub tool. Preserve contribution and identity rules. An unavailable publishing capability is an explicit blocker, not an invitation to install an API wrapper.

Before the PR number exists, a roadmap row can identify its branch. After creation, add the real link in a local documentation-only follow-up commit to that same branch and push it. No new PR or forced rewrite is needed. Confirm final local, remote, and PR branch heads agree. Retain the tested-source identity and state when only documentation followed that test. Do not make self-referential commit hashes trigger endless edits.

Report actual check results. A zero-test selection, skipped test, timeout, queued workflow, or incomplete output is not a pass. Do not disable failed assertions, signing, or required repository checks. A source change after a test requires an affected rerun; a pure link update does not require an identical full build.

A blocker-status PR may contain only reviewed documentation, not staged untested production work. Its milestone remains blocked and its description must not call it an implementation completion.

## Review and acceptance

After the PR is verified, stop for owner review. Do not merge, enable auto-merge, poll for approval, or start another slice. GitHub merge state determines whether linked work is accepted. A roadmap row labelled “ready in linked PR” is a proposal until that PR is merged; no static checkbox overrides the actual merge state.

The next owner-authorized update reconciles stale ready/merged wording from the preceding PR. The merge receipt is recorded on the exact PR, avoiding an unnecessary new commit whose sole purpose would be recording itself.

## After each merge

The owner explicitly starts a synchronization-only step. Confirm the exact PR merged into main. Preserve local work, fetch, and fast-forward clean local main. Confirm local main matches remote main. Check the canonical workspace and any newly incorporated source/resource/build changes.

Reuse the prior result only when the relevant source/build inputs are identical. Check a changed merged input with its smallest affected build/test; do not mistake a squash commit's different hash alone for changed source. Record local/remote main identity, workspace/membership result, actual or reused evidence, and unresolved items in a comment on that merged PR. If commenting fails, retain the receipt in the session and state it was not published. Do not silently claim full synchronization.

This step does not authorize another feature slice. No constant polling, custom synchronization script, or second checkout is needed.

## Phase closeout

The closing PR for each phase must update `README.md`, the existing Unreleased section of `CHANGELOG.md`, the roadmap, and the affected current documents. Examples include the build guide for changed native build behavior, the user guide for new UI behavior, and continuity documentation for a changed handoff contract. Review relevant documents; do not touch unrelated files just to increase the count.

Record completed scope, actual evidence/PRs, what did not run, and remaining requirements. Use “verified” rather than “fixed” when no production defect was repaired. Keep historical release text and product identity unchanged. A separate small documentation-only closeout is permitted. A phase is accepted only after its required milestones and documentation are accepted; unfinished work remains open or explicitly owner-deferred.

Independent milestones can proceed only when separately owner-authorized. For example, an open desktop attachment requirement does not prohibit a manager-owned API experiment, but that experiment cannot close desktop attachment.

## Enforcement boundary

These are agent/operator delivery obligations and a PR-review checklist. They do not install or claim automatic CI enforcement of roadmap edits or local Mac synchronization. Existing repository checks remain authoritative for what they actually test. No additional automation is required to follow this workflow.
