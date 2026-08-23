#!/usr/bin/env python3
from __future__ import annotations

import argparse,hashlib,json,os,sys
from pathlib import Path

def sha(p:Path):
    h=hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""):h.update(b)
    return h.hexdigest()
def locate_repo(explicit):
    if explicit:return Path(explicit).resolve()
    p=Path.cwd().resolve()
    for c in (p,*p.parents):
        if (c/".forge-codex").is_dir():return c
    raise SystemExit("repository not found")

parser=argparse.ArgumentParser()
parser.add_argument("gate")
parser.add_argument("--repo")
parser.add_argument("--acceptance")
parser.add_argument("--criteria-output")
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
plan=json.loads((pkg/"plans/gates.json").read_text())
gate=next((g for g in plan["gates"] if g["id"]==args.gate),None)
if not gate:raise SystemExit("unknown gate")
acceptance=Path(args.acceptance).resolve() if args.acceptance else pkg/"state/acceptance"/f"{args.gate}.json"
if not acceptance.is_file():
    print(f"acceptance record missing: {acceptance}",file=sys.stderr);raise SystemExit(1)
record=json.loads(acceptance.read_text())
errors=[]
criteria_by_text={c.get("criterion"):c for c in record.get("criteria_results",[])}
normalized=[]
for criterion in gate["criteria"]:
    item=criteria_by_text.get(criterion)
    if item is None:
        errors.append(f"missing criterion: {criterion}")
        normalized.append({"criterion":criterion,"passed":False,"evidence":"missing"})
        continue
    evidence=item.get("evidence",[])
    if not isinstance(evidence,list) or not evidence:
        errors.append(f"criterion has no evidence artifacts: {criterion}")
    artifact_notes=[]
    for artifact in evidence if isinstance(evidence,list) else []:
        if not isinstance(artifact,dict) or "path" not in artifact or "sha256" not in artifact:
            errors.append(f"malformed evidence for: {criterion}");continue
        p=Path(artifact["path"])
        if not p.is_absolute():p=(repo/p).resolve()
        if not p.is_file():
            errors.append(f"missing artifact: {p}");continue
        actual=sha(p)
        if actual!=artifact["sha256"]:
            errors.append(f"hash mismatch: {p}")
        artifact_notes.append(f"{p}#{actual}")
    passed=bool(item.get("passed")) and bool(evidence) and not any(criterion in e for e in errors)
    normalized.append({"criterion":criterion,"passed":passed,"evidence":"; ".join(artifact_notes) or "invalid"})
    if not item.get("passed"):errors.append(f"criterion marked failed: {criterion}")
commands=record.get("commands",[])
if not commands:errors.append("acceptance record has no commands")
for command in commands:
    if not isinstance(command,dict) or not {"command","exit_code","evidence"}.issubset(command):
        errors.append("malformed command record");continue
    ep=Path(command["evidence"])
    if not ep.is_absolute():ep=(repo/ep).resolve()
    if not ep.is_file():errors.append(f"command evidence missing: {ep}")
    if command["exit_code"]!=0:errors.append(f"command failed: {command['command']}")
payload={"criteria_results":normalized,"valid":not errors,"errors":errors}
out=Path(args.criteria_output).resolve() if args.criteria_output else pkg/"state/gate-results"/f"{args.gate}.criteria.json"
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n")
print(json.dumps(payload,indent=2))
raise SystemExit(0 if not errors and all(c["passed"] for c in normalized) else 1)
