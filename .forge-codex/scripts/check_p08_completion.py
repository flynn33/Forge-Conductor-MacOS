#!/usr/bin/env python3
"""Validate P08 implementation, evidence, and finding closure."""

from __future__ import annotations

import json
import pathlib


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


required_sources = [
    "Sources/ForgeConductorCore/Domain/ContinuityModels.swift",
    "Sources/ForgeConductorCore/Application/ContinuityCoordinator.swift",
    "Sources/ForgeConductorCore/Application/Tools/ContinuityLifecycleToolPack.swift",
    "Sources/ForgeConductorCore/Infrastructure/ProjectMemoryRepository.swift",
    "Tests/ForgeConductorTests/ContinuityCoordinatorTests.swift",
]
for relative in required_sources:
    require((root / relative).is_file(), f"missing {relative}")

models = (root / required_sources[0]).read_text()
for state in [
    "active", "checkpointPreparing", "checkpointPersisted", "successorRequested",
    "successorCreated", "successorBootstrapping", "successorAcknowledged", "predecessorSealed",
]:
    require(f"case {state}" in models or f", {state}" in models, f"missing state {state}")
require("maximumEncodedBytes = 128 * 1024" in models, "handoff byte bound missing")
require("maximumListItems = 128" in models, "handoff list bound missing")

tools = (root / required_sources[2]).read_text()
for tool in [
    "continuity.checkpoint", "continuity.prepare_handoff", "continuity.get_pending_handoff",
    "continuity.acknowledge_handoff", "continuity.resume", "continuity.status",
    "continuity.request_rollover",
]:
    require(tool in tools, f"missing tool {tool}")

process = load(".forge-codex/evidence/P08-mcp-process-conformance.json")
require(process.get("ok") is True, "process conformance failed")
required_checks = {
    "tool_inventory", "tool_schemas", "memory_only_capability_fallback",
    "durable_handoff_restart", "exact_acknowledgement_rejection",
    "rejected_acknowledgement_no_mutation", "idempotent_acknowledgement",
    "predecessor_seal", "active_session_swap",
}
require(required_checks <= set(process.get("checks", [])), "process conformance is incomplete")

focused = (root / ".forge-codex/evidence/EVID-20260823T204207Z-fb406e171d.stdout.txt").read_text()
strict = (root / ".forge-codex/evidence/EVID-20260823T204247Z-4561e060f3.stdout.txt").read_text()
require("Executed 5 tests" in focused and "0 failures" in focused, "focused suite proof missing")
require("Executed 261 tests" in strict and "0 failures" in strict, "strict suite proof missing")

findings = load(".forge-codex/state/findings-resolution.json")["findings"]
p08 = [finding for finding in findings if finding.get("assigned_phase") == "P08"]
require(len(p08) == 4, "unexpected P08 finding count")
require(all(finding.get("status") == "resolved" for finding in p08), "P08 findings remain open")
require(all(finding.get("ownership_disposition") for finding in p08), "P08 disposition missing")
require(all(finding.get("validation_evidence") for finding in p08), "P08 validation evidence missing")

report = load(".forge-codex/evidence/P08-continuity-report.json")
owners = load(".forge-codex/evidence/P08-resource-owner-matrix.json")
parity = load(".forge-codex/evidence/P08-feature-parity.json")
require(report.get("status") == "passed", "P08 report status failed")
require(len(report.get("crash_points", [])) == 9, "crash matrix incomplete")
require(len(owners.get("owners", [])) >= 6, "owner matrix incomplete")
require(not parity.get("removed") and not parity.get("unknown") and not parity.get("untested"), "feature parity failed")

print(json.dumps({
    "ok": True,
    "phase": "P08",
    "focused_tests": 5,
    "strict_tests": 261,
    "crash_points": len(report["crash_points"]),
    "resolved_findings": len(p08),
    "process_checks": sorted(required_checks),
}, indent=2, sort_keys=True))
