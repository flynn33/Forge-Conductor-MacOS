#!/usr/bin/env python3
from __future__ import annotations
import re, sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
patterns = [
    re.compile(r"Co-authored-by:\s*(ChatGPT|OpenAI|Codex|Claude|Gemini)", re.I),
    re.compile(r"(generated|written|authored)\s+by\s+(an?\s+)?(AI|assistant|model)", re.I),
    re.compile(r"\bAI[- ]generated\b", re.I),
]
skip = {".git", ".build", "DerivedData", ".forge-e2"}
hits = []
for path in root.rglob("*"):
    if not path.is_file() or any(part in skip for part in path.parts):
        continue
    if path.stat().st_size > 4 * 1024 * 1024:
        continue
    try:
        text = path.read_text(errors="ignore")
    except Exception:
        continue
    for pattern in patterns:
        if pattern.search(text):
            hits.append(str(path.relative_to(root)))
            break
if hits:
    print("Attribution policy violations:")
    print("\n".join(hits))
    raise SystemExit(1)
print("Attribution scan passed")
