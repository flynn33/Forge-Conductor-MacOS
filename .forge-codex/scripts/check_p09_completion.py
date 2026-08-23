#!/usr/bin/env python3
"""Validate P09 plugin implementation and qualification evidence."""

from __future__ import annotations

import json
import pathlib


root = pathlib.Path(__file__).resolve().parents[2]


def load(relative: str):
    return json.loads((root / relative).read_text())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


package = (root / "Package.swift").read_text()
require("ForgeNativeSessionHostPlugin" in package, "native plugin target is absent")
require('.library(name: "ForgeNativeSessionHostPlugin"' in package, "native plugin product is absent")

plugin_path = root / "Sources/ForgeNativeSessionHostPlugin/ForgeNativeSessionHostPlugin.swift"
registry_path = root / "Sources/ForgeConductorCore/Domain/HostAdapterRegistry.swift"
tests_path = root / "Tests/ForgeConductorTests/NativeSessionHostPluginTests.swift"
for path in [plugin_path, registry_path, tests_path]:
    require(path.is_file(), f"missing {path.relative_to(root)}")

plugin = plugin_path.read_text()
for marker in [
    "NativeSessionTransport", "ForgeNativeSessionHostAdapter", "maximumRecords = 4096",
    "maximumResponseChunks = 256", "maximumResponseBytes = 256 * 1024",
    "maximumRetries = 3", "queryByIdempotencyKey: true", "completeFileProtectionUnlessOpen",
    "maximumSessions = 4096", "maximumCancelledOperations = 256",
]:
    require(marker in plugin, f"missing plugin contract marker: {marker}")

focused = (root / ".forge-codex/evidence/EVID-20260823T205539Z-7c10f18ca4.stdout.txt").read_text()
strict = (root / ".forge-codex/evidence/EVID-20260823T205612Z-bbcdb66436.stdout.txt").read_text()
build = load(".forge-codex/evidence/EVID-20260823T205600Z-67248c9a56.json")
external = load(".forge-codex/evidence/P09-external-mcp-compatibility.json")
private_scan = (root / ".forge-codex/evidence/EVID-20260823T205330Z-dd887aaee2.stdout.txt").read_text()
require("Executed 4 tests" in focused and "0 failures" in focused, "plugin test proof missing")
require("Executed 265 tests" in strict and "0 failures" in strict, "strict suite proof missing")
require(build.get("exit_code") == 0, "plugin release target did not build")
require(external.get("ok") is True, "external MCP compatibility failed")
require('"ok": true' in private_scan and '"violations": []' in private_scan, "private UI scan failed")

report = load(".forge-codex/evidence/P09-host-capability-report.json")
owners = load(".forge-codex/evidence/P09-resource-owner-matrix.json")
parity = load(".forge-codex/evidence/P09-feature-parity.json")
require(report.get("status") == "passed" and report.get("selected_mode") == "B", "supported host mode missing")
required = {"create", "bootstrap", "usage_reporting", "resume", "idempotency", "query_by_idempotency_key", "acknowledgement", "cancellation", "deadlines"}
capabilities = report.get("selected_adapter", {}).get("capabilities", {})
require(required <= {key for key, value in capabilities.items() if value is True}, "host capabilities incomplete")
require(len(owners.get("owners", [])) >= 5, "resource owner matrix incomplete")
require(not parity.get("removed") and not parity.get("unknown") and not parity.get("untested"), "feature parity failed")

print(json.dumps({
    "ok": True,
    "phase": "P09",
    "selected_mode": report["selected_mode"],
    "adapter": report["selected_adapter"]["identifier"],
    "plugin_tests": 4,
    "strict_tests": 265,
    "external_checks": len(external.get("checks", [])),
    "private_ui_violations": 0,
}, indent=2, sort_keys=True))
