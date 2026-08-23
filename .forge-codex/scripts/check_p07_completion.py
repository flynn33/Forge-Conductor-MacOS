#!/usr/bin/env python3
"""Validate P07 implementation, evidence, and finding closure."""

from __future__ import annotations

import json
import pathlib
import sys


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


required_sources = [
    "Sources/ForgeConductorCore/Domain/ProjectMemoryModels.swift",
    "Sources/ForgeConductorCore/Infrastructure/ProjectMemoryRepository.swift",
    "Sources/ForgeConductorCore/Application/ProjectMemoryService.swift",
    "Sources/ForgeConductorCore/Application/Tools/ProjectMemoryToolPack.swift",
    "Tests/ForgeConductorTests/ProjectMemoryTests.swift",
]
for relative in required_sources:
    require((root / relative).is_file(), f"missing {relative}")

repository_source = (root / required_sources[1]).read_text()
for marker in [
    "PRAGMA journal_mode=WAL", "PRAGMA foreign_keys=ON", "PRAGMA busy_timeout=3000",
    "PRAGMA user_version=1", "quick_check", "memory_records", "memory_links",
    "event_journal", "maximumOpenProjects", "maximumResponseBytes",
]:
    require(marker in repository_source or marker in (root / required_sources[0]).read_text(), f"missing marker: {marker}")

tool_source = (root / required_sources[3]).read_text()
for tool in [
    "project_memory.initialize", "project_memory.remember", "project_memory.remember_batch",
    "project_memory.search", "project_memory.get", "project_memory.update",
    "project_memory.forget", "project_memory.list_recent", "project_memory.link",
    "project_memory.export", "project_memory.import", "project_memory.status",
]:
    require(tool in tool_source, f"missing tool {tool}")

process = load(".forge-codex/evidence/P07-mcp-process-conformance.json")
require(process.get("ok") is True, "process conformance failed")
required_checks = {
    "initialize", "tools_list", "legacy_compatibility", "tool_schemas", "redaction",
    "pagination", "typed_error", "cancellation", "process_restart_durability",
}
require(required_checks <= set(process.get("checks", [])), "process conformance is incomplete")

focused = (root / ".forge-codex/evidence/EVID-20260823T201609Z-581a87dcb8.stdout.txt").read_text()
strict = (root / ".forge-codex/evidence/EVID-20260823T201632Z-6920be9c15.stdout.txt").read_text()
require("Executed 7 tests" in focused and "0 failures" in focused, "focused suite proof missing")
require("Executed 256 tests" in strict and "0 failures" in strict, "strict full-suite proof missing")

findings = load(".forge-codex/state/findings-resolution.json")["findings"]
p07 = [finding for finding in findings if finding.get("assigned_phase") == "P07"]
require(len(p07) == 7, "unexpected P07 finding count")
require(all(finding.get("status") == "resolved" for finding in p07), "P07 findings remain open")
require(all(finding.get("ownership_disposition") for finding in p07), "P07 disposition missing")
require(all(finding.get("validation_evidence") for finding in p07), "P07 validation evidence missing")

report = load(".forge-codex/evidence/P07-project-memory-report.json")
owners = load(".forge-codex/evidence/P07-resource-owner-matrix.json")
parity = load(".forge-codex/evidence/P07-feature-parity.json")
require(report.get("status") == "passed", "P07 report status failed")
require(len(owners.get("owners", [])) >= 7, "owner matrix incomplete")
require("MCP-SERVER-STDIO" in parity.get("preserved", []), "stdio parity missing")

print(json.dumps({
    "ok": True,
    "phase": "P07",
    "focused_tests": 7,
    "strict_tests": 256,
    "resolved_findings": len(p07),
    "process_checks": sorted(required_checks),
}, indent=2, sort_keys=True))
