# Changelog

All notable changes to **Forge Conductor (macOS)** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for marketing versions (`MAJOR.MINOR.PATCH`).

## [0.6.0] — 2026-07-31

### Added

- **Durable memory MCP tools** for cross-session continuity in LM Studio:
  - `memory_set` — upsert a key/value note (optional tags)
  - `memory_get` — read a note by key
  - `memory_list` — list notes (prefix/tag filters; hides agent system keys by default)
  - `memory_delete` — delete a note by key
  - `memory_search` — substring search over key, body, and tags
- SQLite-backed note storage in `memory_notes` under `FORGE_CONDUCTOR_HOME`
  (default `~/.forge-conductor/store.sqlite`)
- `MemoryNote` domain type and store list/search/count APIs
- `MemoryToolPack` wired into the tool router, authorization lifecycle allow-list,
  MCP schemas/descriptions, and telemetry pack map
- `forge_status` now reports `memory_note_count`
- Documentation: [`docs/DURABLE-MEMORY.md`](docs/DURABLE-MEMORY.md)
- Unit tests: `MemoryToolTests`

### Changed

- Marketing version **0.5.3 → 0.6.0** (minor bump for a new MCP tool surface)
- Xcode project includes `MemoryToolPack.swift` and `MemoryToolTests.swift` in the
  native targets (SwiftPM already discovered them)

### Notes

- Memory tools work **without** an active agent session and remain available
  **during** agent runs.
- Internal keys `agent_run/*` and `agent_active/*` are hidden from list/search
  unless `include_system` is true.
- Note bodies are redacted in audit logs.

## [0.5.3] — 2026-07

### Summary

- Swift control plane and MCP server for local models in LM Studio
- Primary + fallback MCP deploy path (`Deploy to LM Studio`)
- Specialist agent playbooks and durable agent sessions
- Filesystem, shell, git, search, and PDF tool packs
- Native SwiftUI + Metal rig / dashboard and LaunchAgent manager
- Apache 2.0 license and closed contribution policy

See [`docs/AUDIT-2026-07-27.md`](docs/AUDIT-2026-07-27.md) and related audits for
0.5.x verification evidence.

[0.6.0]: https://github.com/flynn33/Forge-Conductor-MacOS/compare/v0.5.3...HEAD
[0.5.3]: https://github.com/flynn33/Forge-Conductor-MacOS/releases/tag/v0.5.3
