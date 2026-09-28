# Project instruction packages

Instruction packages give the LM Studio model an ordered, immutable instruction
catalog for a registered project. Each accepted package is bound to the selected
project UUID and generation; Forge does not require a Managed Run to use it.

## Setup

1. Start the provider you intend to use. For LM Studio, load a tool-capable
   model; its activation toggle runs **Connect and Check** before selection. For
   Claude Code Desktop or Codex Desktop, start the supported host
   and complete the exact activation, reload, or trust action reported by its
   provider card.
2. In Forge Conductor **Manager**, start the manager if it is stopped.
3. In **Projects**, register the local repository folder and select it. The
   registration records that exact canonical root as the durable project
   identity and default working directory; it does not confine native access to
   the folder or hide its parent.
4. Under **Instruction packages**, choose **Add Instructions…** one or more
   times and arrange packages by drag-and-drop or the earlier/later buttons.
5. In **Provider**, select and verify exactly one provider. LM Studio requires a
   current saved model/readiness receipt; desktop providers require a verified
   integration and retain their host-selected model.
   Grok Build remains visible but cannot be selected or admit a run in 0.14.1
   because its documented hook outputs cannot deliver the initial assignment
   context to the model.
6. Open a normal LM Studio chat and call `get_forge_status`. Select the intended
   `project_id` when more than one project is registered, then let the model use
   `instruction_catalog` and `instruction_read` to consume packages in the
   displayed priority order.

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

## Ordering and model access

The Projects list order is authoritative. Drag packages or use the explicit
earlier/later buttons. New packages can be added while the model is working;
the next `instruction_catalog` query observes the durable order. Every order change carries a
queue revision so concurrent or stale edits fail instead of silently
overwriting a newer order. The native view also rejects a background snapshot
whose revision predates the queue already shown, and it does not hide the
visible queue while Delete or Reorder is in flight.

The package rows are plain content inside the Projects detail `ScrollView`, not
a nested list. **Move earlier**, **Move later**, and **Delete Package** retain separate
native control identities at the minimum supported window size. The package
container deliberately has no parent accessibility identifier because SwiftUI
would otherwise replace those child identities.

### LM Studio model access

Instruction packages do not start or own a Forge-managed model run. The user
opens an ordinary LM Studio chat and asks the model to call
`get_forge_status`. The returned project-scoped locations and query tools let
the model discover the ordered instruction catalog and fetch bounded content.
With multiple registered projects, the model passes the applicable
`project_id` on later calls.

Package changes remain durable while the LM Studio conversation is active. A
subsequent catalog query observes the newest committed order. **Delete
Package** removes only the selected package; project reset and disposable-cache
clearing are separate confirmed actions on the Projects surface.

## Storage and project linkage

Forge copies accepted content to an owner-only, content-addressed snapshot under:

```text
~/.forge-conductor/instruction-packages/Store/<sha256>/
```

The durable queue metadata is stored in:

```text
~/.forge-conductor/instruction-packages/queue.json
```

Editing or deleting the original selected file after import does not change the
accepted snapshot. Package records retain source provenance. The package and
its catalog remain bound to the exact project identity and generation, while
ordinary native filesystem tools may address absolute paths outside the
registered project folder under the launching Forge process's macOS access.

Import inventories the immutable snapshot's documents and records each
content-addressed reference, byte count, and SHA-256. The package remains bound
to the exact project identity and generation. `get_forge_status` gives the LM
Studio model the catalog tools and locations it needs; large instruction bodies
stay in the immutable store and are fetched in bounded pages rather than being
copied into the initial status response.

Queue refreshes are delivered in revision-bound pages of at most 128 package
records. The app accepts a page only when its project, generation, revision,
total count, cursor, and package positions agree, then reconstructs the visible
order. Large instruction bodies never enter queue metadata.

`instruction_read` accepts a requested byte ceiling but may lower it to fit the
current model context and transport result envelope. Its response reports the
requested and effective limits plus `next_byte_offset`; callers continue until
that cursor is absent. The durable invocation journal records accepted catalog
and byte ranges, and handoffs carry the compact coverage bitmap and partial cursors across restart or
rollover without preventing a document from being revisited by ID.

Resetting a project generation fences unfinished packages from the old generation. Removing a project deletes its active package queue, advances the control-plane generation, invalidates bindings, and hides the registration while preserving project memory and historical run evidence. Registering the same repository again reconnects its durable project identity.

## Resource budgets

- 4,096 queued package records
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
