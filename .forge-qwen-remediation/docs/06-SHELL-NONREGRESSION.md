# Shell non-regression contract

## Required behavior

- New installations default shell access to enabled.
- A legacy implicit-disabled value migrates to enabled once.
- An explicit user decision to disable shell remains respected.
- `shell_exec` remains in MCP `tools/list`.
- The established legacy execution and response contract remains compatible.
- `shell.run`, `bash.run`, `python.run`, `powershell.run`, and hardened XPC profiles are additive.
- Missing optional Python or PowerShell runtimes cannot disable native shell or Bash.
- Memory reset, continuity reset, queue reset, provider restart, app restart, and manager restart cannot change shell policy.

## Native gate

The signed test must exercise:

```text
Settings UI
  -> authenticated manager settings mutation
  -> persisted configuration
  -> manager restart
  -> MCP tools/list
  -> shell_exec success
  -> durable shell.run/bash.run job success
```

The test also disables shell explicitly, proves denial, re-enables it, and repeats after project switching and reset.

## E2/XPC separation

Secure filesystem and XPC work must not route general shell access through an incompatible sandbox or remove the legacy path. Hardened XPC is an optional execution profile chosen per job.
