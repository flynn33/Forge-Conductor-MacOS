# Completion validation test specification

## Unit tests

1. A completion claim with an unrelated successful tool hash does not pass any gate.
2. A failed tool result hash does not pass.
3. A syntactically valid invented SHA-256 does not pass.
4. A receipt for another gate does not pass.
5. A receipt for another run or package run does not pass.
6. A receipt for another project or generation does not pass.
7. A receipt from an older validator version does not pass a revised definition.
8. A receipt from a changed source manifest does not pass.
9. A cancelled/timed-out/blocked-environment validator does not pass.
10. One receipt cannot be attached to two gate definitions unless both definitions explicitly reference the same composite child execution.
11. All mandatory gates are required; unknown gates are rejected.
12. Repeated completion requests are idempotent and do not launch duplicate active gate executions.

## Integration tests

- Provider requests completion; manager persists claim; provider turn ends; validators execute independently; run completes only after receipts pass.
- Manager crashes before validator start, during command, after artifact write, after result commit, and before run transition. Recovery is exactly-once accepted.
- Gate parameter or source changes invalidate prior results and return the run to validation.

## Production assertion

A source scan and dependency-injection test must prove `EvidenceBoundCompletionValidator` is not used by production composition.
