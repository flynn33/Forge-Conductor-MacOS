#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
binding_path = repo / "Sources/ForgeConductorApp/AppTelemetryBinding.swift"
app_model_path = repo / "Sources/ForgeConductorApp/AppModel.swift"
mailbox_path = repo / "Sources/ForgeConductorCore/Telemetry/LatestValueMailbox.swift"
binding = binding_path.read_text()
app_model = app_model_path.read_text()
mailbox = mailbox_path.read_text()
expected_tab_mapping = {
    "rig": "rig",
    "mcp": "mcp",
    "agents": "agents",
    "tools": "tools",
    "feed": "feed",
    "diagnostics": "diagnostics",
    "manager": "manager",
}

listener_start = binding.index("frameListenerID = app.telemetry.addListener")
listener_end = binding.index("\n        }", listener_start) + len("\n        }")
listener = binding[listener_start:listener_end]

checks = {
    "listener-publishes-directly": "mailbox?.publish(frame, generation: generation)" in listener,
    "listener-creates-no-task": "Task" not in listener,
    "mailbox-newest-capacity-one": ".bufferingNewest(1)" in mailbox,
    "mailbox-owns-consumer-task": "private var consumerTask: Task<Void, Never>?" in mailbox,
    "mailbox-has-explicit-stop": "public func stop()" in mailbox,
    "mailbox-invalidates-generations": "requestedGeneration == generation" in mailbox,
    "mailbox-bounds-logical-slots": "(inFlight ? 1 : 0) + (hasBufferedLatest ? 1 : 0)" in mailbox,
    "tab-accessibility-mapping-is-complete": all(
        f'case .{case}: return "{identifier}"' in app_model
        for case, identifier in expected_tab_mapping.items()
    ),
    "tab-accessibility-identifiers-are-unique": len(set(expected_tab_mapping.values()))
    == len(expected_tab_mapping),
}

payload = {
    "schema_version": 1,
    "phase": "P03",
    "tab_accessibility_mapping": expected_tab_mapping,
    "checks": [{"name": name, "passed": passed} for name, passed in checks.items()],
    "valid": all(checks.values()),
}
print(json.dumps(payload, indent=2, sort_keys=True))
raise SystemExit(0 if payload["valid"] else 1)
