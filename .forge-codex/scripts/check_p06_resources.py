#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
inventory = json.loads(
    (root / ".forge-codex/evidence/P06-resource-policy-inventory.json").read_text()
)
assert inventory["unbounded_long_lived_collections"] == 0
assert len(inventory["resources"]) >= 20
assert all(item["enforced"] and item["maximum"] for item in inventory["resources"])

sources = {
    "policy": (root / "Sources/ForgeConductorCore/Infrastructure/ResourcePolicy.swift").read_text(),
    "process": (root / "Sources/ForgeConductorCore/Infrastructure/ProcessRunner.swift").read_text(),
    "logs": (root / "Sources/ForgeConductorCore/Infrastructure/DiagnosticLog.swift").read_text(),
    "telemetry": (root / "Sources/ForgeConductorCore/Telemetry/TelemetryService.swift").read_text(),
    "engine": (root / "Sources/ForgeConductorCore/Telemetry/RealtimeMetricsEngine.swift").read_text(),
    "http": (root / "Sources/ForgeConductorCore/Dashboard/HTTPResponder.swift").read_text(),
    "router": (root / "Sources/ForgeConductorCore/Application/ToolRouter.swift").read_text(),
    "continuity": (root / "Sources/ForgeConductorCore/Application/ContinuityAutomation.swift").read_text(),
    "sessions": (root / "Sources/ForgeConductorCore/Application/AgentSessionService.swift").read_text(),
    "catalog": (root / "Sources/ForgeConductorCore/Application/AgentCatalog.swift").read_text(),
}

assert "ResourcePressureMonitor" in sources["policy"]
assert "min(max(0, maximumOutputBytes), maximumRetainedOutputBytes)" in sources["process"]
assert "try rotateIfNeeded(url)" in sources["logs"]
assert "applyMemoryPressure" in sources["telemetry"]
assert sources["telemetry"].count("maximumListeners = 128") == 1
assert sources["engine"].count("maximumListeners = 128") == 1
assert "maximumLiveStreams = 32" in sources["http"]
assert "maximumPendingFrames = 1" in sources["http"]
assert "maxTrackedClients = 256" in sources["router"]
assert "maxTrackedClients = 128" in sources["continuity"]
assert "maxImplicitRootsPerClient = 16" in sources["continuity"]
assert "maxMemoryBindings = 128" in sources["sessions"]
assert "maximumEntries = 256" in sources["catalog"]

app_sources = "\n".join(
    path.read_text()
    for path in (root / "Sources/ForgeConductorApp").rglob("*.swift")
)
for forbidden in ("waitUntilExit()", "Thread.sleep", ".wait()"):
    assert forbidden not in app_sources, f"main-actor blocking token remains: {forbidden}"

app_model = (root / "Sources/ForgeConductorApp/AppModel.swift").read_text()
for call in ("DashboardPortGuard.inspect", "node.startService()"):
    position = app_model.index(call)
    preceding = app_model[max(0, position - 500):position]
    assert "Task.detached" in preceding, f"{call} is not detached from MainActor"

bounded_tests = (
    root / ".forge-codex/evidence/EVID-20260823T195742Z-533a0ffc8a.stdout.txt"
).read_text()
strict_suite = (
    root / ".forge-codex/evidence/EVID-20260823T195808Z-9893a6484a.stdout.txt"
).read_text()
assert "Executed 24 tests" in bounded_tests and "0 failures" in bounded_tests
assert "Executed 249 tests" in strict_suite and "0 failures" in strict_suite

print(json.dumps({
    "valid": True,
    "resource_entries": len(inventory["resources"]),
    "unbounded_long_lived_collections": 0,
    "main_actor_blocking_tokens": 0,
    "memory_pressure_monitor": True,
    "bounded_resource_test_failures": 0,
    "strict_suite_failures": 0,
}, indent=2, sort_keys=True))
