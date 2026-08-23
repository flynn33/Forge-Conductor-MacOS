#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
metal_dir = repo / "Sources/ForgeConductorApp/Metal"
metal_files = sorted(metal_dir.glob("*.swift"))
metal_source = "\n".join(path.read_text() for path in metal_files)
resources = (metal_dir / "MetalGaugeResources.swift").read_text()
rig = (repo / "Sources/ForgeConductorApp/Views/Rig/RigDashboardView.swift").read_text()
app_model = (repo / "Sources/ForgeConductorApp/AppModel.swift").read_text()

checks = {
    "one-shared-command-queue-construction": metal_source.count("makeCommandQueue()") == 1,
    "one-shared-pipeline-construction": metal_source.count("makeRenderPipelineState(descriptor:") == 1,
    "buffer-allocation-only-in-capacity-growth-owner": metal_source.count("makeBuffer(") == 1
    and "private func ensureCapacity" in resources,
    "persistent-buffer-reuses-capacity": "capacityBytes < requiredBytes" in resources,
    "metal-views-are-paused": "view.isPaused = true" in resources,
    "metal-views-use-needs-display": "view.enableSetNeedsDisplay = true" in resources,
    "all-renderers-reject-static-draws": metal_source.count("guard dirty else") == 5,
    "all-renderers-have-explicit-dismantle": metal_source.count("static func dismantleNSView") == 5,
    "surface-lifetime-is-counted": "final class GaugeSurfaceLifetime" in resources,
    "rig-has-no-independent-timeline-clock": "TimelineView" not in rig,
    "auto-refresh-propagates-to-binding": "didSet { telemetryBinding.autoRefresh = autoRefresh }" in app_model,
}

payload = {
    "schema_version": 1,
    "phase": "P04",
    "metal_files": [str(path.relative_to(repo)) for path in metal_files],
    "checks": [{"name": name, "passed": passed} for name, passed in checks.items()],
    "valid": all(checks.values()),
}
print(json.dumps(payload, indent=2, sort_keys=True))
raise SystemExit(0 if payload["valid"] else 1)
