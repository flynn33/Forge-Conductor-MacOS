# Completion Checklist

- [ ] Current HEAD is a descendant of the merged PR #11 baseline.
- [ ] Every work package is passed.
- [ ] Every hard gate is passed.
- [ ] `FC-FILESYSTEM-PATH-TOCTOU-001` has source and runtime evidence.
- [ ] No compare-then-unlink/rename pattern remains.
- [ ] No path-based fallback remains.
- [ ] Outside-root sentinels are unchanged.
- [ ] Unsupported volumes fail closed.
- [ ] Exact-version mismatches restore or quarantine without destruction.
- [ ] Crash recovery passes every state.
- [ ] Shell defaults enabled.
- [ ] `shell_exec` is listed and executes through `/bin/bash -lc`.
- [ ] Memory, continuity, autonomy, and manager tests pass.
- [ ] Resource budgets pass.
- [ ] Attribution scan passes.
- [ ] Secret scan passes.
- [ ] Focused PR is open and mergeable.
- [ ] Final doctor/state selector reports no open E2 work.
