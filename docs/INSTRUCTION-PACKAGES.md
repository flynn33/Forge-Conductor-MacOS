# Project instruction packages

Instruction packages turn a registered local repository into an ordered work queue. Each accepted package is bound to the selected project UUID and generation. Forge Conductor runs one package at a time in the order shown in **Projects**.

## Setup

1. Start the provider you intend to use. For LM Studio, load a tool-capable
   model; its activation toggle runs **Connect and Check** before selection. For
   Claude Code Desktop or Codex Desktop, start the supported host
   and complete the exact activation, reload, or trust action reported by its
   provider card.
2. In Forge Conductor **Manager**, start the manager if it is stopped.
3. In **Projects**, register the local repository folder and select it. The
   registration authorizes that exact canonical root without widening access to
   its parent.
4. Under **Instruction packages**, choose **Add Instructions…** and arrange
   packages by dragging rows.
5. In **Provider**, select and verify exactly one provider. LM Studio requires a
   current saved model/readiness receipt; desktop providers require a verified
   integration and retain their host-selected model.
   Grok Build remains visible but cannot be selected or admit a run in 0.14.1
   because its documented hook outputs cannot deliver the initial assignment
   context to the model.
6. For an ordinary task, open **Projects → Run Details**, select one or more imported packages,
   and choose **Start Task**. Forge prepares the run against that exact durable
   provider selection and returns one exact Provider action if it is not ready.
   A selectable desktop host receives the exact assignment through its hook and
   must complete the instructed one-time `desktop_run_attach` before any
   project-scoped Forge tool is available.
7. To run the whole project queue, choose **Start Ordered Work** in Projects.
   LM Studio endpoint, credential, exact-model, inventory, and probe controls
   remain under **LM Studio Advanced**; they are not prerequisites for a
   desktop-host run.

The question-mark toolbar button opens the same setup sequence inside the app.

## Accepted package formats

### One document

Select a document in its existing format. Admission is content-aware rather than
based on a filename whitelist. Forge normalizes UTF-8 and BOM-marked UTF-16 text
and uses native PDFKit/AppKit adapters for PDF, DOCX, RTF, and HTML. Every
original is retained. Textless supported images and PDFs receive a bounded
native Vision OCR attempt. The catalog classifies every source as converted
instruction content, retained attachment, unrepresented visual/structural
content, or unresolved conversion. Unsupported or unreadable sources are
retained and reported without blocking readable instructions from the same
package. A source containing no readable instruction text cannot run by itself;
malformed and encrypted failures are named separately.

### A folder of documents

Select a folder containing instruction and support files. Forge inventories
hidden files, rejects symbolic links, preserves stable relative paths, and
stores converted instruction text separately from originals. It creates a
compact bootstrap mission; large documents remain in the artifact for bounded,
project/run-scoped retrieval.

### A ZIP archive

Select or drop a ZIP in its existing form. Forge preflights the container before
native extraction and rejects traversal, duplicate paths, links, encryption,
unsupported compression, excessive entry or aggregate size, excessive expansion
ratios, and local/central-header disagreement. It compares the extracted file
inventory and sizes with the inspected container, observes cancellation during
the bounded native extraction deadline, and removes its private staging tree.
The original archive and accepted inventory remain in the immutable snapshot.
Nested ZIPs are retained unresolved for separate bounded import rather than
recursively expanded.

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

`entry_documents` must remain inside the selected package folder. `project_id`,
when present, must match the selected registered project. Capabilities must name
production tools exposed by the current Forge build. `completion_gates` is the
stable schema key for package-owned completion requirements. Those values are
bound to the immutable package and displayed read-only in Project Runs; Forge
configuration can select only its recognized built-in evidence checks. The
built-in `forge.package.tool-success` requirement needs at least one durable
tool result from the exact run and rejects unresolved or failed tool
invocations.

## Ordering and execution

The Projects list order is authoritative. Drag rows before or during ordered
execution. New packages can be added while work is running. Forge preserves the
active run identity and applies the revised order to pending packages. Every
order change carries a queue revision so concurrent or stale edits fail instead
of silently overwriting a newer order.

**Start Ordered Work** requires one selected, verified provider and a
running managed autonomy service. LM Studio requires its exact saved model;
desktop providers use the model chosen by their host. Forge creates a managed run scoped to the registered
repository root, package project UUID, and current project generation. It
advances to the next queued package only after the current package reaches
`completed`. A failed, cancelled, paused, or terminally failed run stops
automatic advancement so the operator can review it in **Projects → Run Details**. Provider
readiness uses the bounded `waiting_provider` recovery path and resumes the
retained operation automatically after **Connect and Check** succeeds. A
persisted legacy `blocked_configuration` value is recovered automatically; it
does not require additional Forge configuration or an environment reset. If a
run cannot be committed after the package receives its durable run identity,
Forge retains that exact identity and retries it through the existing Manager
watchdog instead of converting the package into a configuration blocker.

**Stop Ordered Work** prevents the next package from starting. It does not discard or silently cancel an already admitted run; that run remains visible in **Projects → Run Details**.

**Dashboard** monitors the active queue without changing it. Its project status
shows delivered document steps and completed packages; the Managed Activity
frame names a current package only when its `run_id` exactly links it to the
nonterminal active run. Failed, cancelled, terminal, and unrelated packages are
never combined with that run. The first queued package is shown separately as
**Next Package**. For an exact active package the frame shows the next inferred
current step and durable delivered count together with the run's current phase,
work item, and next action. The display refreshes every five seconds only while
Dashboard is visible and does not treat a missing Manager snapshot as completed work.

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
input checks. In **Projects → Run Details**, large pasted text plus every selected or dropped
file, folder, or ZIP uses the same importer. A direct artifact is durably bound
to its exact project generation and run UUID without entering or reordering the
package queue. Prepare and Start carry only its compact bootstrap and snapshot
digest, never the full large instruction body.

Queue refreshes are delivered in revision-bound pages of at most 128 package
records. The app accepts a page only when its project, generation, revision,
total count, cursor, and package positions agree, then reconstructs the visible
order. Large instruction bodies never enter queue metadata.

`instruction_read` accepts a requested byte ceiling but may lower it to fit the
current provider-reported remaining context and the run's durable inline-result
envelope. Its response reports the requested and effective limits plus
`next_byte_offset`; callers continue until that cursor is absent. The durable
invocation journal records accepted catalog and byte ranges, and managed
handoffs carry the compact coverage bitmap and partial cursors across restart or
rollover without preventing a document from being revisited by ID.

Resetting a project generation fences unfinished packages from the old generation. Removing a project deletes its active package queue, advances the control-plane generation, invalidates bindings, and hides the registration while preserving project memory and historical run evidence. Registering the same repository again reconnects its durable project identity.

## Resource budgets

- 4,096 queued package records
- 4,096 durable direct-run artifact records
- 4,096 source files per import
- 128 MiB per source file
- 512 MiB aggregate source bytes per import
- 32 KiB compact bootstrap summary metadata
- 64 KiB upper transport bound per scoped delivery window; the effective page
  may be smaller for the current provider context or inline-result envelope
- 64 MiB queue metadata

These are explicit resource backpressure budgets, not a 32 KiB limit on the
user's total instructions. Referenced snapshots remain durable; unreferenced
snapshots are removed when their owning package/project record is removed.

All queue mutations use bounded authenticated manager requests. The queue file is written atomically with owner-only permissions, and an unsuccessful persistence write restores the prior in-memory state.
