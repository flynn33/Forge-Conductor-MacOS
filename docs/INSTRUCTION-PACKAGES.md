# Project instruction packages

Instruction packages turn a registered local repository into an ordered work queue. Each accepted package is bound to the selected project UUID and generation. Forge Conductor runs one package at a time in the order shown in **Projects**.

## Setup

1. In LM Studio, load a tool-capable model and start the local server from the Developer screen.
2. In Forge Conductor **Provider**, enter the LM Studio endpoint (commonly `http://127.0.0.1:1234`), load the model list, choose the loaded model, save, and run the connection and contract checks.
3. In **Manager**, add the repository or its parent folder to **Allowed Roots**, apply the setting, and start the manager if it is stopped.
4. In **Projects**, register the local repository folder and select it.
5. Under **Instruction packages**, choose **Add Instructions…**, arrange packages by dragging rows, then choose **Start Ordered Autonomy**.

The question-mark toolbar button opens the same setup sequence inside the app.

## Accepted package formats

### One document

Select a UTF-8 Markdown or text file (`.md`, `.markdown`, or `.txt`). Its contents become the package mission. Forge assigns the standard project editing tool set and the built-in successful-tool completion gate.

### A folder of documents

Select a folder containing Markdown or text files. Forge reads up to 64 non-hidden documents in stable path order and combines them into one mission. Symbolic links are rejected.

### A manifest package

Select a `.forgepackage` JSON file, a `forge-package.json` file, or a folder containing `forge-package.json` or `package.forgepackage`.

```json
{
  "schema_version": 1,
  "package_id": "repair-settings-flow",
  "version": "1.0",
  "mission": "Repair and verify the Settings save flow.",
  "project_id": "optional-exact-registered-project-uuid",
  "entry_documents": [
    "instructions.md",
    "acceptance.md"
  ],
  "requested_capabilities": [
    "fs_read",
    "fs_write",
    "fs_edit",
    "search_text",
    "shell_exec",
    "git_status",
    "git_diff"
  ],
  "completion_gates": [
    "forge.package.tool-success"
  ]
}
```

`entry_documents` must remain inside the selected package folder. `project_id`, when present, must match the selected registered project. Capabilities must name production tools exposed by the current Forge build. The built-in `forge.package.tool-success` gate requires at least one durable tool result from the exact run and rejects unresolved or failed tool invocations.

## Ordering and execution

The Projects list order is authoritative. Drag rows before starting the queue. Forge persists every order change with a queue revision so concurrent or stale edits fail instead of silently overwriting a newer order.

**Start Ordered Autonomy** requires a saved Provider model and a running managed autonomy service. Forge creates a managed run scoped to the registered repository root, package project UUID, and current project generation. It advances to the next queued package only after the current package reaches `completed`. A failed, cancelled, paused, or configuration-blocked run stops automatic advancement so the operator can review it in **Autonomy**.

**Stop Queue** prevents the next package from starting. It does not discard or silently cancel an already admitted autonomous run; that run remains visible in **Autonomy**.

## Storage and project linkage

Forge copies accepted content to an owner-only, content-addressed snapshot under:

```text
~/.forge-conductor/instruction-packages/Store/<sha256>/
```

The durable queue metadata is stored in:

```text
~/.forge-conductor/instruction-packages/queue.json
```

Editing or deleting the original selected file after import does not change the accepted snapshot. Package records include the source path for operator provenance, but autonomous tools receive the registered repository as their filesystem scope.

Queue admission inventories the immutable snapshot's documents and records each
content-addressed reference, byte count, and SHA-256 in the manager-owned
prepared-run descriptor. The durable run also records the descriptor revision,
package snapshot hash, provider and tool-catalog revisions, continuity mode,
and applicable budget-policy revisions. Direct starts use the same preparation
contract, so queued work does not bypass ordinary grant, validation, or stale
input checks.

Resetting a project generation fences unfinished packages from the old generation. Removing a project deletes its active package queue, advances the control-plane generation, invalidates bindings, and hides the registration while preserving project memory and historical run evidence. Registering the same repository again reconnects its durable project identity.

## Limits

- 256 package records per queue store
- 512 content-addressed snapshots, with unreferenced snapshots removed after queue deletion
- 64 source documents per package
- 1 MiB per source document
- 8 MiB aggregate source bytes per package
- 32 KiB combined mission text

All queue mutations use bounded authenticated manager requests. The queue file is written atomically with owner-only permissions, and an unsuccessful persistence write restores the prior in-memory state.
