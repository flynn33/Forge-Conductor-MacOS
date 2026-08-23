#!/usr/bin/env python3
from __future__ import annotations
import argparse,json,re,hashlib
from pathlib import Path
from datetime import datetime,timezone

parser=argparse.ArgumentParser()
parser.add_argument("--repo",default=".")
parser.add_argument("--output")
args=parser.parse_args()
root=Path(args.repo).resolve()
out=Path(args.output).resolve() if args.output else root/".forge-codex/state/source-risk-scan.json"
skip={".git",".build","DerivedData","build","dist",".forge-codex"}

rules=[
 ("TASK-MAINACTOR-PER-EVENT","E1","High",re.compile(r'Task\s*\{\s*@MainActor'),"Unstructured MainActor task; inspect whether invoked per event and bounded."),
 ("TASK-DETACHED","E2","High",re.compile(r'Task\.detached'),"Detached task requires immutable/sendable payload and explicit result ownership."),
 ("TASK-STORED","E2","High",re.compile(r'(?:var|let)\s+\w*(?:task|Task)\w*\s*:\s*Task\b',re.I),"Stored task requires owner cancellation/await boundary."),
 ("TIMER-SCHEDULED","E2","High",re.compile(r'Timer\.scheduledTimer|Timer\.publish'),"Repeating timer requires explicit owner and invalidation/cancellation."),
 ("NOTIFICATION-BLOCK","E2","High",re.compile(r'addObserver\s*\(\s*forName:'),"Block observer token requires ownership and removal."),
 ("READABILITY-HANDLER","E2","High",re.compile(r'readabilityHandler\s*='),"FileHandle handler requires clear, close, and reader shutdown."),
 ("PROCESS-WAIT","E1","Critical",re.compile(r'\.waitUntilExit\s*\('),"Blocking process wait must not execute on MainActor."),
 ("METAL-QUEUE","E3","High",re.compile(r'makeCommandQueue\s*\('),"Inspect creation scope; gauge instances must not multiply queues."),
 ("METAL-PIPELINE","E3","High",re.compile(r'makeRenderPipelineState|makeComputePipelineState'),"Inspect creation scope and warm-up."),
 ("METAL-BUFFER","E3","High",re.compile(r'makeBuffer\s*\('),"Inspect whether allocation occurs in draw/update path."),
 ("UNBOUNDED-APPEND","E2","Medium",re.compile(r'\.\s*append\s*\('),"Long-lived collection append requires a proven bound/eviction policy."),
 ("COMBINE-SINK","E2","High",re.compile(r'\.\s*sink\s*\{'),"Subscription requires owner cancellation and capture review."),
 ("STRONG-DELEGATE","E2","High",re.compile(r'\bvar\s+\w*delegate\w*\s*:',re.I),"Delegate ownership requires classification."),
]
findings=[]
for p in root.rglob("*.swift"):
    if any(part in skip for part in p.relative_to(root).parts): continue
    text=p.read_text(encoding="utf-8",errors="replace")
    for line_no,line in enumerate(text.splitlines(),1):
        for rule_id,evidence,severity,pat,detail in rules:
            if pat.search(line):
                key=f"{rule_id}|{p.relative_to(root)}|{line_no}|{line.strip()}"
                findings.append({
                    "id":"SCAN-"+hashlib.sha256(key.encode()).hexdigest()[:12].upper(),
                    "rule":rule_id,"evidence_class":evidence,"severity":severity,
                    "path":str(p.relative_to(root)),"line":line_no,
                    "excerpt":line.strip()[:600],"required_determination":detail,
                    "status":"candidate"
                })
payload={"schema_version":1,"generated_at":datetime.now(timezone.utc).isoformat(),"repository_root":str(root),"findings":findings,
         "disclaimer":"E2/E3 records are candidates, not confirmed live defects. Trace effective ownership and runtime reachability."}
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n")
print(json.dumps({"output":str(out),"candidates":len(findings)},indent=2))
