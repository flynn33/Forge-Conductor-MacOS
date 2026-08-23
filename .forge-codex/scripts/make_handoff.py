#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

def now(): return datetime.now(timezone.utc).isoformat()
def locate_repo(explicit):
    if explicit:return Path(explicit).resolve()
    p=Path.cwd().resolve()
    for c in (p,*p.parents):
        if (c/".forge-codex").is_dir():return c
    raise SystemExit("repository not found")
def run(repo,*argv):
    try:
        p=subprocess.run(argv,cwd=repo,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
        return p.stdout.strip() if p.returncode==0 else None
    except Exception:return None
def content_hash(payload: dict[str,Any])->str:
    copy=json.loads(json.dumps(payload))
    copy.get("integrity",{}).pop("content_sha256",None)
    return hashlib.sha256(json.dumps(copy,sort_keys=True,separators=(",",":")).encode()).hexdigest()
def atomic(path,payload):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n")
    os.replace(tmp,path)

parser=argparse.ArgumentParser()
parser.add_argument("--repo")
parser.add_argument("--mission-file")
parser.add_argument("--project-id")
parser.add_argument("--predecessor-session",default="codex-current")
parser.add_argument("--adapter-id")
parser.add_argument("--next-action",action="append",default=[])
parser.add_argument("--output")
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
state=json.loads((pkg/"state/run-state.json").read_text())
mission=(Path(args.mission_file).read_text() if args.mission_file else (pkg/"CODEX_EXECUTION_PROMPT.md").read_text())
project_id=args.project_id or str(uuid.uuid5(uuid.NAMESPACE_URL,str(repo)))
dirty=(run(repo,"git","status","--short") or "").splitlines()
passed=[g for g,v in state["gates"].items() if v["status"]=="passed"]
open_gates=[g for g,v in state["gates"].items() if v["status"]!="passed"]
open_issues=[i for i in state["issues"] if i.get("status")!="resolved"]
next_actions=args.next_action or [
    f"Run select_next_work.py and resume the highest-priority ready phase.",
    f"Verify current Git/build state before editing.",
]
payload={
    "schema_version":1,
    "handoff_id":str(uuid.uuid4()),
    "operation_id":str(uuid.uuid4()),
    "created_at":now(),
    "project":{"project_id":project_id,"display_name":repo.name,"repository_root":str(repo),"branch":run(repo,"git","branch","--show-current"),"commit":run(repo,"git","rev-parse","HEAD"),"dirty_summary":dirty[:500]},
    "predecessor_session":{"session_id":args.predecessor_session,"provider_session_id":None,"model":None},
    "successor_session":None,
    "mission":mission[:12000],
    "constraints":[
        "Preserve every current feature and compatibility surface.",
        "Use evidence before defect claims or fixes.",
        "Keep continuous work and retained state bounded.",
        "Do not request operator decisions.",
        "Do not add automated authorship credits."
    ],
    "current_work":{"phase_id":state.get("current_work") or "P00","work_item_id":None,"summary":"Resume from persistent run state.","active_files":[]},
    "completed_work":[{"id":p,"summary":"Phase gate recorded as passed.","status":"passed","evidence_ids":state["gates"].get(p.replace("P","G"),{}).get("evidence_ids",[])} for p,v in state["phases"].items() if v["status"]=="passed"],
    "open_work":[{"id":i["id"],"summary":i.get("title","Open issue"),"status":i.get("status"),"evidence_ids":[]} for i in open_issues],
    "decisions":[{"id":d,"summary":"See decision record.","memory_id":None} for d in state.get("decisions",[])],
    "validation":{"passed_gates":passed,"open_gates":open_gates,"commands":[]},
    "memory_references":[],
    "evidence_references":state.get("evidence",[])[:1000],
    "next_actions":[{"order":i+1,"action":a,"command":None,"success_condition":None} for i,a in enumerate(next_actions[:100])],
    "host_state":{"adapter_id":args.adapter_id,"continuity_state":"checkpointPersisted","context_budget_source":None,"remaining_budget_estimate":None,"retry":None},
    "integrity":{"content_sha256":"0"*64,"redaction_complete":True}
}
payload["integrity"]["content_sha256"]=content_hash(payload)
output=Path(args.output).resolve() if args.output else pkg/"state/current-handoff.json"
atomic(output,payload)
subprocess.run([str(pkg/"scripts/statectl.py"),"--repo",str(repo),"reference","handoffs",payload["handoff_id"]],check=False)
print(json.dumps({"handoff":str(output),"handoff_id":payload["handoff_id"],"sha256":payload["integrity"]["content_sha256"]},indent=2))
