#!/usr/bin/env python3
from __future__ import annotations
import argparse
import re
from pathlib import Path

PATTERNS = [
    re.compile(r"co-authored-by:", re.I),
    re.compile(
        r"generated\s+by\s+(chatgpt|codex|qwen(?:\s+code)?|openai|an?\s+ai)",
        re.I,
    ),
    re.compile(
        r"written\s+by\s+(chatgpt|codex|qwen(?:\s+code)?|an?\s+ai)",
        re.I,
    ),
    re.compile(r"ai[- ]generated", re.I),
    re.compile(
        r"assisted\s+by\s+(chatgpt|codex|qwen(?:\s+code)?|openai)",
        re.I,
    ),
]
EXCLUDED_PREFIXES = (
    ".git/",
    ".build/",
    ".qwen/",
    ".forge-qwen-remediation/",
    ".forge-qwen-state/",
    ".forge-continuity-design/",
    ".forge-e2/",
    ".forge-codex/evidence/",
    ".forge-autonomy-state/evidence/",
)

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    repo = Path(args.repo).resolve()
    hits = []
    for path in repo.rglob("*"):
        if not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
            continue
        relative = path.relative_to(repo).as_posix()
        if relative in {
            "scripts/scan_publication_hygiene.py",
            "PACKAGE_VALIDATION.json",
            "MANIFEST.json",
        }:
            continue
        if any(relative.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
            continue
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except Exception:
            continue
        for line_number, line in enumerate(lines, 1):
            if any(pattern.search(line) for pattern in PATTERNS):
                hits.append(
                    f"{relative}:{line_number}:{line[:240]}"
                )
    if hits:
        print("\n".join(hits))
        return 1
    print("publication hygiene scan passed")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
