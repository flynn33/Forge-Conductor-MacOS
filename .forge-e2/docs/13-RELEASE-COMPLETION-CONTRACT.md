# Release Completion Contract

Codex may close E2 only when every hard gate below is green.

## Hard gates

- `E2-G01` baseline and feature inventory recorded.
- `E2-G02` macOS public API probe passed.
- `E2-G03` typed root capabilities replace path-string authority.
- `E2-G04` read/list/glob/mkdir use descriptor resolution.
- `E2-G05` write/edit use staged atomic publication and version conflicts.
- `E2-G06` delete uses atomic capture before validation/disposal.
- `E2-G07` same-volume move has no final compare/rename race.
- `E2-G08` cross-volume move captures source and descriptor-copies.
- `E2-G09` package ingestion operates on immutable managed snapshots.
- `E2-G10` crash recovery passes every transaction state.
- `E2-G11` adversarial sentinel matrix passes.
- `E2-G12` full SwiftPM serial and parallel suites pass.
- `E2-G13` Xcode Debug and Release build/test pass.
- `E2-G14` shell preservation gate passes.
- `E2-G15` project memory, continuity, autonomy, and manager restart gates
  pass.
- `E2-G16` constrained-memory and descriptor budgets pass.
- `E2-G17` attribution and secret scans pass.
- `E2-G18` source guard finds no forbidden path mutation in the secure
  surface.
- `E2-G19` PR description states the exact security contract and evidence.
- `E2-G20` repository doctor and state selector report no open E2 item.

## Required finding disposition

`FC-FILESYSTEM-PATH-TOCTOU-001` may be marked closed only with:

- source paths and line ranges;
- test evidence identifiers;
- macOS/SDK/Xcode versions;
- filesystem types tested;
- race iteration counts;
- sentinel digests;
- crash-state matrix;
- performance measurements;
- shell preservation evidence;
- residual threat statement.

## Residual statement

The final report must distinguish:

- closed path-resolution and namespace-mutation races;
- unsupported filesystems that fail closed;
- same-user OS processes outside Forge's application trust boundary;
- App Sandbox/XPC isolation, if separately implemented.

Do not call an unsupported or untested environment secure.

## Publication

Before PR creation:

```bash
python3 .forge-e2/scripts/validate_completion.py
python3 .forge-e2/scripts/check_attribution.py .
python3 .forge-e2/scripts/check_shell_preservation.py
```

The pull request must be focused, mergeable against current `main`, and
contain no attribution trailers.
