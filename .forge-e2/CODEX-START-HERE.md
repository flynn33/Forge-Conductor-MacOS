# Codex Start Here — Close E2

## Mission

Close `FC-FILESYSTEM-PATH-TOCTOU-001` on the current Forge Conductor
macOS repository without feature loss.

Do not ask the operator for implementation choices. Use the contracts in
this package, inspect the current checkout, make evidence-backed decisions,
and continue through recoverable failures.

## Required first actions

Run:

```bash
git status --short
git rev-parse --verify HEAD
git branch --show-current
python3 .forge-e2/scripts/doctor.py
python3 .forge-e2/scripts/select_next_work.py
```

Record the exact baseline in `.forge-e2-state/baseline.json`.

The expected merged baseline is:

```text
6288210d82270b26add5f0e078d150bc4377bd62
```

A later descendant is acceptable. An older or unrelated checkout is not.
Do not reset, force-push, or overwrite user work. Create a clean worktree
or branch when necessary.

## Required branch and publication behavior

Use a human-readable branch such as:

```text
repair/e2-atomic-filesystem
```

Use the repository's existing human identity. Do not add attribution
trailers, generated-by markers, assistant names, model names, or tool
credits to commits, paths, comments, source, evidence, or pull requests.

Publish one focused pull request against `main` after all host-independent
gates pass. Native macOS gates are release-blocking; run them on the
available macOS 26 host rather than classifying them as optional.

## Definition of E2 closure

E2 is closed only when all of these are true:

1. Filesystem authority is a typed root capability plus relative
   components, not a canonical string.
2. Authorized roots are pinned and identity-checked.
3. Path resolution uses descriptor-relative operations with beneath and
   no-follow rules.
4. Destructive leaf operations do not validate an entry and then mutate
   the same pathname.
5. Delete uses atomic capture into a private transaction namespace before
   inspection or recursive disposal.
6. Same-volume move uses an atomic, exclusive descriptor-relative rename.
7. Exact precondition operations use capture, verify, restore-or-quarantine.
8. Cross-volume move captures the source before copying and publishes only
   a fully synchronized descriptor-copied staging tree.
9. Destination hierarchy creation is descriptor-relative and race-safe.
10. Recursive traversal never follows a symlink and never shells out.
11. Every nonterminal transaction state is recoverable after process death.
12. The adversarial race suite cannot alter any outside-root sentinel.
13. Unsupported filesystems fail closed instead of falling back to
    Foundation path mutation.
14. The runtime volume matrix records strict and leaf-only final-symlink behavior.
15. Shell access remains enabled and fully compatible.
16. Project memory, continuity, and managed autonomy regression suites pass.

## Absolute prohibitions

Do not:

- solve E2 with another `fstatat`/`unlinkat` comparison pair;
- use `realpath`, `resolvingSymlinksInPath`, or string prefix checks as
  mutation authority;
- use `FileManager.removeItem`, `moveItem`, recursive enumerators, or
  `/bin/cp` in the secure mutation path;
- use `/usr/bin/find` for model-controlled filesystem traversal;
- follow a symlink while resolving a mutation path;
- silently fall back to string-path or Foundation mutation when a required
  filesystem primitive is unavailable; classify the volume and fail closed;
- pass a multi-component path to a rename syscall; the measured leaf-only policy for
  final symlink entries is allowed only with pinned parents and validated leaf names;
- disable `shell_exec`;
- change legacy shell semantics under the same tool name;
- mark E2 complete from source review or unit tests alone.

## Execution

Follow `work/work-packages.json` in dependency order. After each work
package:

```bash
python3 .forge-e2/scripts/record_checkpoint.py \
  --work-id <ID> \
  --status passed \
  --evidence <path-to-evidence-json>

python3 .forge-e2/scripts/select_next_work.py
```

On a recoverable failure, record it, preserve evidence, select the next
unblocked diagnostic or remediation action, and continue. Do not erase
failed evidence.
