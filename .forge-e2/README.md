# Forge Conductor E2 Secure Filesystem Remediation Package

This package directs Codex to close `FC-FILESYSTEM-PATH-TOCTOU-001` (E2)
without removing any Forge Conductor feature.

The implementation target is the current `main` branch of
`flynn33/Forge-Conductor-MacOS`, beginning at or after:

```text
6288210d82270b26add5f0e078d150bc4377bd62
```

That commit merged PR #11, **Harden descriptor-relative filesystem
mutations**, while explicitly leaving E2 open.

## Start

From this package directory:

```bash
./scripts/install_into_repo.sh /absolute/path/to/Forge-Conductor-MacOS
cd /absolute/path/to/Forge-Conductor-MacOS
./.forge-e2/scripts/bootstrap.sh
```

Codex must then read, in order:

1. `.forge-e2/CODEX-START-HERE.md`
2. repository `AGENTS.md`
3. `.forge-e2/AGENTS.md`
4. `.forge-e2/work/work-packages.json`
5. `.forge-e2/docs/13-RELEASE-COMPLETION-CONTRACT.md`

The package is restartable. State is stored under:

```text
.forge-e2-state/
```

## Non-negotiable product invariants

- `shell_exec` remains available and enabled by default.
- Existing `shell_exec` behavior is not silently replaced.
- `process.run`, `shell.run`, `bash.run`, `python.run`, and
  `powershell.run` remain additive.
- Project memory, project isolation, managed autonomy, and continuity
  rollover remain operational.
- No path-string validation result is used later as mutation authority.
- No E2 completion claim is allowed until the macOS 26 qualification
  suite passes.
- Commits, pull requests, source, evidence, and release notes contain
  no automated-authorship attribution or attribution trailers.

## Core security decision

E2 is closed by changing the operation contract:

```text
validate path -> later mutate path        [forbidden]

authorize root capability
    -> pin directories
    -> atomically capture or publish namespace entry
    -> validate the captured object
    -> commit, restore, or quarantine      [required]
```

macOS does not expose a public “unlink this pathname only if it still
names inode X” operation. Codex must not simulate that contract with a
check followed by `unlinkat` or `renameatx_np`.

For destructive operations, the atomic rename is the linearization
point. A caller that supplies an exact version precondition receives
one of three outcomes:

- committed;
- restored with a conflict result;
- preserved in bounded quarantine with a conflict receipt.

A mismatched object is never destroyed.

## Package map

- `docs/17-ATOMIC-CAPTURE-PSEUDOCODE.md` defines syscall linearization and
  restore/quarantine behavior.
- `docs/18-IMPLEMENTATION-CHANGE-MAP.md` maps the design onto current `main`.
- `docs/19-E2-CLOSURE-ARGUMENT.md` states the safety proof and nonclaims.
- `docs/20-FILESYSTEM-CAPABILITY-AND-VOLUME-MATRIX.md` defines runtime volume
  qualification.
- `docs/21-MIGRATION-ROLLOUT-AND-COMPATIBILITY.md` preserves public behavior.
- `work/work-packages.json` is the dependency-ordered autonomous execution plan.
- `scripts/run_e2_qualification.sh` records the required evidence boundary.

The included repository ZIP predates merged PR #11 and is evidence only. The baseline
guard requires the implementation checkout to contain commit
`6288210d82270b26add5f0e078d150bc4377bd62` or a descendant.
