#!/usr/bin/env python3
from __future__ import annotations
import argparse,re,sys
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument("--root",default=".")
args=parser.parse_args()
root=Path(args.root).resolve()
skip={".git",".build","DerivedData","build","dist","inputs","audit","evidence"}
patterns=[
 ("private-key",re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
 ("generic-token",re.compile(r"(?i)\b(?:api[_-]?key|access[_-]?token|secret)\b\s*[:=]\s*[\"']?[A-Za-z0-9_./+\-=]{20,}")),
 ("bearer-token",re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}")),
 ("aws-access-key",re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
]
hits=[]
for p in root.rglob("*"):
    if not p.is_file() or p.name == "scan_secrets.py" or any(part in skip for part in p.relative_to(root).parts):continue
    if p.suffix.lower() in {".zip",".png",".jpg",".jpeg",".pdf",".sqlite",".sqlite3",".trace",".memgraph"}:continue
    try:text=p.read_text(encoding="utf-8")
    except Exception:continue
    for n,line in enumerate(text.splitlines(),1):
        for name,pat in patterns:
            if pat.search(line) and "example" not in line.lower() and "pattern" not in line.lower():
                hits.append((p.relative_to(root),n,name,line.strip()[:300]))
if hits:
    for hit in hits:print(f"{hit[0]}:{hit[1]} [{hit[2]}] {hit[3]}",file=sys.stderr)
    raise SystemExit(1)
print(f"Secret scan passed for {root}")
