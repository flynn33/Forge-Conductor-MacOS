#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
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
SKIP = frozenset({".git", ".build", "DerivedData", "build", "dist"})
GENERATED_OR_IMMUTABLE = frozenset({"audit", "backups", "evidence", "state"})
AUTONOMY_GENERATED = frozenset({"command-logs", "evidence"})
POLICY_EXAMPLES = frozenset({
    ".github/agents/attribution-guard.agent.md",
    ".forge-continuity-design/scripts/validate_package.py",
})
# These reviewed regex examples are bound to the exact path, position and
# UTF-8 line bytes (including the newline). A changed or additional line still
# receives normal scanning; the workflow itself is never exempted.
PINNED_POLICY_EXAMPLE_LINES = {
    ".github/workflows/no-ai-attribution.yml": {
        100: "51e6e5f032b42fb437c3053c22b11664cf8319206e55c0e55de7e4d0d672ae3f",
        184: "08a1200e51df8e7e9560c82ef7e85c1384aefbb38a7f2a6b8b7b7fbb74d94558",
        231: "08a1200e51df8e7e9560c82ef7e85c1384aefbb38a7f2a6b8b7b7fbb74d94558",
        272: "ba04ba65269ace162486df40950af4e35f0a546fbaf0123cb153b65ca9f10e9c",
        326: "edbad54512651f15036fabadd5c164a4174be7acf5f5e321265e4d9527484b2b",
    },
}
BINARY_SUFFIXES = frozenset({
    ".zip", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".trace",
    ".memgraph", ".sqlite", ".sqlite3", ".xcassets", ".car",
})
PATTERNS = (
    re.compile(
        r"generated\s+by\s+(?:chatgpt|codex|an?\s+ai|artificial intelligence|openai)",
        re.I,
    ),
    re.compile(
        r"(?:written|authored|created)\s+by\s+(?:chatgpt|codex|an?\s+ai|artificial intelligence|openai)",
        re.I,
    ),
    re.compile(
        r"co-authored-by:.*(?:chatgpt|codex|openai|artificial intelligence)",
        re.I,
    ),
    re.compile(r"\bai-generated\b", re.I),
    re.compile(r"\bmachine-generated\s+(?:code|content|documentation)\b", re.I),
)


def scan_repository(
    root: Path,
    *,
    maximum_file_bytes: int = MAXIMUM_SCAN_FILE_BYTES,
    maximum_total_bytes: int = MAXIMUM_SCAN_TOTAL_BYTES,
    maximum_entries: int = MAXIMUM_REPOSITORY_SCAN_ENTRIES,
) -> list[dict[str, object]]:
    root = root.resolve(strict=True)
    budget = BoundedReadBudget(maximum_total_bytes, "attribution scan")
    entries = bounded_repository_tree(
        root,
        skip_names=SKIP,
        maximum_entries=maximum_entries,
        reject_symlinks=True,
    )
    hits: list[dict[str, object]] = []
    for entry in entries:
        if not entry.is_file:
            continue
        relative = entry.relative_path
        root_is_control = root.name == ".forge-codex"
        root_is_autonomy = root.name == ".forge-autonomy-state"
        within_control = root_is_control or bool(
            relative.parts and relative.parts[0] == ".forge-codex"
        )
        within_autonomy = root_is_autonomy or bool(
            relative.parts and relative.parts[0] == ".forge-autonomy-state"
        )
        control_parts = (
            relative.parts
            if root_is_control
            else relative.parts[1:]
            if relative.parts and relative.parts[0] == ".forge-codex"
            else relative.parts
        )
        autonomy_parts = (
            relative.parts
            if root_is_autonomy
            else relative.parts[1:]
            if relative.parts and relative.parts[0] == ".forge-autonomy-state"
            else relative.parts
        )
        exempt_control = bool(
            within_control
            and control_parts
            and control_parts[0] in GENERATED_OR_IMMUTABLE
        )
        exempt_autonomy = bool(
            within_autonomy
            and autonomy_parts
            and autonomy_parts[0] in AUTONOMY_GENERATED
        )
        if (
            relative.name in {"scan_attribution.py", "PACKAGE_VALIDATION.json"}
            or exempt_control
            or exempt_autonomy
            or relative.as_posix() in POLICY_EXAMPLES
            or relative.suffix.lower() in BINARY_SUFFIXES
        ):
            continue
        raw = read_bounded_repository_bytes(
            root,
            relative,
            label=f"attribution scan input {relative}",
            maximum_bytes=maximum_file_bytes,
            budget=budget,
        )
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            continue
        pinned_lines = PINNED_POLICY_EXAMPLE_LINES.get(relative.as_posix(), {})
        for line_number, line in enumerate(text.splitlines(keepends=True), 1):
            expected_hash = pinned_lines.get(line_number)
            if (
                expected_hash is not None
                and hashlib.sha256(line.encode("utf-8")).hexdigest() == expected_hash
            ):
                continue
            for pattern in PATTERNS:
                if not pattern.search(line):
                    continue
                if len(hits) >= MAXIMUM_SCAN_HITS:
                    raise EvidenceSupportError(
                        f"attribution scan exceeds {MAXIMUM_SCAN_HITS} findings"
                    )
                hits.append({
                    "path": relative.as_posix(),
                    "line": line_number,
                    "text": line.strip()[:500],
                    "pattern": pattern.pattern,
                })
    return hits


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args(arguments)
    try:
        root = Path(args.root).resolve(strict=True)
        hits = scan_repository(root)
    except (EvidenceSupportError, OSError) as error:
        print(f"Authorship-attribution scan failed closed: {error}", file=sys.stderr)
        return 1
    if hits:
        for hit in hits:
            print(
                f"{hit['path']}:{hit['line']}: {hit['text']}",
                file=sys.stderr,
            )
        return 1
    print(f"Authorship-attribution scan passed for {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
