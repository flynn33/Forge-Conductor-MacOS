# Current-Main Implementation Change Map

Baseline: `6288210d82270b26add5f0e078d150bc4377bd62` on
`flynn33/Forge-Conductor-MacOS` (`main`). A descendant may move symbols, but the
behavioral replacements remain mandatory.

## `ToolAuthorizationService.swift`

Current behavior returns normalized path strings after canonicalization. Replace the
internal filesystem authorization result with a typed capability request:

```swift
struct AuthorizedFilesystemRequest {
    let invocationContext: ToolInvocationContext
    let access: FilesystemAccessMode
    let source: AuthorizedPathCapability
    let destination: AuthorizedPathCapability?
    let expectedVersion: FilesystemVersionToken?
}
```

Required changes:

- persist root records with root ID, project ID, generation, bookmark reference,
  identity, display path, read/mutation grants, and reserved-name policy;
- select an exact root before dispatch;
- convert only lexically to root-relative components;
- reject a stale project generation before acquiring descriptors;
- acquire and pin the root in `SecureFilesystemBroker`;
- pass opaque capability objects to `FilesystemToolPack`;
- keep sanitized paths only for audit/display;
- retain permitted-home read behavior as read-only root capabilities;
- preserve all non-filesystem authorization behavior.

Do not expand shell authority while doing this work. The shell compatibility contract
remains exactly as currently qualified.

## `ToolRouter.swift` and tool-pack protocol

- characterize every authorization mock and test double first;
- add an internal associated authorization payload or a filesystem-specific dispatch
  path without changing external MCP JSON schemas;
- ensure cancellation/deadline reaches root acquisition, traversal, transaction
  repository commits, copying, recovery, and cleanup;
- preserve late-commit truthful results.

## `FilesystemToolPack.swift`

The current file combines policy-independent algorithms and raw Darwin operations.
Refactor it rather than layering additional comparisons into it.

### Replace path-based reads and traversal

| Current behavior | Required behavior |
|---|---|
| `URL`/path reopening | root capability + components |
| Foundation enumerator | `fdopendir`/`readdir` |
| `/usr/bin/find` | bounded in-process glob over descriptor traversal |
| `realpath` root pinning | selected root descriptor and persisted identity |
| `lstat` absolute paths | `fstatat` relative to pinned parent |

### Replace writes and edits

| Current behavior | Required behavior |
|---|---|
| `Data.write(.atomic)` | staged descriptor write + fsync + exclusive publish/swap |
| `String.write(atomically:)` | versioned staged edit + swap + verify/rollback/quarantine |
| Foundation intermediate directory creation | `mkdirat`/strict reopen/fsync |

Preserve text size, UTF-8, replacement count, response fields, pagination, cancellation,
and error compatibility. Add only documented transaction/version/conflict fields.

### Replace delete

Remove the plan/check/unlink sequence from the authorized namespace. Capture the root
entry atomically into a transaction directory, then descriptor-traverse and dispose of
the capture. The old compare/mutate hooks remain only in a regression fixture showing
why the design changed.

### Replace move

- same volume current-entry: one atomic exclusive descriptor-relative rename;
- exact version: capture, verify, publish or restore/quarantine;
- cross volume: source capture, native descriptor copy, destination staging, durable
  exclusive publication, source disposal;
- eliminate `/bin/cp -pR` from the secure path;
- preserve existing result fields and late-commit handling.

## New `CForgeSecureFS` target

Add a thin C target to `Package.swift` and the Xcode project. It owns only:

- checked imports of Darwin constants and syscalls;
- descriptor RAII entry points callable from Swift;
- component validation at the ABI boundary;
- wrappers that preserve `errno` immediately;
- directory iteration records with bounded names;
- public-SDK availability and runtime capability probing.

It must not own authorization, project selection, transaction state, retries, logging,
or business policy.

## New Swift components

Suggested files, adapted to repository conventions:

```text
Sources/ForgeConductorCore/Filesystem/
  AuthorizedPathCapability.swift
  FilesystemRootRegistry.swift
  SecureFilesystemBroker.swift
  FilesystemTransactionModels.swift
  FilesystemTransactionRepository.swift
  FilesystemRecoveryWorker.swift
  DescriptorTreeWalker.swift
  DescriptorTreeCopier.swift
  FilesystemVersioning.swift
  FilesystemQuarantineService.swift
```

Use actors for mutation admission, per-project generation fencing, and recovery.
Do not put open descriptors in `Sendable` value types without a proven ownership
wrapper.

## Control-plane integration

Integrate `schemas/filesystem-transactions.sql` into the existing migration system.
Do not create an uncoordinated second SQLite database. Required migration behavior:

- backup/recovery follows the repository's already-qualified migration path;
- schema changes are idempotent;
- old binaries either tolerate the additive tables or are blocked by the existing
  version policy;
- no root bookmark bytes or descriptor numbers appear in audit JSON.

## Manager lifecycle

The LaunchAgent manager is the sole recovery owner:

- recover nonterminal filesystem transactions before admitting new destructive work;
- limit concurrent mutations by memory profile and project;
- pause project mutations during reset;
- reject stale-generation work;
- continue independent projects when one project is quarantined;
- expose bounded status and receipts to the GUI/diagnostics.

## Package ingestion

Route package ingestion through the same broker. Never inspect, hash, unzip, or execute
a watched package directly from its source path. Atomically capture or descriptor-copy
it into immutable managed storage, validate there, and bind the resulting digest to the
queue assignment.

## Tests to edit or add

At minimum:

```text
Tests/ForgeConductorTests/FilesystemAuthorizationCapabilityTests.swift
Tests/ForgeConductorTests/FilesystemAtomicCaptureTests.swift
Tests/ForgeConductorTests/FilesystemAtomicPublicationTests.swift
Tests/ForgeConductorTests/FilesystemRecoveryTests.swift
Tests/ForgeConductorTests/FilesystemHardLinkTests.swift
Tests/ForgeConductorTests/FilesystemPackageIngestionTests.swift
Tests/ForgeConductorTests/FilesystemCompatibilityTests.swift
Tests/ForgeConductorTests/FilesystemResourceBudgetTests.swift
```

Retain and adapt `FilesystemCancellationTests.swift`; do not delete PR #11 evidence or
weaken its assertions.
