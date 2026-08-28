#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
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
def sha(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(1024*1024),b""):h.update(b)
    return h.hexdigest()

parser=argparse.ArgumentParser()
parser.add_argument("--repo")
parser.add_argument("--no-finalize",action="store_true")
args=parser.parse_args()
repo=locate_repo(args.repo)
pkg=repo/".forge-codex"
state_path=pkg/"state/run-state.json"
state=json.loads(state_path.read_text())
gate_plan=json.loads((pkg/"plans/gates.json").read_text())
errors=[]
checks=[]

def check(name: str, passed: bool, detail: Any):
    checks.append({"name":name,"passed":bool(passed),"detail":detail})
    if not passed:errors.append(f"{name}: {detail}")

check("run-state-valid",subprocess.run([str(pkg/"scripts/statectl.py"),"--repo",str(repo),"validate"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT).returncode==0,"state/event chain")
check("package-valid",subprocess.run([sys.executable,str(pkg/"scripts/validate_package.py"),"--root",str(pkg)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT).returncode==0,"package validation")
check("attribution-clean",subprocess.run([sys.executable,str(pkg/"scripts/scan_attribution.py"),"--root",str(repo)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT).returncode==0,"repository scan")
check("secret-scan-clean",subprocess.run([sys.executable,str(pkg/"scripts/scan_secrets.py"),"--root",str(repo)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT).returncode==0,"repository scan")

result_dir=pkg/"state/gate-results"
required=[g for g in gate_plan["completion_requires"] if g!="G12"]
for gid in required:
    path=result_dir/f"{gid}.json"
    check(f"gate-result-exists:{gid}",path.is_file(),str(path))
    if not path.is_file():continue
    try:
        result=json.loads(path.read_text())
    except Exception as exc:
        check(f"gate-result-valid:{gid}",False,repr(exc));continue
    current_authority=True
    authority_detail="current or unspecified"
    acceptance_path=pkg/"state/acceptance"/f"{gid}.json"
    if acceptance_path.is_file():
        try:
            acceptance=json.loads(acceptance_path.read_text())
            current_authority=acceptance.get("current_release_authority") is not False
            authority_detail=acceptance.get("authority_note",acceptance.get("authority_scope","current or unspecified"))
        except Exception as exc:
            current_authority=False
            authority_detail=repr(exc)
    result_status=result.get("status")
    result_detail=result_status if current_authority else f"{result_status}; {authority_detail}"
    check(f"gate-passed:{gid}",result_status=="passed" and current_authority,result_detail)
    check(f"gate-ledger-passed:{gid}",state["gates"].get(gid,{}).get("status")=="passed",state["gates"].get(gid,{}).get("status"))
    check(f"gate-current-release-authority:{gid}",current_authority,authority_detail)
    for artifact in result.get("artifacts",[]):
        p=Path(artifact["path"])
        check(f"gate-artifact-exists:{gid}:{p.name}",p.is_file(),str(p))
        if p.is_file():
            check(f"gate-artifact-hash:{gid}:{p.name}",sha(p)==artifact.get("sha256"),artifact.get("sha256"))

baseline_path=pkg/"state/feature-baseline.json"
check("feature-baseline-exists",baseline_path.is_file(),str(baseline_path))
if baseline_path.is_file():
    baseline=json.loads(baseline_path.read_text())
    summary=baseline.get("parity_summary",{})
    check("feature-runtime-inventory-complete",baseline.get("runtime_completion_required") is False,baseline.get("runtime_completion_required"))
    check("feature-unknown-zero",int(summary.get("unknown",1))==0,summary)
    check("feature-untested-zero",int(summary.get("untested",1))==0,summary)
    check("feature-removed-zero",int(summary.get("removed",1))==0,summary)
    feature_states=[f.get("parity_status") for f in baseline.get("features",[])]
    check("all-feature-statuses-valid",all(s in {"preserved","additive","migrated"} for s in feature_states),sorted(set(feature_states)))

findings_path=pkg/"state/findings-resolution.json"
check("findings-resolution-exists",findings_path.is_file(),str(findings_path))
if findings_path.is_file():
    findings=json.loads(findings_path.read_text()).get("findings",[])
    unresolved=[f for f in findings if f.get("severity") in {"Critical","High"} and f.get("status")!="resolved"]
    check("critical-high-findings-resolved",not unresolved,[f.get("id") for f in unresolved])

host_path=pkg/"state/host-capability-report.json"
check("host-capability-report-exists",host_path.is_file(),str(host_path))
if host_path.is_file():
    host=json.loads(host_path.read_text())
    check("autonomous-rollover-mode-proven",bool(host.get("autonomous_rollover_proven")),host.get("selected_adapter"))
    check("supported-api-only",not bool(host.get("uses_private_ui_automation")),host.get("uses_private_ui_automation"))

completion={
    "schema_version":1,
    "evaluated_at":now(),
    "repository":str(repo),
    "passed":not errors,
    "checks":checks,
    "errors":errors,
    "run_id":state.get("run_id"),
    "commit":state.get("repository",{}).get("commit"),
}
report_json=pkg/"state/completion-report.json"
tmp=report_json.with_suffix(".tmp")
tmp.write_text(json.dumps(completion,indent=2,sort_keys=True)+"\n")
os.replace(tmp,report_json)

report_md=pkg/"state/completion-report.md"
lines=["# Forge Conductor completion verification","",f"- Evaluated: `{completion['evaluated_at']}`",f"- Passed: **{completion['passed']}**","",
       "## Checks",""]
for c in checks:
    lines.append(f"- [{'x' if c['passed'] else ' '}] `{c['name']}` — {c['detail']}")
if errors:
    lines+=["","## Blocking errors",""]+[f"- {e}" for e in errors]
report_md.write_text("\n".join(lines)+"\n")

if not errors and not args.no_finalize:
    # The completion validator is the evaluator for G12.
    gate_result={
        "schema_version":1,"gate_id":"G12","status":"passed","started_at":completion["evaluated_at"],"ended_at":now(),
        "commands":[{"command":"verify_completion.py","exit_code":0,"stdout_sha256":None,"stderr_sha256":None,"timed_out":False}],
        "environment":{"repository":str(repo)},
        "artifacts":[{"path":str(report_json),"sha256":sha(report_json),"kind":"completion-report"},{"path":str(report_md),"sha256":sha(report_md),"kind":"completion-report"}],
        "evaluator":{"name":"verify_completion.py","version":"1","criteria_results":[{"criterion":c["name"],"passed":c["passed"],"evidence":str(c["detail"])} for c in checks]},
        "notes":"All prerequisite gates and final integrity checks passed."
    }
    gate_path=result_dir/"G12.json"; gate_path.parent.mkdir(parents=True,exist_ok=True)
    gate_path.write_text(json.dumps(gate_result,indent=2,sort_keys=True)+"\n")
    subprocess.run([str(pkg/"scripts/statectl.py"),"--repo",str(repo),"gate","G12","passed","--evidence",sha(report_json),"--evaluator",str(gate_path)],check=False)
    subprocess.run([str(pkg/"scripts/statectl.py"),"--repo",str(repo),"status","complete"],check=False)

print(json.dumps({"passed":not errors,"errors":errors,"report":str(report_json)},indent=2))
raise SystemExit(0 if not errors else 1)
