#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path
from datetime import datetime, timezone

def locate_repo(explicit):
    if explicit: return Path(explicit).resolve()
    p=Path.cwd().resolve()
    for c in (p,*p.parents):
        if (c/".forge-codex").is_dir(): return c
    raise SystemExit("repository not found")

parser=argparse.ArgumentParser()
parser.add_argument("--repo")
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
state=json.loads((pkg/"state/run-state.json").read_text())
plan=json.loads((pkg/"plans/phases.json").read_text())
by_id={p["id"]:p for p in plan["phases"]}
passed={pid for pid,s in state["phases"].items() if s["status"]=="passed"}
running=[pid for pid,s in state["phases"].items() if s["status"]=="running"]
if running:
    chosen=sorted(running, key=lambda p:-by_id[p]["priority"])[0]
    reason="resume_running"
else:
    ready=[]
    for phase in plan["phases"]:
        status=state["phases"][phase["id"]]["status"]
        if status=="passed": continue
        if all(dep in passed for dep in phase["dependencies"]):
            ready.append(phase)
    if not ready:
        chosen=None
        reason="no_ready_phase"
    else:
        ready.sort(key=lambda p:(-p["priority"],p["id"]))
        chosen=ready[0]["id"]
        reason="highest_priority_ready"
print(json.dumps({
    "selected_phase":chosen,
    "reason":reason,
    "phase":by_id.get(chosen),
    "open_issues":[i for i in state["issues"] if i.get("status")!="resolved"],
    "timestamp":datetime.now(timezone.utc).isoformat()
},indent=2))
