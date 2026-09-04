# Filesystem Capability and Volume Matrix

Compile-time availability is insufficient. `RENAME_EXCL` and `RENAME_SWAP` are
filesystem capabilities, and removable/network volumes can differ from the system APFS
volume. Codex must probe each mounted volume used for mutation.

## Probe record

Persist a bounded record keyed by stable volume identity:

```text
volume identity
filesystem type
read-only status
case sensitivity
Unicode behavior observed
supports exclusive rename
supports atomic swap
supports directory fsync
supports unique open
supports clone/copy optimization (informational only)
probe timestamp
OS build and SDK build
```

Invalidate the record on mount-generation change, OS upgrade, or an unexpected syscall
capability error.

## Qualification classes

### Class A — fully qualified

- descriptor-relative beneath/no-follow resolution passes;
- exclusive rename passes;
- atomic swap passes;
- directory fsync behavior is accepted;
- crash and race harnesses pass.

All secure filesystem operations are enabled.

### Class B — capture/publish qualified, no swap

- exclusive rename passes;
- swap is unavailable or fails its probe.

Allow current-entry delete/move, create-only write, and cross-volume staging. For
replace/edit requiring swap, use a documented capture-then-exclusive-publish algorithm
only when compatibility tests accept its temporary name gap; otherwise return
`filesystem_capability_unavailable`. Never silently perform an unsafe path write.

### Class C — read-only qualified

Strict descriptor reads/listing work, but safe mutation primitives do not. Permit only
read operations and return a stable nonretryable mutation capability error.

### Unqualified

No model-facing access until the probe finishes or the volume becomes available.

## Probe behavior

The probe must operate in an application-created, mode-0700 test directory on the same
volume and must clean up through pinned descriptors. It must test behavior, not just
constant presence:

- `..` and absolute escapes rejected;
- intermediate symlink rejected;
- final symlink behavior measured for open and rename flag combinations;
- multiple hard link rejected by `O_UNIQUE` when used;
- existing destination rejected by exclusive rename;
- swap exchanges identities atomically;
- destination/source parent fsync succeeds or yields a documented filesystem-specific
  result;
- same-volume and forced-cross-volume paths classified correctly.

## Fail-forward policy

A failed volume probe does not disable shell, memory, continuity, telemetry, or other
projects. It blocks only unsafe filesystem connector mutations on that volume, records
an actionable diagnostic, and continues host-independent work.
