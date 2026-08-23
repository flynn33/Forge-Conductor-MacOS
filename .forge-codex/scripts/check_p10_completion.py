#!/usr/bin/env python3
"""Validate P10 parity, migration, protocol, and native UI evidence."""

from __future__ import annotations

import json
import pathlib


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


baseline = load(".forge-codex/state/feature-baseline.json")
features = baseline.get("features", [])
require(len(features) == 66, "baseline feature count changed")
require(all(item.get("parity_status") == "preserved" for item in features), "feature parity is incomplete")
require(all(item.get("evidence") and item.get("tests") for item in features), "baseline feature lacks evidence or tests")

project = (root / "ForgeConductor.xcodeproj/project.pbxproj").read_text()
expected_sources = [
    "ContinuityCoordinator.swift", "ContinuityLifecycleToolPack.swift", "ContinuityModels.swift",
    "ForgeNativeSessionHostPlugin.swift", "HostAdapterRegistry.swift", "LatestValueMailbox.swift",
    "MetalGaugeResources.swift", "ProjectMemoryModels.swift", "ProjectMemoryRepository.swift",
    "ProjectMemoryService.swift", "ProjectMemoryToolPack.swift", "ResourcePolicy.swift",
    "RuntimeObservability.swift", "ContinuityCoordinatorTests.swift", "LatestValueMailboxTests.swift",
    "LifecycleOwnershipTests.swift", "NativeSessionHostPluginTests.swift", "ProjectMemoryTests.swift",
    "ResourcePolicyTests.swift", "RuntimeObservabilityTests.swift",
]
for source in expected_sources:
    require(source in project, f"Xcode project is missing {source}")

package = (root / "Package.swift").read_text()
require('.library(name: "ForgeNativeSessionHostPlugin"' in package, "plugin product is absent")
require('name: "ForgeNativeSessionHostPlugin"' in package, "plugin target is absent")

evidence_ids = {
    "EVID-20260823T210530Z-4f9d8de5c7",
    "EVID-20260823T210623Z-182392fa73",
    "EVID-20260823T210632Z-016869a17f",
    "EVID-20260823T210719Z-a3e959a8b6",
    "EVID-20260823T210727Z-dd0087ce58",
}
for evidence_id in evidence_ids:
    record = load(f".forge-codex/evidence/{evidence_id}.json")
    require(record.get("exit_code") == 0 and record.get("timed_out") is False, f"failed evidence {evidence_id}")

ui = (root / ".forge-codex/evidence/EVID-20260823T210530Z-4f9d8de5c7.stdout.txt").read_text()
migrations = (root / ".forge-codex/evidence/EVID-20260823T210632Z-016869a17f.stdout.txt").read_text()
protocol = (root / ".forge-codex/evidence/EVID-20260823T210719Z-a3e959a8b6.stdout.txt").read_text()
strict = (root / ".forge-codex/evidence/EVID-20260823T210727Z-dd0087ce58.stdout.txt").read_text()
require("Executed 4 tests" in ui and "0 failures" in ui, "native UI test proof missing")
require("Executed 6 tests" in migrations and "0 failures" in migrations, "migration test proof missing")
require("Executed 8 tests" in protocol and "0 failures" in protocol, "protocol test proof missing")
require("Executed 265 tests" in strict and "2 tests skipped and 0 failures" in strict, "strict suite proof missing")

parity = load(".forge-codex/evidence/P10-parity-report.json")
migration_report = load(".forge-codex/evidence/P10-migration-report.json")
protocol_report = load(".forge-codex/evidence/P10-protocol-compatibility-report.json")
for report in [parity, migration_report, protocol_report]:
    require(report.get("status") == "passed", "P10 report is not passed")
require(not parity.get("removed") and not parity.get("unknown") and not parity.get("untested"), "parity report has gaps")
require(len(migration_report.get("fixtures", [])) == 6, "migration fixture matrix is incomplete")
require(not protocol_report.get("removed_tools") and not protocol_report.get("schema_breaks"), "protocol compatibility failed")

app_source = (root / "Sources/ForgeConductorApp/ForgeConductorApp.swift").read_text()
sidebar_source = (root / "Sources/ForgeConductorApp/Views/AppSidebarView.swift").read_text()
model_source = (root / "Sources/ForgeConductorApp/AppModel.swift").read_text()
for marker in [
    'CommandMenu("Navigation")', 'CommandMenu("Telemetry")', "Settings {",
    'accessibilityIdentifier("tab-\\(tab.accessibilityID)")', 'case .rig: return "rig"', 'case .manager: return "manager"',
]:
    require(marker in app_source or marker in sidebar_source or marker in model_source, f"UI contract marker is absent: {marker}")

print(json.dumps({
    "ok": True,
    "phase": "P10",
    "baseline_features": len(features),
    "migration_fixtures": len(migration_report["fixtures"]),
    "protocol_checks": len(protocol_report["compatibility_checks"]),
    "native_ui_tests": 4,
    "strict_tests": 265,
    "unknown_features": 0,
}, indent=2, sort_keys=True))
