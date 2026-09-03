# E2 qualification

Follow `.forge-e2/docs/09-TEST-AND-ADVERSARIAL-QUALIFICATION.md` and the installed attacker harness.

Required operations include delete, same-volume move, cross-volume move, write/replace, edit, staging cleanup, migration backup rotation, package ingestion publication, and reset backup handling.

Attackers repeatedly perform atomic leaf swaps, file/directory swaps, parent rebinding, symlink substitution, hard-link changes, case/Unicode collisions, cancellation, reset, and manager termination.

Pass requires:

- no outside-root sentinel mutation;
- no unverified substituted object destruction;
- exact committed/partial/unsupported receipts;
- recoverable transaction state;
- unsupported filesystems/flags fail closed;
- formal source closure argument identifies the atomic linearization point for each mutation.
