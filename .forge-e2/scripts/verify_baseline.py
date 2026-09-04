#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--repo", default=".")
parser.add_argument("--allow-dirty", action="store_true")
args = parser.parse_args()

repo = Path(args.repo).resolve()
package = Path(__file__).resolve().parents[1]
baseline = json.loads((package / "evidence/source-baseline.json").read_text())
expected = baseline["authoritative_commit"]

def git(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *arguments],
        text=True,
        capture_output=True,
        check=check,
    )

head = git("rev-parse", "--verify", "HEAD").stdout.strip()
branch = git("branch", "--show-current").stdout.strip()
raw_status = git("status", "--porcelain=v1", "--untracked-files=all").stdout
ignored_prefixes = (
    ".forge-e2/",
    ".forge-e2-state/",
    ".forge-e2.backup.",
    ".forge-e2.stage.",
)
status_lines = []
for line in raw_status.splitlines():
    path_text = line[3:] if len(line) >= 4 else line
    # Rename records may contain "old -> new"; neither side may escape the check.
    candidates = [part.strip() for part in path_text.split(" -> ")]
    if candidates and all(candidate.startswith(ignored_prefixes) for candidate in candidates):
        continue
    status_lines.append(line)
status = "\n".join(status_lines)
if status:
    status += "\n"

exists = git("cat-file", "-e", f"{expected}^{{commit}}", check=False).returncode == 0
if not exists:
    raise SystemExit(
        "Required merged baseline commit is absent from this checkout. "
        "Use a complete current repository clone; do not implement E2 on the historical input archive."
    )

ancestor = git("merge-base", "--is-ancestor", expected, head, check=False).returncode == 0
if not ancestor:
    raise SystemExit(
        f"HEAD {head} is not a descendant of required baseline {expected}. "
        "Do not reset or overwrite work; create a clean worktree from current main."
    )
if status and not args.allow_dirty:
    raise SystemExit(
        "Repository has uncommitted changes. Preserve them and create a clean worktree before E2 implementation."
    )

record = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "repository": str(repo),
    "branch": branch,
    "head": head,
    "required_ancestor": expected,
    "is_descendant": ancestor,
    "dirty": bool(status),
    "status_porcelain": status.splitlines(),
    "ignored_package_state_paths": list(ignored_prefixes),
}
state = repo / ".forge-e2-state"
state.mkdir(exist_ok=True)
(state / "baseline.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
