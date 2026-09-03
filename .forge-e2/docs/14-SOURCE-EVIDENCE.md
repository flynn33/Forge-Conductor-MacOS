# Current Source Evidence

## Authoritative repository baseline

```text
repository: flynn33/Forge-Conductor-MacOS
branch: main
commit: 6288210d82270b26add5f0e078d150bc4377bd62
merged PR: #11
title: Harden descriptor-relative filesystem mutations
```

PR #11 reports 33 focused filesystem tests and explicitly leaves
`FC-FILESYSTEM-PATH-TOCTOU-001` at High E2.

Its remaining qualification identifies:

- final-component verification and `unlinkat`/`renameatx_np` as separate
  syscalls;
- pathname anchoring;
- destination-hierarchy creation;
- a hard-link ctime interval.

## Relevant current source

### `ToolAuthorizationService.swift`

Current authorization:

- canonicalizes roots and candidates into URLs;
- resolves symlinks in the deepest existing ancestor;
- returns normalized path strings;
- checks containment by path components.

This is useful policy input but cannot serve as mutation authority.

### `FilesystemToolPack.swift`

Current code already improves ancestor handling with pinned descriptors and
identity checks. The residual remains because:

- `removeEntry` checks with `fstatat` and then calls `unlinkat`;
- `removeVerifiedDeletionCandidate` captures/verifies and then calls
  `unlinkat`;
- `renameExclusively` checks source identity and then calls
  `renameatx_np`;
- `pinnedDirectory` begins from a `realpath` result;
- recursive plans use Foundation enumeration;
- cross-volume copy launches `/bin/cp -pR`;
- destination hierarchy creation occurs before a typed root capability is
  carried into the tool.

## Baseline discipline

Codex must inspect the current checkout because later commits may have
advanced these files. This package names semantic defects, not brittle line
numbers. Never revert a later fix merely to match this evidence.
