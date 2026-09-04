#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

EXCLUDED_PREFIXES = (
    ".git/",
    ".build/",
    "DerivedData/",
    "dist/",
    "__MACOSX/",
    ".qwen/",
    ".forge-qwen-state/",
    ".forge-qwen-remediation/",
    ".forge-continuity-design/",
    ".forge-e2/",
    ".forge-codex/",
    ".forge-autonomy-state/",
)
EXCLUDED_NAMES = {".DS_Store", "AGENTS.md", "QWEN.md"}

def manifest(root: Path) -> dict:
    entries = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if (
            relative in EXCLUDED_NAMES
            or any(relative.startswith(prefix) for prefix in EXCLUDED_PREFIXES)
        ):
            continue
        data = path.read_bytes()
        entries.append({
            "path": relative,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(
            entry["path"].encode()
            + b"\0"
            + str(entry["bytes"]).encode()
            + b"\0"
            + entry["sha256"].encode()
            + b"\n"
        )
    return {
        "schema_version": 1,
        "file_count": len(entries),
        "total_bytes": sum(entry["bytes"] for entry in entries),
        "manifest_sha256": digest.hexdigest(),
        "entries": entries,
    }

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--output")
    parser.add_argument("--digest-only", action="store_true")
    args = parser.parse_args()
    result = manifest(Path(args.repo).resolve())
    if args.output:
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
    print(
        result["manifest_sha256"]
        if args.digest_only
        else json.dumps(result, indent=2)
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
