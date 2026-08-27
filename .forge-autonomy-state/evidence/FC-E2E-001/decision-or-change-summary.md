# FC-E2E-001 decision and change summary

FC-E2E-001 remains partial and its evidence remains incomplete. The latest exact-commit
LM Studio scenario passed, but the UI dependency is still blocked, the performance
dependency is incomplete, and the remaining hard end-to-end and feature-parity scenarios
listed in `test-results.json` have not all been executed.

The 2026-08-27 live rerun `CMD-20260827T100722Z-8515b5f9b3` reproduced a real
liveness defect. Probe and bootstrap completed, but the automatic continuation kept
streaming without a provider-side output-token bound until the existing 300-second total
transport deadline raised `deadlineExceeded(phase: total)`. The test failed after 379.940
seconds. The repair preserved the bounded transport deadlines, added explicit
`max_output_tokens` to every managed LM Studio Responses request with a 4,096-token
default, and scoped the bootstrap instruction so a stateful successor can advance into
its continuation response.

The first focused repair build, `CMD-20260827T102141Z-75855aa527`, failed before test
execution because the assertion referenced a property not present on `ProviderTurn`.
After that assertion was corrected, `CMD-20260827T102227Z-947a6aa63e` passed 27 focused
tests with one skip. The repaired candidate live scenario
`CMD-20260827T102419Z-ba036e7505` then passed in 166.766 seconds, and the final focused
rerun `CMD-20260827T103019Z-caacf56201` again passed 27 tests with one skip.

Commit `52f8aca47463f88fa94276115fb5c2070ca683ef` received the final strict regression
and live-provider proof:

- Debug `CMD-20260827T103327Z-5d0a028f3d`: 447 tests executed, 3 skipped, 0 failures.
- Release `CMD-20260827T103455Z-4b3944647c`: 447 tests executed, 4 skipped, 0 failures.
- Live `CMD-20260827T103812Z-17ac760a12`: 1 test executed, 0 failures, 170.832 seconds.

The immutable final live artifact is
`.forge-autonomy-state/evidence/FC-E2E-001/live-lmstudio-managed-continuity-52f8aca.json`
with SHA-256 `f870f77cd2036f60dac6ca8c8ac434eef31cae9b04b001e4fee6854a47d2c9bb`.
It records genuine `resp_` identifiers, exact handoff acknowledgment, a validated
automatic-continuation marker, a 119,552-token context, a 4,096-token configured output
bound, and provider-exact continuation usage of 2,321 input, 82 output, and 2,403 total
tokens. No operator action occurred between the rollover bootstrap and successor
continuation inside that scenario; starting the provider and loading the model remained
explicit test setup.

Final cleanup also passed: `CMD-20260827T104150Z-7623857663` unloaded
`qwen/qwen3.8-27b`, and `CMD-20260827T104156Z-7ba27baea0` stopped the LM Studio
server. The compact command ledger preserves its two historical lines unchanged and
appends all 18 later raw FC-E2E command records in raw-ledger order.

These repaired passes replace the earlier live deadline failure as current-source proof,
but they do not close FC-E2E-001. GUI closure, reset fencing, real multi-project
model-plus-shell interleaving, full managed authentication and outage recovery, real
emergency-overflow recovery, profiling and soaks, and final feature parity remain open.
