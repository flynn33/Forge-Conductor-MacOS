# Feature parity tests

## MCP

Snapshot and compare all existing tool names and input schemas. New tools are additive. Exercise representative success/error behavior for filesystem, Git, memory, project memory, continuity, shell, runtime jobs, agents, search, and PDF tools.

## UI

Every baseline tab remains present. Critical controls retain accessibility identifiers unless a versioned test migration is committed.

## Settings and migration

- shell enabled default and migration;
- explicit shell opt-out;
- allowed roots and manager settings;
- project and provider settings;
- database schema migration fixtures;
- prior handoff and memory compatibility.

## Documentation and packaging

Version, release notes, user guide, architecture, continuity, memory, shell, queue, reset, XPC, and security documents describe actual behavior. Clean source archive excludes build products, temporary evidence, secrets, temporary keychains, and absolute user paths.
