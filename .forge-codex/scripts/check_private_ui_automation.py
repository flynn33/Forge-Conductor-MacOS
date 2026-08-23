#!/usr/bin/env python3
"""Reject private or UI-driving automation from host-adapter implementation paths."""

from __future__ import annotations

import json
import pathlib
import re


root = pathlib.Path(__file__).resolve().parents[2]
source_root = root / "Sources"
plugin_root = source_root / "ForgeNativeSessionHostPlugin"
private_patterns = [
    re.compile(value, re.IGNORECASE)
    for value in [r"AXUIElement", r"CGEvent", r"NSAppleScript", r"System Events"]
]
plugin_automation_patterns = [
    re.compile(value, re.IGNORECASE)
    for value in [r"osascript", r"AppleScript", r"Accessibility"]
]
violations = []
for path in sorted(source_root.rglob("*.swift")):
    text = path.read_text(errors="replace")
    patterns = private_patterns + (plugin_automation_patterns if plugin_root in path.parents else [])
    for pattern in patterns:
        for match in pattern.finditer(text):
            violations.append({
                "path": str(path.relative_to(root)),
                "line": text.count("\n", 0, match.start()) + 1,
                "pattern": pattern.pattern,
            })

result = {
    "ok": not violations,
    "scope": ["Sources/**/*.swift", "all private UI APIs", "all plugin UI automation"],
    "allowed_existing_lifecycle_integration": "LMStudioDeployService may use public app activation and termination without UI element control.",
    "violations": violations,
}
print(json.dumps(result, indent=2, sort_keys=True))
raise SystemExit(0 if not violations else 1)
