# Rune Forge and Stjornarvald acceptance

This record closes RF-SJ-10 against all 40 rows in the issued acceptance
matrix. It is implementation acceptance retained by the current `0.14.7 (13)` source;
it is not release, notarization, installation, or shipment acceptance.

Status meanings:

- **Accepted** — current source and repeatable evidence satisfy the behavior.
- **Limited** — the implemented behavior has automated evidence, but a named
  owner or physical validation remains outstanding.

## Acceptance matrix

| ID | Status | Current evidence and boundary |
| --- | --- | --- |
| AC-001 | Accepted | The 14-destination native sidebar round trip passed, including Rune Forge, without removing an existing destination. |
| AC-002 | Accepted | Native UI automation opened and cancelled the unrestricted file-or-directory policy picker. |
| AC-003 | Accepted | `StjornarvaldPolicySourceCatalogTests` cataloged the all-format fixture matrix with durable accepted identities. |
| AC-004 | Accepted | Source admission commits before interpretation; sparse 2 GiB and restart cases prove size-independent acceptance and incremental work. |
| AC-005 | Accepted | Opaque, encrypted, binary, zero-byte, linked, and special entries remain active with honest metadata-only, partial, or pending interpretation. |
| AC-006 | Accepted | A 150-file tree, link cycle, durable cursor, and reopen cases proved bounded resumable discovery without following links. |
| AC-007 | Accepted | The native adapter, stored projection, Manager snapshot, and Rune Forge presentation expose Raven Forge Development 0.6.2 at `ed0028a46bac9c5b92876a6ad6589ca421fd9499`. |
| AC-008 | Accepted | All 15 projected rules retain revision, repository-relative path, Markdown heading locator, and source identity. |
| AC-009 | Accepted | Equal-rank material conflicts retain interpretations, alternatives, assumptions, and confidence instead of selecting a false winner. |
| AC-010 | Accepted | Throwing and unavailable optional utilities append evidence without suspending the pinned native rules. |
| AC-011 | Accepted | Ordinary and managed completed tools emit bounded redacted observations only after their canonical commit boundaries. |
| AC-012 | Accepted | Full evaluator/process/boot lease identity, cursor advancement, restart, and contention cases prove single committed processing. |
| AC-013 | Accepted | Repository/tool activity fixtures open source-linked violations through the native detector and evaluator. |
| AC-014 | Accepted | Stable condition identity groups repeats and appends correction and reopen events without replacing original history. |
| AC-015 | Accepted | A detector fault becomes evidence while peer detectors and the evaluator continue. |
| AC-016 | Accepted | The managed fake-provider transcript receives a bounded notice at the next safe input boundary with its run outcome unchanged. |
| AC-017 | Accepted | Ordinary MCP delivery appends a separate text item while preserving canonical content, structured content, error state, and replay. |
| AC-018 | Accepted | Durable snapshots and receipts distinguish queued, presented, deferred, superseded, and retry-eligible delivery. |
| AC-019 | Accepted | Stable event identity, quieting, bounded selection, and delivery receipts deduplicate repeat guidance. |
| AC-020 | Accepted | Static review and protected-path authorization tests show no Stjornarvald status in tool authorization or grants. |
| AC-021 | Accepted | Fault-injected ordinary-tool integration preserves byte-equivalent canonical results while policy delivery fails and later recovers. |
| AC-022 | Accepted | Store, mirror, detector, notice, Manager, outbox, export, saturation, and shutdown faults remain outside tool, provider, run, queue, and completion outcomes. |
| AC-023 | Accepted | The managed fixture completes with an open observation path and records one managed-tool and one completion observation. |
| AC-024 | Accepted | Protocol and source review find no policy capability that edits, reverts, stages, commits, or pushes project source. |
| AC-025 | Accepted | The dedicated schema-versioned SQLite authority stores immutable append-only policy events and bounded projections. |
| AC-026 | Accepted | Digest-chained JSONL mirror repair and cursor replay restore committed SQLite history after interruption. |
| AC-027 | Accepted | Owner-only outboxes survive Manager outage/restart and reconcile in FIFO order without duplicate committed observations. |
| AC-028 | Accepted | JSONL, JSON, Markdown, and CSV round trips passed with filters, chronology, policy revisions, integrity metadata, atomic publication, mode `0600`, and explicit limits; the stress case disclosed 1,000 of 1,025 matching events. |
| AC-029 | Accepted | Coordinator restart cases resume sources, evaluator lease/cursor, violations, notice reservations, and outboxes. |
| AC-030 | Accepted | Initialization, loop, route, and transport faults publish degraded health without failing app, Manager, or ordinary tool startup. |
| AC-031 | Accepted | App-hosted and native UI tests expose source, violation, evidence, correction, occurrence, delivery, degraded-state, picker, and export workflows. |
| AC-032 | Limited | Stable accessibility identifiers and labels, non-color textual state, native controls, keyboard dismissal, and automated accessibility queries passed. A human physical VoiceOver listening session was not performed. |
| AC-033 | Accepted | The bundled offline Rune Forge guide explains immediate acceptance, interpretation states, notices, export, outage behavior, and strict non-interference. |
| AC-034 | Accepted | A 2,000-observation burst admitted synchronously in under one second while network delivery remained asynchronous and bounded. |
| AC-035 | Accepted | Sparse 2 GiB source, 150-entry traversal, 1,025-event export, 2,000-observation burst, caps, drops, truncation metadata, and restart cases cover bounded large inputs. |
| AC-036 | Accepted | Notice, observation, payload, and encoded-storage tests retain bounded identity/status and SHA-256 evidence while excluding arguments, result bodies, credentials, and secret fixtures. |
| AC-037 | Accepted | Both SwiftPM products, the canonical Xcode workspace, app-hosted tests, native UI tests, strict signing verification, and explicit project membership passed. |
| AC-038 | Accepted | README, User Guide, Unreleased changelog, roadmap, architecture, documentation index, Guided Mode, product record, qualification status, acceptance, and handoff agree with the delivered behavior and limits. |
| AC-039 | Accepted | Changed-content and RF-SJ commit-history scans found no model/tool attribution; all RF-SJ checkpoints through RF-SJ-09 have valid owner signatures. |
| AC-040 | Accepted | Work was delivered as small signed checkpoints directly to synchronized `main`, with no PR under the controlling owner workflow; the final handoff records evidence and limits. |

