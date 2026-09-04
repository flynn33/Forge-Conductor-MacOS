# Shipping execution

The owner selected the September 4, 2026 shipping package as the current
execution authority. Earlier instruction packages remain historical inputs;
do not reinstall them or use their independent state systems. Preserve
existing feature, security, continuity, and evidence requirements.

Use work orders A through E in `work-orders/`, the
`SYNC-DOCS-VERSION-CONTRACT.md`, `MACOS-VALIDATION-RUNBOOK.md`, and
`RELEASE-GATES.md`. The authoritative state remains `.forge-codex/state`.
Implementation, local commits, and permitted branch synchronization are
authorized. The owner performs shipping; do not merge protected branches,
publish a release, or submit distribution without appropriate authority.

Run the existing doctor, statectl show, and selector on resume, read the
current handoff, inspect live Git state, and continue current ready work.
Do not restart completed phases because an old dispatch package is missing.
All hard gates remain binding, including unresolved filesystem containment,
real manager-owned rollover, native product paths, and hardware evidence.
Keep skipped, blocked, failed, and passed distinct.

Each coherent change includes targeted tests, Xcode membership, a build/version
decision, CHANGELOG when behavior changes, and README/USER-GUIDE/XCODE review.
Only the integrator edits shared project/version/state files or controls live
manager, provider, service, and signing state. Independent work uses separate
worktrees and explicit file ownership. No destructive Git cleanup, automatic
stash, force push, user-data deletion, or attribution credits/trailers.

The package targets 24 hours from the recorded start; time is not a release
waiver. Three attempts without new evidence require a diagnostic change.
Continue independent implementation while external qualification is blocked.

The schema-v2 feature baseline is validated with
`python3 .forge-codex/scripts/test_p10_feature_baseline.py`; never overwrite it
with the legacy schema-v1 inventory generator. Completion still requires
`.forge-codex/scripts/verify_completion.py` to exit zero with current evidence.
