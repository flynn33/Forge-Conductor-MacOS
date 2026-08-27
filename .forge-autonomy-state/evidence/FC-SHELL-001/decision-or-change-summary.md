# FC-SHELL-001 decision and change summary

Configuration schema version 2 makes the project shell available on fresh installs and
migrates the prior implicit-disabled default exactly once. Migration holds a bounded
process/file lock, preserves and verifies the pre-migration source, persists an immutable
target snapshot and receipt, and can reconcile an interrupted prepared receipt. Later
schema-v2 settings edits retain verified migration lineage instead of invalidating the
original receipt.

An explicit schema-v2 disable is represented separately from provider/runtime absence and
persists through reload. Authorization returns `shell_disabled_by_user` for that explicit
choice. Status, doctor, manager settings, and the native settings view expose effective
policy, migration status, and independent zsh/Bash/Python/PowerShell discovery.

The existing `ShellToolPack` implementation was not changed. Its `command`, `cwd`, and
`timeout_sec` payload, 120-second ceiling, bounded output behavior, and `/bin/bash -lc`
compatibility execution profile therefore remain intact.
