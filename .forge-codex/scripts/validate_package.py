#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import py_compile
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REQUIRED = [
    "VERSION",
    "CODEX_EXECUTION_PROMPT.md",
    "docs/EXECUTION_CONTRACT.md",
    "docs/EVIDENCE_RULES.md",
    "docs/DECISION_POLICY.md",
    "docs/FAIL_FORWARD_POLICY.md",
    "docs/FEATURE_PRESERVATION.md",
    "docs/PHASE_PLAYBOOK.md",
    "architecture/TARGET_ARCHITECTURE.md",
    "architecture/TELEMETRY_BACKPRESSURE.md",
    "architecture/GAUGE_RENDERING.md",
    "architecture/PROJECT_MEMORY_MCP.md",
    "architecture/CONTINUITY_AND_ROLLOVER.md",
    "architecture/HOST_ADAPTER_PLUGIN.md",
    "specifications/MCP_TOOL_CONTRACTS.md",
    "specifications/CONTINUITY_STATE_MACHINE.md",
    "specifications/COMPLETION_GATES.md",
    "plans/phases.json",
    "plans/gates.json",
    "plans/resource-budgets.json",
    "schemas/run-state.schema.json",
    "schemas/handoff.schema.json",
    "schemas/memory-record.schema.json",
    "scripts/statectl.py",
    "scripts/feature_inventory.py",
    "scripts/verify_completion.py",
    "scripts/scan_attribution.py",
]

parser=argparse.ArgumentParser()
parser.add_argument("--root",default=".")
parser.add_argument("--report")
args=parser.parse_args()
root=Path(args.root).resolve()
errors=[]
warnings=[]
checks=[]

def check(name, passed, detail):
    checks.append({"name":name,"passed":bool(passed),"detail":str(detail)})
    if not passed: errors.append(f"{name}: {detail}")

for rel in REQUIRED:
    check(f"required:{rel}",(root/rel).is_file(),rel)

json_objects={}
for p in sorted(root.rglob("*.json")):
    if any(part in {".git",".build","DerivedData","work"} for part in p.relative_to(root).parts): continue
    try:
        json_objects[str(p.relative_to(root))]=json.loads(p.read_text(encoding="utf-8"))
        check(f"json:{p.relative_to(root)}",True,"valid")
    except Exception as exc:
        check(f"json:{p.relative_to(root)}",False,repr(exc))

phase_plan=json_objects.get("plans/phases.json",{})
gate_plan=json_objects.get("plans/gates.json",{})
phase_ids=[p.get("id") for p in phase_plan.get("phases",[])]
gate_ids=[g.get("id") for g in gate_plan.get("gates",[])]
check("phase-ids-unique",len(phase_ids)==len(set(phase_ids)),phase_ids)
check("gate-ids-unique",len(gate_ids)==len(set(gate_ids)),gate_ids)
for phase in phase_plan.get("phases",[]):
    for dep in phase.get("dependencies",[]):
        check(f"phase-dependency:{phase.get('id')}->{dep}",dep in phase_ids,dep)
    for gate in phase.get("hard_gates",[]):
        check(f"phase-gate:{phase.get('id')}->{gate}",gate in gate_ids,gate)
for gate in gate_plan.get("completion_requires",[]):
    check(f"completion-gate:{gate}",gate in gate_ids,gate)

# Detect cycles.
deps={p["id"]:set(p.get("dependencies",[])) for p in phase_plan.get("phases",[]) if "id" in p}
remaining=set(deps)
resolved=set()
while remaining:
    ready={p for p in remaining if deps[p] <= resolved}
    if not ready: break
    resolved |= ready; remaining -= ready
check("phase-dag-acyclic",not remaining,sorted(remaining))

for p in sorted(root.rglob("*.py")):
    if any(part in {"work"} for part in p.relative_to(root).parts): continue
    try:
        py_compile.compile(str(p),doraise=True)
        check(f"python:{p.relative_to(root)}",True,"compiled")
    except Exception as exc:
        check(f"python:{p.relative_to(root)}",False,repr(exc))

bash=shutil.which("bash")
for p in sorted(root.rglob("*.sh")):
    if any(part in {"work"} for part in p.relative_to(root).parts): continue
    if bash:
        proc=subprocess.run([bash,"-n",str(p)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        check(f"shell:{p.relative_to(root)}",proc.returncode==0,proc.stdout.strip() or "syntax valid")
    else:
        warnings.append("bash unavailable; shell syntax not checked")
        break

for p in root.rglob("*"):
    if p.is_symlink():
        try:
            target=p.resolve(strict=False)
            check(f"symlink:{p.relative_to(root)}",target==root or root in target.parents,target)
        except Exception as exc:
            check(f"symlink:{p.relative_to(root)}",False,repr(exc))

scanner=root/"scripts/scan_attribution.py"
if scanner.exists():
    proc=subprocess.run([sys.executable,str(scanner),"--root",str(root)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    check("authorship-attribution-scan",proc.returncode==0,proc.stdout.strip())

secret_scanner=root/"scripts/scan_secrets.py"
if secret_scanner.exists():
    proc=subprocess.run([sys.executable,str(secret_scanner),"--root",str(root)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    check("secret-scan",proc.returncode==0,proc.stdout.strip())

is_distribution=(root/"START_HERE.md").exists()
if is_distribution:
    check("included-source-archive",(root/"inputs/Forge-Conductor-MacOS-main.zip").is_file(),"source archive")
    check("included-audit",(root/"audit/Forge-Conductor-Consolidated-Audit.md").is_file(),"audit report")

report={
    "schema_version":1,
    "validated_at":datetime.now(timezone.utc).isoformat(),
    "root":str(root),
    "valid":not errors,
    "checks":checks,
    "errors":errors,
    "warnings":warnings,
}
report_path=Path(args.report).resolve() if args.report else root/"PACKAGE_VALIDATION.json"
report_path.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
print(json.dumps({"valid":report["valid"],"checks":len(checks),"errors":errors,"report":str(report_path)},indent=2))
raise SystemExit(0 if report["valid"] else 1)
