# A — Reconcile baseline and restore reliable dispatch

**Goal:** one current source baseline, one task dispatcher, and an early list of owner-controlled dependencies. Do not restart the project.

## Execute

Discover the canonical checkout and execution checkout as described in the synchronization contract. Inspect root/nested AGENTS and any Codex override instructions. Record current branch, dirty files, remotes, worktrees, HEAD, main, and active PRs. Read the current handoff and compare it to live GitHub. Do not fetch or apply PR #20 as new work: it is already merged in the audit baseline. Preserve newer source.

Run `scripts/preflight-macos.sh` from this package with the absolute repository path. This is a read-only inventory; it does not start/stop services or install dependencies. Python 3 is used only for the included testing/automation and the repository already has Python gate tools. If Python is genuinely absent, record that and implement equivalent checks with available native tools; do not turn it into a new application dependency or fabricate a successful run.

Inspect the existing doctor and selector scripts before running them; keep their real gate failures. Correct the dead `.forge-continuity-design` dispatch link. Map its requirements to existing autonomy/provider/continuity implementation, the active `.forge-codex` specifications, and this package's focused work orders. Do not manufacture the missing original file or declare its obligations fulfilled. Keep older documents as history and update the active entry point and handoff. Merge the compact shipping addendum without replacing root rules or globally changing Codex permissions.

Use the existing `.forge-codex` state/evidence workflow. Copy only the needed support documents/scripts from this package under `.forge-codex/shipping/` when useful, with a reviewed normal commit. Do not run old `install_into_repo`/bootstrap tools that replace state. This package itself should remain outside the repo until reviewed; do not commit runtime logs, certificates, model files, or user data.

Inventory Xcode/SDK/Swift versions, macOS/hardware, command availability, Developer ID identity, compiled production team policy, screen/test permission, LM Studio version/active model/API access, and permitted fixture location. The current source expects macOS 26 and Swift tools 6.2, while language mode is 5. Use a compatible installed toolchain; do not do an unrelated Swift 6 language conversion.

Read the real LM Studio configuration through supported product diagnostics without dumping tokens. Do not overwrite the operator's mcp.json or interrupt unrelated chats. Record whether isolated manager/provider/service tests can run safely. Request only genuinely owner-controlled certificate/consent/hardware actions, then continue independent work.

## Baseline proof and acceptance

Capture current Debug/Release build and test results as available, including exact selected/executed/skipped counts and source identity. Distinguish historical evidence from fresh baseline evidence. Read existing hard gates and feature preservation inventory, not just the README. Verify that unresolved filesystem, provider, native lifecycle and hardware gates remain visible.

A is complete when a new session can identify the exact branch and checkout, understand old vs current evidence, run one correct next command, and avoid every missing-path/stale-PR dead end. The source must be preserved, not reset to produce a clean status.
