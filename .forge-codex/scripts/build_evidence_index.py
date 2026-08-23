#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path


repo = Path(__file__).resolve().parents[2]
evidence_dir = repo / ".forge-codex" / "evidence"
output = repo / ".forge-codex" / "state" / "evidence-index.json"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


records = []
for path in sorted(evidence_dir.iterdir()):
    if not path.is_file():
        continue
    records.append({
        "path": str(path.relative_to(repo)),
        "sha256": digest(path),
        "bytes": path.stat().st_size,
    })

payload = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "repository": str(repo),
    "artifact_count": len(records),
    "artifacts": records,
}
temporary = output.with_suffix(".tmp")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
os.replace(temporary, output)
print(json.dumps({"output": str(output), "artifact_count": len(records)}, indent=2))
