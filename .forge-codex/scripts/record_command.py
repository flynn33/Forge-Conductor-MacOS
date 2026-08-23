#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

def now(): return datetime.now(timezone.utc).isoformat()
def digest(path: Path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""):h.update(b)
    return h.hexdigest()

parser=argparse.ArgumentParser()
parser.add_argument("--repo",default=".")
parser.add_argument("--kind",required=True)
parser.add_argument("--related-gate",action="append",default=[])
parser.add_argument("--related-finding",action="append",default=[])
parser.add_argument("--timeout",type=int,default=1800)
parser.add_argument("--artifact",action="append",default=[])
parser.add_argument("command",nargs=argparse.REMAINDER)
args=parser.parse_args()
if not args.command:
    raise SystemExit("A command is required after --")
if args.command and args.command[0]=="--": args.command=args.command[1:]
repo=Path(args.repo).resolve()
evidence_dir=repo/".forge-codex/evidence"
evidence_dir.mkdir(parents=True,exist_ok=True)
eid=f"EVID-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:10]}"
stdout_path=evidence_dir/f"{eid}.stdout.txt"
stderr_path=evidence_dir/f"{eid}.stderr.txt"
started=now()
timed_out=False
try:
    with stdout_path.open("wb") as out, stderr_path.open("wb") as err:
        p=subprocess.run(args.command,cwd=repo,stdout=out,stderr=err,timeout=args.timeout)
        exit_code=p.returncode
except subprocess.TimeoutExpired:
    timed_out=True
    exit_code=124
ended=now()
artifacts=[]
for raw in args.artifact:
    p=(repo/raw).resolve() if not Path(raw).is_absolute() else Path(raw)
    if p.exists() and p.is_file():
        artifacts.append({"path":str(p),"sha256":digest(p),"bytes":p.stat().st_size})
for p in (stdout_path,stderr_path):
    artifacts.append({"path":str(p),"sha256":digest(p),"bytes":p.stat().st_size})
record={
    "schema_version":1,"id":eid,"kind":args.kind,
    "command":shlex.join(args.command),"exit_code":exit_code,"timed_out":timed_out,
    "started_at":started,"ended_at":ended,
    "environment":{"platform":platform.platform(),"machine":platform.machine(),"cwd":str(repo)},
    "artifacts":artifacts,"related_findings":args.related_finding,"related_gates":args.related_gate
}
record_path=evidence_dir/f"{eid}.json"
record_path.write_text(json.dumps(record,indent=2,sort_keys=True)+"\n")
print(json.dumps(record,indent=2))
try:
    subprocess.run([str(repo/".forge-codex/scripts/statectl.py"),"--repo",str(repo),"reference","evidence",eid],check=False)
except Exception: pass
raise SystemExit(exit_code)
