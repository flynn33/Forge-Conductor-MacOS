# Feature preservation

## Baseline

`plans/feature-preservation.json` records the current MCP tools and application tabs. Qwen Code must generate a live baseline from the checkout and compare it with this supplied baseline before the first product edit.

## Compatibility classes

### Exact compatibility

These contracts must remain byte- or field-compatible where practical:

- MCP tool names and required arguments;
- existing response keys and error codes;
- `shell_exec` invocation and result semantics;
- settings keys and default migration behavior;
- project identifiers and generation fencing;
- continuity V2 identifiers and acknowledgment fields;
- accessibility identifiers used by native tests.

### Additive compatibility

New queue, reset, XPC, validator, and operator APIs are additive. Existing clients that do not use them continue to work.

### Versioned migration

Schema changes require forward migration, backup, crash recovery, and migration tests from every supported prior schema. Never silently reinterpret persisted values.

## Required parity snapshots

- MCP `tools/list` names and input schemas;
- operator tabs and key controls;
- settings defaults and serialized configuration;
- manager route inventory and authorization class;
- database schema version and migrations;
- project package formats;
- CLI commands and exit behavior;
- app version/build identifiers.

## Regression prohibition

Performance work may not solve scale by removing processors, disks, MCP servers, agents, tools, gauges, histories, or operator information. Use virtualization, batching, shared resources, lower cadence, paging, and adaptive policy.
