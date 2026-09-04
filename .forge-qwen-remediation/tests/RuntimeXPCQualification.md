# Hardened XPC runtime qualification

Run with a signed local app and XPC service.

## Allowed behavior

- execute a fixed test binary and staged Python/PowerShell script inside the authorized project root;
- read/write authorized fixture files;
- return bounded stdout/stderr and structured receipt;
- cancel and terminate a descendant process tree;
- reconnect after manager or XPC service restart.

## Denied behavior

- read another project's sentinel;
- read denied home/system paths;
- escape through symlink or stale bookmark;
- connect to network in denied profile;
- exceed output/time/process limits;
- use stale project generation or lease epoch;
- forge a bookmark or request envelope.

## Compatibility

Prove `shell_exec`, `shell.run`, and `bash.run` still work outside hardened XPC exactly as declared. Absence of Python or PowerShell is reported per runtime, not as global shell failure.
