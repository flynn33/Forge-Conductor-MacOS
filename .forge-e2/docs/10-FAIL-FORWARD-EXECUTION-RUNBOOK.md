# Fail-Forward Execution Runbook

## Operating principle

A failed experiment produces evidence and narrows the next action. It does
not trigger a broad rollback, a guessed workaround, or a request for
operator intervention.

## Failure classes

### API unavailable

- record compiler and runtime probe output;
- confirm SDK and deployment target;
- inspect current public headers;
- do not use numeric constants without the public declaration unless a
  deliberately reviewed compatibility shim is required;
- keep E2 release gate red;
- continue host-independent refactoring and tests.

### Filesystem lacks required atomic capability

- return `filesystem_atomicity_unsupported`;
- do not use Foundation as fallback;
- retain read-only capability where safe;
- continue other projects and jobs;
- record volume type and errno without exposing secrets.

### Restore fails

- preserve the captured object;
- transition to `quarantined`;
- publish a conflict receipt;
- continue unrelated operations;
- block only operations whose safety depends on the unresolved namespace.

### Crash/restart

- run recovery before accepting new mutations;
- lease transaction rows;
- reconcile namespace and identity;
- retry bounded steps;
- never assume a side effect did or did not occur solely from the old state.

### Test regression

- keep the smallest reproducer;
- classify feature, security, performance, or environment;
- fix the earliest incorrect invariant;
- rerun focused tests, then full gates;
- do not weaken an existing test to obtain green status.

## Checkpoint contents

Every checkpoint records:

```text
work package
baseline HEAD
current HEAD
files changed
commands
exit codes
test counts
evidence paths and hashes
open findings
deferred environment gates
next selected work
```

## No-progress detector

After three attempts with the same failure signature:

1. stop repeating the same command;
2. write a decision record;
3. run the designated diagnostic branch from `work/work-packages.json`;
4. select another unblocked implementation task;
5. return when new evidence exists.

## Native gates

Signing, Developer Mode, AppKit, LaunchAgent, and real Xcode tests are
release-blocking. An environment problem may be recorded as
`deferred_environment_release_blocking`, never as passed.
