#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


parser = argparse.ArgumentParser()
parser.add_argument("--repo", default=".")
parser.add_argument(
    "--index",
    default=".forge-continuity-design/evidence/source-evidence-index.json",
)
arguments = parser.parse_args()

repository = Path(arguments.repo).resolve()
index_path = (repository / arguments.index).resolve()
index = json.loads(index_path.read_text(encoding="utf-8"))
results = []

for finding in index["findings"]:
    source_path = repository / finding["path"]
    lines = source_path.read_text(encoding="utf-8").splitlines()
    actual = digest(source_path)
    results.append(
        {
            "id": finding["id"],
            "path": finding["path"],
            "expected_sha256": finding["file_sha256"],
            "actual_sha256": actual,
            "hash_matches": actual == finding["file_sha256"],
            "line_range_valid": 1 <= finding["start_line"] <= finding["end_line"] <= len(lines),
        }
    )

report = {
    "schema_version": 1,
    "repository": str(repository),
    "index": str(index_path),
    "finding_count": len(results),
    "unique_source_count": len({item["path"] for item in results}),
    "all_hashes_match": all(item["hash_matches"] for item in results),
    "all_line_ranges_valid": all(item["line_range_valid"] for item in results),
    "results": results,
}
print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if report["all_hashes_match"] and report["all_line_ranges_valid"] else 1)
