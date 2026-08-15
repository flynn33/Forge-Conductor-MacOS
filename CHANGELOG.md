# Changelog

All notable changes to **Forge Conductor (macOS)** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for marketing versions (`MAJOR.MINOR.PATCH`).

## [0.8.0] — 2026-08-14

### Added

- **Hard context budget** — after auto-handoff (20 progress tools) or a hard identical-call loop, further filesystem/shell/git tools on that MCP client return `context_budget_exceeded` until `context_get`. Writes `memory/NEXT-CHAT.md`. LM Studio has no API to open a GUI chat; this is the enforcement.
- **Runtime continuity** — Forge checkpoints and handoffs from tool progress.
  The model no longer has to remember `session_checkpoint` / `session_handoff`.
  Default: checkpoint every 5 progress tools, handoff every 20 or 12 minutes.
- **Workspace resume** — latest handoff `cwd` / `key_files` become implicit roots.
  `context_get` adopts them for the calling client.
- **Home read-only paths** — `fs_list` / `fs_read` / `fs_glob` / `search_text` may
  read under the interactive user's home (excluding Library, ssh, and similar).
- Idle MCP **presence heartbeat** every 10s so a quiet serve stays live on the dashboard.
- Snapshot now reports real `presence` rows and `primary_alive` / `fallback_alive`.
- `shell_exec` failures persist `exit_code` / stderr in the audit error field.

### Changed

- Implement playbook includes continuity and memory tools.
- Manager heartbeat age is 0 while the manager process is alive (no longer the
  stale `manager-state.json` mtime capped at 120s).
- Soft auto-checkpoints no longer change a model packet's source, status, or
  client id, and no longer append diagnostic lines to the narrative.
- MCP server cards omit LM Studio host helpers and model backends.

## [0.7.0] — 2026-08-01

### Added

- **Context and agent continuity MCP tools** on the existing stdio server:
  - `session_checkpoint` — soft-save task context while work continues
  - `session_handoff` — finalize a resume-ready packet for a new chat
  - `context_get` — load the latest or a selected handoff packet
  - `context_list` — list recent handoff packets
- SQLite `context_handoffs` storage as the authoritative handoff record, with
  rebuildable JSON, `LATEST`, and `current-task.md` projections.
- Transactional durable-memory pointers at `continuity/latest` and
  `continuity/resume_ready`; these internal keys are hidden from default memory
  list, search, and count results.
- Agent-session snapshots and compare-and-swap reattachment so an open durable
  run can transfer safely to the resumed MCP client.
- Repeated-call context budget: the fourth identical non-continuity call writes
  a soft resume-ready handoff; the ninth is blocked after persisting the handoff.
- Process-level deployment verification for the complete continuity and durable-
  memory product tool surfaces.
- Continuity integration, recovery, multi-process, MCP, loop-budget, and
  new-chat process tests.

### Changed

- `fs_read` supports 1-based `offset` plus `length`/`limit` pagination and returns
  line-window metadata to prevent accidental full-file reread loops.
- `forge_status` reports continuity state while retaining `memory_note_count`.
- Tool auditing redacts continuity narrative, resume, decision, blocker, and
  working-set fields in addition to durable-memory bodies.
- Marketing version **0.6.0 → 0.7.0**.

### Notes

- Continuity uses the same primary/fallback mcpBridge deployment path as the
  existing tool packs; it does not add an HTTP service or sidecar.
- Opening a new LM Studio chat remains an operator/host action. The handoff
  packet and returned resume seed provide the Phase 1 bootstrap.
- Durable `memory_*` tools and their 0.6 behavior remain intact.

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

[0.7.0]: https://github.com/flynn33/Forge-Conductor-MacOS/compare/6fe03e0...main
[0.6.0]: https://github.com/flynn33/Forge-Conductor-MacOS/commit/6fe03e0626273ced4211ed4e1bbef8c70cfb36b8
[0.5.3]: https://github.com/flynn33/Forge-Conductor-MacOS/commit/90fc5757dbf7acf629e16184c5347760dbff4a47
