#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--root")
parser.add_argument("--allow-missing-input-archive", action="store_true")
args = parser.parse_args()
root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[1]
manifest_path = root / "MANIFEST.json"
manifest = json.loads(manifest_path.read_text())
allowed_missing = {"inputs/Forge-Conductor-MacOS-main.zip"} if args.allow_missing_input_archive else set()
errors: list[str] = []
seen: set[str] = set()
for item in manifest.get("files", []):
    relative = item["path"]
    if relative in seen:
        errors.append(f"duplicate manifest path: {relative}")
        continue
    seen.add(relative)
    path = root / relative
    if not path.is_file():
        if relative not in allowed_missing:
            errors.append(f"missing: {relative}")
        continue
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != item["bytes"]:
        errors.append(f"size mismatch: {relative}")
    if digest != item["sha256"]:
        errors.append(f"hash mismatch: {relative}")
    executable = bool(path.stat().st_mode & 0o111)
    if executable != bool(item.get("executable", False)):
        errors.append(f"executable-bit mismatch: {relative}")

actual = {
    str(path.relative_to(root))
    for path in root.rglob("*")
    if path.is_file() and path.name != "MANIFEST.json"
}
# Validation output may be generated after the manifest and is explicitly ignored.
actual.discard("PACKAGE_VALIDATION.json")
actual.discard("INSTALLED_FROM_REPOSITORY_HEAD")
unmanifested = sorted(actual - seen)
if unmanifested:
    errors.extend(f"unmanifested: {item}" for item in unmanifested)
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print(f"Manifest validation passed: {len(seen)} entries")
