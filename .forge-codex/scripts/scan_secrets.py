#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from evidence_support import (
    BoundedReadBudget,
    EvidenceSupportError,
    MAXIMUM_REPOSITORY_SCAN_ENTRIES,
    bounded_repository_tree,
    read_bounded_repository_bytes,
)


MAXIMUM_SCAN_FILE_BYTES = 64 * 1024 * 1024
MAXIMUM_SCAN_TOTAL_BYTES = 512 * 1024 * 1024
MAXIMUM_SCAN_HITS = 10_000
SKIP = frozenset({
    ".git", ".build", "DerivedData", "build", "dist", "inputs", "audit",
    "evidence",
})
BINARY_SUFFIXES = frozenset({
    ".zip", ".png", ".jpg", ".jpeg", ".pdf", ".sqlite", ".sqlite3",
    ".trace", ".memgraph",
})
PATTERNS = (
    (
        "private-key",
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ),
    (
        "generic-token",
        re.compile(
            r"(?i)\b(?:api[_-]?key|access[_-]?token|secret)\b\s*[:=]\s*[\"']?[A-Za-z0-9_./+\-=]{20,}"
        ),
    ),
    (
        "bearer-token",
        re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}"),
    ),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
)


def scan_repository(
    root: Path,
    *,
    maximum_file_bytes: int = MAXIMUM_SCAN_FILE_BYTES,
    maximum_total_bytes: int = MAXIMUM_SCAN_TOTAL_BYTES,
    maximum_entries: int = MAXIMUM_REPOSITORY_SCAN_ENTRIES,
) -> list[tuple[str, int, str, str]]:
    root = root.resolve(strict=True)
    budget = BoundedReadBudget(maximum_total_bytes, "secret scan")
    entries = bounded_repository_tree(
        root,
        skip_names=SKIP,
        maximum_entries=maximum_entries,
        reject_symlinks=True,
    )
    hits: list[tuple[str, int, str, str]] = []
    for entry in entries:
        if not entry.is_file:
            continue
        relative = entry.relative_path
        if (
            relative.name == "scan_secrets.py"
            or relative.suffix.lower() in BINARY_SUFFIXES
        ):
            continue
        raw = read_bounded_repository_bytes(
            root,
            relative,
            label=f"secret scan input {relative}",
            maximum_bytes=maximum_file_bytes,
            budget=budget,
        )
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            for name, pattern in PATTERNS:
                if (
                    pattern.search(line)
                    and "example" not in line.lower()
                    and "pattern" not in line.lower()
                ):
                    if len(hits) >= MAXIMUM_SCAN_HITS:
                        raise EvidenceSupportError(
                            f"secret scan exceeds {MAXIMUM_SCAN_HITS} findings"
                        )
                    hits.append(
                        (
                            relative.as_posix(),
                            line_number,
                            name,
                            line.strip()[:300],
                        )
                    )
    return hits


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args(arguments)
    try:
        root = Path(args.root).resolve(strict=True)
        hits = scan_repository(root)
    except (EvidenceSupportError, OSError) as error:
        print(f"Secret scan failed closed: {error}", file=sys.stderr)
        return 1
    if hits:
        for path, line, name, text in hits:
            print(f"{path}:{line} [{name}] {text}", file=sys.stderr)
        return 1
    print(f"Secret scan passed for {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
