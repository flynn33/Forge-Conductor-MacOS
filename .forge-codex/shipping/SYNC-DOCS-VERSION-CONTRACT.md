# Mandatory source, documentation, Xcode, and version closure

This is part of implementation, not cleanup after the code is declared finished.

## 1. Establish the actual source locations

Record the absolute path of Flynn's canonical checkout, the execution checkout, Git common directory, branch, upstream, and both fetch/push destinations. `git worktree list --porcelain` exposes linked worktrees but cannot discover every unrelated clone; inspect the project location already opened by the user before assuming the execution worktree is canonical. A genuinely unresolved canonical location is a local-delivery blocker, not permission to overwrite the first similarly named directory.

Inspect `git status --porcelain=v1 --untracked-files=all`, `git branch -vv`, and `git remote -v` locally. Never publish credentials embedded in URLs. Fetch the existing authorized remote without force or pruning unrelated refs. Compare local and live remote SHAs. Do not reset to the audit SHA, replay merged PR #20, delete branches, automatically stash, or replace a dirty checkout. Preserve unrelated work and reconcile safely. A conflicting human edit needs a targeted resolution, not a mass reset.

## 2. Every coherent checkpoint is one complete change

Before staging, inspect the diff and associate each change with its feature and tests. Include changed Swift files, actual Xcode source/resource/test membership, necessary Package.swift changes, the version-impact decision, and relevant documentation. Stage named files, review the staged diff, then commit with the repository's existing human author configuration. Do not alter authorship identity or add attribution trailers.

A product behavior change requires a CHANGELOG entry. Review README, USER-GUIDE, XCODE, and relevant `docs/` pages. Each review must be either `updated` with a real diff or `not_applicable` with a concrete reason. Empty explanations and touching timestamps do not count. For the final release range, README, CHANGELOG, USER-GUIDE, and XCODE must all reflect the final version, supported installation path, current capabilities, and known limitations. Historical changelog entries and evidence must not be rewritten to pretend they used today's version.

Use `templates/doc-impact.json` for the current checkpoint and the `docs` guard against the correct base. Keep the current checkpoint review with the existing handoff; do not create a second gate state system. The guard checks file changes and review coverage, not the semantic truth of prose. Review the actual content.

## 3. Xcode and SwiftPM must describe the same shipped application

The audited project uses explicit PBX file references and compile phases. Adding a Swift file on disk does NOT add it to Xcode. For every added, moved, or removed file, update its intended group, file reference, compile/resource phase, relevant target dependency, test target, resource bundle, and shared scheme as applicable. Remove obsolete references, not product features.

The native session-host source is a separate SwiftPM target but is compiled into the Xcode Core target in the audited project. Preserve that intentional module distinction. Do not duplicate definitions or load another static protocol copy into a test process. Preserve the dedicated app-hosted test target rather than converting unrelated tests.

Run native project parsing and `xcodebuild -list`; inspect effective Debug and Release build settings. Build both the app and CLI paths. Verify that the archived app contains its matching Core framework, embedded CLI, runtime launcher, daemon, LaunchDaemon plist, icons, and resources. Signed peer hashes must refer to the artifacts actually installed. Qualification-only adversary/harness products must not become shipping dependencies or archive contents.

The supplied `xcode` guard verifies tracked source-file membership against native plist-parsed PBX targets. It is a source membership check, not proof of resource placement, linking, signing, test execution, or archive completeness. Its non-macOS result is NOT RUN, never PASS.

## 4. Version and build are a single change

Observed baseline: marketing `0.9.0`, build `1`, currently consistent in the checked source and Xcode settings. The audit does not mandate `1.0.0` or assume build `2` is unused.

First inventory current local/remote tags, published releases, intended product version, prior distributed builds, and all version-bearing targets. Keep the established marketing version unless the actual release scope or an owner decision warrants another. Advance the build number above every already distributed build for that marketing version. Record the chosen identity and basis in the current handoff. Private development source commits do not each need a new marketing version, but a new candidate artifact must not impersonate a previously delivered build with different inputs.

For this run, use the existing `ForgeFilesystemProtocolConstants.productVersion` and `productBuildVersion` as the reference pair and check all derived surfaces; a broad version-generator migration is not required. Update all version-bearing Xcode Debug/Release configurations and any resolved plist values in the same commit. Preserve the distinction between product versions, filesystem protocol version `5`, canonicalization/schema versions, package-tool VERSION files, and historical examples. Never perform an unrestricted global replacement.

Repair `FORGE_BUILD_NUMBER` so it cannot silently override the plist without changing compiled identity: either reject a value differing from the canonical build or implement a tested unified generation path before compiling every target. Reject unknown, malformed, or ambiguous versions. Re-run version checks on effective Xcode settings and the built app, not just source regexes. Inspect embedded CLI identity and CLI `version`; do not change its established output contract merely to add a build number.

Do not mutate a signed bundle to fix its version. Rebuild and re-sign a coherent product. DevelopmentRelease trust policy must never leak into the distributable.

## 5. Synchronization requires server read-back

After a permitted checkpoint push, fetch and compare local HEAD, upstream, and the live server branch with `git ls-remote`. A successful push message or cached `origin/main` alone is insufficient. The supplied `sync` guard checks the exact current branch against both configured fetch and push destinations; it does not push or modify files.

Run it against the execution checkout and, separately, the canonical checkout on the branch each is actually meant to track. Before merge, a canonical `main` synchronized to `origin/main` may still lack the unmerged shipping work. Say so. Never report feature delivery to the canonical checkout just because both branches independently match their remotes.

Once the owner-authorized merge occurs, safely fast-forward a clean canonical main to the live remote main. Do not move another worktree's checked-out branch behind its back. Re-open/parse the canonical Xcode project, verify its version and files, and perform at least build/startup verification from that exact final source. If a squash merge changes the commit ID, preserve the tested-source manifest and requalify the final candidate as required; do not assume ancestor identity. A dirty canonical checkout remains an explicit synchronization blocker until safely reconciled.

## 6. Freeze without a self-referential hash loop

Record a **source candidate SHA** before the final build. Record its complete build-input manifest, toolchain/configuration, artifact SHA-256 values, and signing identities. Evidence may be committed in a later **delivery SHA**. Do not endlessly amend a commit to insert its own hash. An evidence-only delivery commit does not prove identical build inputs by assertion: compare all actual build inputs, including resources, project files, scripts and any version generation. A code, dependency, build setting, script, or resource change requires a new candidate and rerun of affected qualification.

Secure timestamps mean independent signed builds need not have identical bytes. Record the identity of the artifact tested and distributed, rather than promising byte-identical independently signed builds.

## Required final table

Show canonical path/branch/HEAD, execution path/branch/HEAD, live remote fetch/push refs, clean/dirty state, source-candidate SHA, delivery/merge SHA, product version/build, Xcode workspace/schemes, documentation review, archive/export paths, and distribution hashes. State review/merge/publication permission separately from technical readiness. Every unknown remains unknown until checked.
