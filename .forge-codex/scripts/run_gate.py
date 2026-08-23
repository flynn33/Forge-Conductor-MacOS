#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shlex
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

def now(): return datetime.now(timezone.utc).isoformat()
def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""): h.update(b)
    return h.hexdigest()

def locate_repo(explicit):
    if explicit: return Path(explicit).resolve()
    p=Path.cwd().resolve()
    for c in (p,*p.parents):
        if (c/".forge-codex").is_dir(): return c
    raise SystemExit("repository not found")

parser=argparse.ArgumentParser()
parser.add_argument("gate")
parser.add_argument("--repo")
parser.add_argument("--timeout",type=int,default=7200)
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
gate_plan=json.loads((pkg/"plans/gates.json").read_text())
gate=next((g for g in gate_plan["gates"] if g["id"]==args.gate),None)
if gate is None: raise SystemExit(f"Unknown gate: {args.gate}")
handler=pkg/"state/gate-handlers"/f"{args.gate}.sh"
result_dir=pkg/"state/gate-results"
result_dir.mkdir(parents=True,exist_ok=True)
started=now()

if not handler.exists():
    status="failed"
    commands=[{"command":str(handler),"exit_code":127,"stdout_sha256":None,"stderr_sha256":None,"timed_out":False}]
    artifacts=[]
    evaluator={"name":"handler-presence","version":"1","criteria_results":[{"criterion":"gate handler exists","passed":False,"evidence":str(handler)}]}
    notes="No gate handler exists. Codex must implement a deterministic handler that evaluates every criterion."
else:
    handler.chmod(handler.stat().st_mode|0o111)
    stdout=result_dir/f"{args.gate}.stdout.txt"
    stderr=result_dir/f"{args.gate}.stderr.txt"
    timed=False
    try:
        with stdout.open("wb") as out, stderr.open("wb") as err:
            p=subprocess.run([str(handler)],cwd=repo,stdout=out,stderr=err,timeout=args.timeout)
            code=p.returncode
    except subprocess.TimeoutExpired:
        code=124; timed=True
    commands=[{"command":str(handler),"exit_code":code,"stdout_sha256":sha(stdout),"stderr_sha256":sha(stderr),"timed_out":timed}]
    artifacts=[
        {"path":str(stdout),"sha256":sha(stdout),"kind":"stdout"},
        {"path":str(stderr),"sha256":sha(stderr),"kind":"stderr"},
    ]
    # Handler may emit a criteria JSON sidecar.
    criteria_path=result_dir/f"{args.gate}.criteria.json"
    criteria=[]
    if criteria_path.exists():
        try: criteria=json.loads(criteria_path.read_text())["criteria_results"]
        except Exception as exc:
            criteria=[{"criterion":"criteria sidecar parses","passed":False,"evidence":repr(exc)}]
        artifacts.append({"path":str(criteria_path),"sha256":sha(criteria_path),"kind":"criteria"})
    else:
        criteria=[{"criterion":c,"passed":code==0,"evidence":"handler exit status; replace with criterion-specific evidence"} for c in gate["criteria"]]
    status="passed" if code==0 and all(bool(c.get("passed")) for c in criteria) else "failed"
    evaluator={"name":"forge-gate-handler","version":"1","criteria_results":criteria}
    notes=""

result={
    "schema_version":1,"gate_id":args.gate,"status":status,
    "started_at":started,"ended_at":now(),"commands":commands,
    "environment":{"platform":platform.platform(),"machine":platform.machine(),"repository":str(repo)},
    "artifacts":artifacts,"evaluator":evaluator,"notes":notes
}
path=result_dir/f"{args.gate}.json"
tmp=path.with_suffix(".tmp")
tmp.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
os.replace(tmp,path)
evidence_ids=[a["sha256"] for a in artifacts]
subprocess.run([str(pkg/"scripts/statectl.py"),"--repo",str(repo),"gate",args.gate,status,
                *sum((["--evidence",eid] for eid in evidence_ids),[]),
                "--evaluator",str(path)],check=False)
print(json.dumps(result,indent=2))
raise SystemExit(0 if status=="passed" else 1)
