#!/usr/bin/env python3
from __future__ import annotations
import re
from pathlib import Path

root = Path(".").resolve()
sources = list((root / "Sources").rglob("*.swift"))
text = "\n".join(p.read_text(errors="ignore") for p in sources)

required = ["shell_exec", "/bin/bash", "-lc"]
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit("shell preservation source check failed; missing: " + ", ".join(missing))

# This is intentionally a source preflight. The real MCP smoke remains mandatory.
print("Shell preservation source preflight passed.")
print("Run the real MCP tools/list and shell_exec smoke before completion.")
