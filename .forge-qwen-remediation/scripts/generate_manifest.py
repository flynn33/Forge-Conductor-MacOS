#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {"MANIFEST.json", "PACKAGE_VALIDATION.json"}
files = []
for path in sorted(ROOT.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(ROOT).as_posix()
    if relative in EXCLUDED or relative.startswith("work/") or "/__pycache__/" in f"/{relative}" or relative.endswith(".pyc"):
        continue
    data = path.read_bytes()
    files.append({
        "path": relative,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    })
payload = {
    "schema_version": 1,
    "package": "Forge-Conductor-Shippable-Remediation-Qwen-Code-3.8-27B-4bit-Package",
    "files": files,
}
(ROOT / "MANIFEST.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(f"wrote {len(files)} entries")
