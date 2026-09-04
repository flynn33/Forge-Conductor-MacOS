#!/usr/bin/env python3
from __future__ import annotations
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = []
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.name == "MANIFEST.json":
        continue
    data = path.read_bytes()
    files.append({
        "path": str(path.relative_to(root)),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "executable": bool(path.stat().st_mode & 0o111),
    })
manifest = {
    "schema_version": 1,
    "package": "Forge-Conductor-E2-Secure-Filesystem-Codex-Package",
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "authoritative_repository": "flynn33/Forge-Conductor-MacOS",
    "minimum_baseline_commit": "6288210d82270b26add5f0e078d150bc4377bd62",
    "finding": "FC-FILESYSTEM-PATH-TOCTOU-001",
    "files": files,
}
(root / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Wrote {len(files)} manifest entries")
