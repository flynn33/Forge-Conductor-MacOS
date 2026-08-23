# Persistence and Migration Architecture

## Principles

- version every durable format;
- never mutate user data without a recoverable precondition;
- use atomic writes or transactions;
- make migrations idempotent and resumable;
- validate semantics, not only row counts;
- keep project identity stable across moves;
- bound cache and WAL growth.

## SQLite wrapper

Use an object-oriented Swift wrapper around SQLite3:

- `SQLiteConnection`
- `SQLiteStatement`
- `SQLiteTransaction`
- `SQLiteMigration`
- `SQLiteError`

The database connection is owned by a repository actor. Statements are finalized deterministically. Binding and column decoding are typed. SQL input is not interpolated from untrusted values.

## Migration protocol

1. open with safe pragmas;
2. inspect application/user schema version;
3. create a backup or snapshot where supported;
4. begin an exclusive migration transaction;
5. apply one version step;
6. validate constraints and semantic invariants;
7. update version in the same transaction;
8. commit and checkpoint;
9. record checksum/evidence;
10. retain rollback/export information.

On failure, rollback and preserve the prior database. Never delete a database to recover from a migration error.

## File persistence

JSON and handoff files use:

- strict `Codable` schema versions;
- temporary sibling file;
- write, synchronize when durability requires it;
- atomic rename;
- restrictive permissions;
- checksum where cross-process handoff matters.

## Disk budgets

Track database, WAL, attachments, exports, traces, and logs independently. Maintenance must not delete durable decisions/handoffs without retention policy. Prefer compaction, summary, archive, and user-visible export over silent loss.

## Corruption recovery

- run lightweight quick checks at open and full integrity checks when indicated;
- preserve the corrupt artifact;
- attempt SQLite recovery only into a new file;
- validate recovered project and record counts;
- fall back to the latest verified backup;
- surface a recoverable error state rather than crashing.

## Tests

Use fixtures for every schema version, interrupted migration, duplicate migration, path move, concurrent access, lock timeout, disk full, corrupt page, and export/import.