## Integrated verification

- Full SwiftPM regression: 1,687 tests executed, 12 explicit skips, zero
  failures. The first run had two expectation failures in a protected-path
  precedence test; the corrected test now expects the more specific
  `manager_policy_path_protected` result for whole-home deletion and movement.
  The exact case then passed 1/1, its class passed 94/94, and the full suite
  passed on rerun.
- App-hosted Rune Forge and Guided Mode: 9/9 passed.
- Native UI: 5/5 passed for all-destination navigation, all-guide routing,
  immediate opaque-source acceptance during Manager outage, native picker
  presentation/cancellation, and four-format export presentation/cancellation.
- RF-SJ-09 integrated regressions retained 58/58 Stjornarvald, 9/9 managed
  step, 20/20 MCP, 3/3 Thread Sanitizer, 4/4 canonical Core graph, and 3/3
  app-hosted results.
- The ordinary Apple Development-signed Debug workspace build and strict deep
  signature verification passed for the delivered product graph.

Existing `ProjectContextService` priority-inversion warnings and one managed
test SQLite teardown diagnostic remain bounded observations. They are not
represented as a clean whole-application performance result.

## Closeout

Rune Forge Development Policy and Stjornarvald are implemented. Every selected
policy source is accepted; Raven Forge Development is continuously applied;
detected violations are reported to the coding agent and retained in the
exportable policy log; and fault-injection evidence shows Stjornarvald does not
interfere with development.

The remaining physical VoiceOver session is an accessibility-validation limit,
not an implementation defect or a release gate pass. The owner will separately
perform release qualification and shipment.
