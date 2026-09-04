#!/usr/bin/env python3
from __future__ import annotations
import re, sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
sensitive = [
    root / "Sources/ForgeConductorCore/Application/Tools/FilesystemToolPack.swift",
]
patterns = {
    "FileManager remove": re.compile(r"\bFileManager\b.*\bremoveItem\s*\("),
    "FileManager move": re.compile(r"\bFileManager\b.*\bmoveItem\s*\("),
    "Foundation recursive enumeration": re.compile(r"\.enumerator\s*\("),
    "path authority realpath": re.compile(r"\brealpath\s*\("),
    "path authority symlink resolution": re.compile(r"resolvingSymlinksInPath"),
    "external find": re.compile(r'"/usr/bin/find"'),
    "external cp": re.compile(r'"/bin/cp"'),
}
failures = []
for path in sensitive:
    if not path.exists():
        continue
    text = path.read_text(errors="ignore")
    for name, pattern in patterns.items():
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            failures.append(f"{path.relative_to(root)}:{line}: {name}")

# Compare-then-mutate heuristic in secure filesystem sources.
for path in (root / "Sources").rglob("*.swift"):
    text = path.read_text(errors="ignore")
    if "fstatat" in text and ("unlinkat" in text or "renameatx_np" in text):
        # This is a review warning; allow explicit atomic-capture files with marker.
        if "E2_ATOMIC_CAPTURE_REVIEWED" not in text:
            failures.append(f"{path.relative_to(root)}: requires manual compare/mutate review")

if failures:
    print("\n".join(failures))
    raise SystemExit(1)
print("E2 source guard passed")
