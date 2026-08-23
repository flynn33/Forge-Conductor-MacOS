# Feature Preservation Contract

## Principle

Performance and reliability work must not silently remove, rename, disable, or narrow existing functionality. The current repository, executable behavior, persistent formats, and protocol surfaces form the baseline.

## Baseline construction

Before behavior-changing edits, run:

```bash
./.forge-codex/scripts/feature_inventory.py --repo .
```

Then inspect and complete `.forge-codex/state/feature-baseline.json`.

The inventory must cover:

- Xcode schemes, targets, products, package products, and executables;
- app scenes, windows, menu-bar surfaces, commands, toolbar actions, keyboard shortcuts, settings, and URL handlers;
- project create/open/import/export/delete/archive behavior;
- model/provider integrations and subprocess/network clients;
- MCP servers, tools, prompts, resources, transports, capabilities, names, request schemas, and response schemas;
- memory, continuity, telemetry, gauge, diagnostics, logging, and performance surfaces;
- persisted files, SQLite schemas, UserDefaults keys, Keychain entries, caches, and migrations;
- background tasks, notifications, file watchers, timers, processes, pipes, and delegates;
- accessibility identifiers and automation-critical labels;
- error, recovery, offline, and cancellation behavior.

Static discovery is a starting point. Exercise the application and merge runtime-discovered features.

## Stable identifiers

Assign each feature a stable ID such as:

```text
UI-MAIN-WINDOW
UI-PROJECT-OPEN
CMD-NEW-PROJECT
MCP-EXISTING-TOOL-NAME
DATA-PROJECT-FORMAT-V1
TELEMETRY-GAUGE-CPU
CONTINUITY-HANDOFF
```

Every change record lists affected feature IDs.

## Characterization tests

Add tests before refactoring code that lacks coverage. Prefer semantic tests over exact internal implementation. Required categories:

- command routes to expected service action;
- settings load, persist, and migrate;
- project files round-trip;
- each existing MCP tool accepts the prior request and returns a compatible response;
- telemetry metric maps to the correct gauge and units;
- window/scene state remains reachable;
- subprocess lifecycle supports start, cancellation, exit, and failure;
- memory and continuity additions do not shadow existing MCP tools.

## Golden protocol snapshots

Capture canonical MCP initialize/capabilities and tool-list transcripts. Normalize nondeterministic identifiers and timestamps. Compare names, schemas, required fields, and semantic response content.

Schema change rules:

- additions must be optional or version-negotiated;
- renamed fields require aliases;
- removed behavior requires an explicit migration and compatibility period;
- error codes and cancellation behavior remain stable.

## UI preservation

For critical surfaces, store:

- window and scene list;
- command/menu list;
- accessibility tree snapshots;
- representative screenshots;
- keyboard shortcut tests;
- navigation and selection tests.

Visual pixel equality is not required when fixing layout/performance, but all controls and actions must remain discoverable and functional.

## Data preservation

Before schema changes:

1. collect representative old-format fixtures;
2. copy before migration;
3. migrate transactionally;
4. validate counts, checksums, and semantic fields;
5. reopen with the new version;
6. prove idempotent re-migration;
7. test interrupted migration recovery;
8. keep a rollback/export path.

## Parity gate

A phase passes feature parity only when every affected baseline feature is one of:

- `preserved` with passing tests;
- `additive` with no conflict;
- `migrated` with compatibility and migration proof.

`removed`, `unknown`, and `untested` block completion.
