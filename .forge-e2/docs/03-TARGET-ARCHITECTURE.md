# Target Architecture

```text
ToolRouter
  ├── ToolAuthorizationService
  │     └── FilesystemCapabilityAuthorizer
  │           ├── ProjectRootRegistry
  │           ├── security-scoped bookmark resolver
  │           └── pinned root identity verification
  │
  └── FilesystemToolPack
        └── SecureFilesystemBroker actor
              ├── CForgeSecureFS thin Darwin shim
              ├── DescriptorWalker
              ├── AtomicNamespaceTransaction
              ├── DescriptorCopier
              ├── FilesystemTransactionRepository
              └── FilesystemRecoveryWorker
```

## Typed authorization result

Replace the path-only authorization handoff with a typed internal result.

Suggested form:

```swift
public struct AuthorizedToolInvocation: Sendable {
    public let sanitizedArguments: [String: Any]
    public let filesystemAccesses: [String: AuthorizedFilesystemPath]
}

public struct AuthorizedFilesystemPath: Sendable {
    public let projectID: ProjectID
    public let generation: ProjectGeneration
    public let root: AuthorizedRootHandle
    public let relativeComponents: [String]
    public let mode: FilesystemAccessMode
    public let displayURL: URL
}
```

`AuthorizedRootHandle` owns an invocation-scoped descriptor and balanced
security-scope lease. It is not encoded, persisted, or exposed over MCP.

Do not hide a capability identifier in model-visible arguments. Keep the
typed capability on the internal router-to-tool boundary.

## Root registry

Persist for every writable project root:

```text
project_id
project_generation
root_id
display_path
volume_identifier
device
inode
mode
owner
bookmark_data or bookmark reference
bookmark_digest
registered_at
last_verified_at
```

On the current process:

1. resolve the bookmark with file-ID preference when available;
2. start security-scoped access if required;
3. open the root with strict flags;
4. `fstat` the descriptor;
5. compare identity and project generation;
6. create the invocation capability;
7. balance security-scope access when the handle closes.

A moved root may be recovered through its bookmark and file identity. A
different object at the former path is never adopted implicitly.

## Per-volume transaction roots

The manager maintains a pinned, mode-0700 transaction root for every volume that
receives destructive operations. The root is excluded from model-facing filesystem
capabilities and shell-based implementation paths. Where sandbox scope prevents a
private sibling location, use a reserved directory inside the granted root only after
recording that policy, denying it through all connector tools, and retaining the
same-user-process nonclaim. Never use a predictable temporary directory.

## C interoperability target

Add a small target such as:

```text
Sources/CForgeSecureFS/
  include/CForgeSecureFS.h
  CForgeSecureFS.c
```

The target wraps only:

- checked flag composition;
- `openat`;
- `renameatx_np`;
- `mkdirat`;
- `unlinkat`;
- `fstatat`;
- descriptor duplication and directory iteration helpers;
- API/volume feature probes.

Do not put policy, retries, transaction state, JSON, SQLite, or project
logic in C.

## Concurrency

`SecureFilesystemBroker` is an actor with bounded admission:

- low-memory profile: one tree mutation and two read operations;
- standard profile: two tree mutations and four reads;
- expanded profile: four tree mutations and eight reads.

Serialize mutations by `{rootID, relative path prefix}`. Unrelated project
roots may execute concurrently.

## Integration boundary

The secure broker must serve:

- `fs_read`
- `fs_write`
- `fs_edit`
- `fs_list`
- `fs_glob`
- `fs_mkdir`
- `fs_delete`
- `fs_move`
- package ingestion
- reset backup/rotation file operations where they share the same risk
- Git and runtime cwd validation through root capabilities

Shell tools remain available. They do not become the implementation of the
secure filesystem broker.
