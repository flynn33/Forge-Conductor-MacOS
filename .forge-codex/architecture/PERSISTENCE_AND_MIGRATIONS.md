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

## SQLite pathname trust boundary

During schema migration, Forge checks each protected open `main` database with
`SQLITE_FCNTL_HAS_MOVED` around backup creation and before a durable migration
or recovery transaction commits. An unsupported or failed check, or a result
that reports the file moved, fails closed. This detects a stable rename,
deletion, or pathname replacement that remains in place when the check runs.

The check is not atomic with pathname lookup or commit and is not an integrity
boundary against an actively hostile process running with Forge's effective
user ID. The current macOS VFS fails closed in the tested restored-path cycle,
but no portable guarantee makes sequential observations atomic. A hostile
same-user process can attempt namespace substitution between checks or write
owner-controlled database-family files directly while ignoring advisory locks.
Those attacks are therefore outside the production migration trust boundary.
Broadening that boundary requires a custom SQLite VFS that pins and verifies
the exact main/WAL/journal file family, and protection from direct same-owner
mutation requires an independent privilege boundary.

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
