#!/usr/bin/env python3
from __future__ import annotations
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
skip_parts = {".git", ".build", "DerivedData", ".forge-e2", ".forge-e2-state", "node_modules", ".swiftpm"}
max_bytes = 4 * 1024 * 1024
patterns = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github-token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "openai-key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    "aws-access-key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "generic-secret-assignment": re.compile(
        r"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*[\"']?[A-Za-z0-9_./+\-=]{24,}"
    ),
}
allow_suffixes = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".xcassets", ".car", ".sqlite3", ".db"}
hits: list[str] = []
for path in root.rglob("*"):
    if not path.is_file() or any(part in skip_parts for part in path.parts):
        continue
    if path.suffix.lower() in allow_suffixes or path.stat().st_size > max_bytes:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    for label, pattern in patterns.items():
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            hits.append(f"{path.relative_to(root)}:{line}: {label}")
if hits:
    print("\n".join(hits))
    raise SystemExit(1)
print("Secret scan passed")
