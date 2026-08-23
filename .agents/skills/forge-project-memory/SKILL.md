---
name: forge-project-memory
description: Build and validate Forge Conductor's native project-scoped memory MCP, SQLite repository, migrations, search, and resource policies.
---

# Forge Project Memory

Use Apple-native Swift and SQLite3. Extend the existing MCP server and preserve existing tools.

## Implementation order

1. Inventory current MCP names/schemas/transports.
2. Implement stable project identity.
3. Build typed SQLite connection/statement/transaction/migration wrappers.
4. Create the repository actor and versioned schema.
5. Add memory service, redaction, dedupe, links, bounded search, pagination, and maintenance.
6. Add additive MCP tools/resources and capability negotiation.
7. Add old/new protocol golden tests.
8. Test migrations, interruption, locks, disk full, corruption, restart, isolation, cancellation, and export/import.
9. Measure cache/database/query budgets.

## Invariants

- no global cross-project namespace;
- no full-corpus in-memory mirror;
- bounded request, response, result, cache, and maintenance work;
- transactional writes and migrations;
- compact automatic capture, not raw transcript retention;
- secrets never persist or appear in logs;
- project close releases repositories and caches.
