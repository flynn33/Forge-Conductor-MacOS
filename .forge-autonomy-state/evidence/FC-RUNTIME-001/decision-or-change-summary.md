# FC-RUNTIME-001 decision and change summary

Runtime execution now uses a durable SQLite job repository and an actor-owned execution
service. Each job records its project, generation, optional run, replay class, idempotency
key, execution profile, state, deadlines, process identity, output metadata, and terminal
receipt. Submission validates project context and canonical roots before persistence.

Direct process jobs use an argument vector without shell parsing. New zsh and Bash jobs use
staged scripts with startup files disabled; Python uses isolated mode and PowerShell is
noninteractive with profiles disabled when those optional runtimes are available. Runtime
capability discovery reports each executable independently, so missing Python or PowerShell
does not disable the native shell surface.

Stdout and stderr are drained concurrently into capped in-memory prefixes and bounded,
manager-owned artifacts. Child-writable scratch space is separate from durable output.
Artifact reads revalidate the recorded device, inode, owner, link count, size, and digest;
same-directory replacement, mutation, and symlink escape are rejected. Project and global
artifact quotas, terminal-job limits, compact idempotency receipts, and a bounded startup
orphan sweep prevent unbounded retention while preserving replay protection.

The signed product supplies a dedicated launch-gate helper. The parent does not release the
helper's gate byte until the exact PID, process group, and process-start identity are durably
committed. Each child becomes a process-group leader and receives bounded CPU, file-size,
descriptor, and core limits. A group census enforces the descendant budget. Timeout,
explicit cancellation, run cancellation, and shutdown use persisted, deadline-bounded
TERM/KILL phases and wait for pipe readers. Recovery signals a surviving group only when the
persisted group relation and exact process-start identity still match. A transiently
unavailable identity is retried only inside the absolute deadline; mismatch, signal failure,
or unconfirmed death remains fail-closed and owned by the durable reaper. Generation-reset
results are quarantined rather than committed.

The runtime sandbox is deny-by-default, strips dynamic-loader variables, denies Mach/XPC and
AF_UNIX broker delegation, and grants outbound networking only when the request authorizes
it. Read and write roots are distinct. Shell capability discovery uses semantic probes:
Python must run in isolated mode and PowerShell must be PowerShell Core 7 or newer.

The additive contextual tools are `runtime.capabilities`, `process.run`, `shell.run`,
`bash.run`, `python.run`, `powershell.run`, `job.status`, `job.read_output`, `job.cancel`,
and `job.list`. Existing `shell_exec` keeps its command, cwd, timeout, bounded output, and
Bash-login compatibility behavior while executing through the durable subsystem.

The frozen FC-RUNTIME ledger contains 13 command records. Current-source strict SwiftPM and
ad-hoc-signed Xcode runs each executed 64 runtime tests with one documented PowerShell-host
skip and no failures. The Xcode run also exercised the exact helper product identifier.
Two bootstrap-router tests are outside that focused proof because the locked macOS session
cannot reopen their complete-file-protected `registry.json`; that environment boundary and
the matching full-suite failures are retained in FC-RELEASE-001.
