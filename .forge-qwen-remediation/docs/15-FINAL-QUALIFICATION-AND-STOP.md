# Final qualification and stop procedure

P14 is a clean-room qualification pass over the exact final source manifest. Freeze product edits before starting. Any source change invalidates the pass and restarts qualification at stage one of `plans/final-qualification-order.json`.

## Stage one — deterministic final-source rerun

Run strict SwiftPM Debug and Release, Xcode unit/integration, source membership parity, completion integrity, continuity authority, package ingestion, queue, reset, resource policy, dashboard, publication hygiene, secrets, migrations, and documentation contract. Resolve every warning treated as an error. Do not reuse receipts from an earlier source manifest.

## Stage two — signed local native security and UI

Build all app, LaunchAgent, XPC, C interoperability, and test targets with a local matching identity. Verify entitlements from products. Execute operator XCUITests, shell end to end, XPC sandbox tests, E2 race tests, LaunchAgent restart/reconnect, and the crash matrix. Preserve `.xcresult`, transcripts, built-product hashes, and entitlement reports.

## Stage three — real provider and Instruments

Use a real local LM Studio model for forced rollover and integrated two-package autonomy. Keep the GUI closed during manager-owned portions. Run Allocations, Leaks/memgraph, Time Profiler, SwiftUI, and Metal System Trace under the defined constrained/standard/expanded profiles. Preserve raw traces and deterministic metric extraction.

## Stage four — local release candidate

Create a clean source archive and local app release candidate under `.forge-qwen-state/release-candidate/`. Exclude local work state, DerivedData, `.build`, credentials, ephemeral signing material, absolute host paths, and raw unbounded logs. Generate SBOM/checksums, migration and rollback notes, user/release notes, and a readiness attestation. The release candidate remains local.

Generate the attestation:

```bash
./.forge-qwen-remediation/scripts/create_release_readiness.py \
  --repo . \
  --release-candidate .forge-qwen-state/release-candidate/<artifact>
```

Run the registered G20 validator, accept its receipt, close any final source-manifest finding receipts, complete P14, then run:

```bash
./.forge-qwen-remediation/scripts/verify_completion.py --repo .
```

The only successful terminal result is:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

Stop immediately. Do not merge, tag, notarize-submit, upload, publish, distribute, modify a production feed, or announce availability.
