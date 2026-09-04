# Shell Preservation Gate

The E2 implementation must not disable shell access.

## Required behavior

- clean installation defaults shell access to enabled;
- legacy accidental-disabled configurations migrate to enabled;
- an explicit user opt-out made after migration is preserved;
- `shell_exec` remains present in MCP `tools/list`;
- `shell_exec` executes through the established `/bin/bash -lc` path;
- existing timeout, cancellation, stdout, stderr, exit code, truncation,
  cwd, and result fields remain compatible;
- app restart, manager restart, project switch, memory reset, continuity
  reset, and E2 recovery do not change the shell setting;
- missing optional Python or PowerShell runtimes do not disable Bash;
- `process.run`, `shell.run`, `bash.run`, `python.run`, and
  `powershell.run` remain additive.

## Required smoke command

Through the real MCP path:

```bash
printf 'FORGE_E2_SHELL_OK\n'
```

The exact output, exit code zero, and configured working directory must be
captured as evidence.

## Secure filesystem separation

The secure filesystem broker must not shell out to implement copy, find,
delete, move, or hierarchy creation. That restriction protects filesystem
atomicity; it is not permission to disable general shell tools.
