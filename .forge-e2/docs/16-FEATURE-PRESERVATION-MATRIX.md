# Feature Preservation Matrix

| Feature | Required E2 behavior |
|---|---|
| Project memory MCP | No schema or routing regression; project generation remains authoritative. |
| Continuity MCP | Handoffs, rollover, recovery, and successor acknowledgment remain operational. |
| Managed autonomy | Manager-owned work continues with GUI closed. |
| `shell_exec` | Enabled by default, present, executes `/bin/bash -lc`, contract unchanged. |
| Runtime jobs | Direct process, native shell, Bash, Python, PowerShell remain additive. |
| Filesystem read | Bounded paging retained; version token added. |
| Filesystem write | Size limits retained; atomic staged publication. |
| Filesystem edit | Replacement count and size behavior retained; atomic conflict handling. |
| Filesystem list | Entry limit retained; descriptor enumeration. |
| Filesystem glob | Pattern semantics characterized and retained without `/usr/bin/find`. |
| Filesystem mkdir | Intermediate-directory behavior retained with descriptor creation. |
| Filesystem delete | Recursive behavior retained; atomic root capture and truthful partial/quarantine results. |
| Filesystem move | Same- and cross-volume behavior retained; no overwrite preserved. |
| Package queue | Finder import and immutable managed storage preserved. |
| Git tools | Working-directory authorization becomes capability-backed. |
| PDF tools | Source/destination path authorization becomes capability-backed. |
| Resets | Memory/continuity resets do not alter shell and fence stale transactions. |
| Diagnostics | Add transaction/capability health without leaking raw bookmarks or descriptors. |
