#!/usr/bin/env python3
from __future__ import annotations
import argparse,re,sys
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument("--root",default=".")
args=parser.parse_args()
root=Path(args.root).resolve()
skip={".git",".build","DerivedData","build","dist"}
generated_or_immutable={"audit","backups","evidence","state"}
policy_examples={".github/agents/attribution-guard.agent.md"}
binary_suffixes={".zip",".png",".jpg",".jpeg",".gif",".pdf",".trace",".memgraph",".sqlite",".sqlite3",".xcassets",".car"}
patterns=[
    re.compile(r"generated\s+by\s+(?:chatgpt|codex|an?\s+ai|artificial intelligence|openai)",re.I),
    re.compile(r"(?:written|authored|created)\s+by\s+(?:chatgpt|codex|an?\s+ai|artificial intelligence|openai)",re.I),
    re.compile(r"co-authored-by:.*(?:chatgpt|codex|openai|artificial intelligence)",re.I),
    re.compile(r"\bai-generated\b",re.I),
    re.compile(r"\bmachine-generated\s+(?:code|content|documentation)\b",re.I),
]
hits=[]
for p in root.rglob("*"):
    relative=p.relative_to(root)
    control_parts=relative.parts[1:] if relative.parts and relative.parts[0] == ".forge-codex" else relative.parts
    exempt_control=bool(control_parts and control_parts[0] in generated_or_immutable)
    exempt_policy=relative.as_posix() in policy_examples
    if not p.is_file() or p.name == "scan_attribution.py" or p.name == "PACKAGE_VALIDATION.json" or exempt_control or exempt_policy or any(part in skip for part in relative.parts): continue
    if p.suffix.lower() in binary_suffixes: continue
    try:
        text=p.read_text(encoding="utf-8",errors="strict")
    except Exception:
        continue
    for n,line in enumerate(text.splitlines(),1):
        for pattern in patterns:
            if pattern.search(line):
                hits.append({"path":str(relative),"line":n,"text":line.strip()[:500],"pattern":pattern.pattern})
if hits:
    for hit in hits: print(f"{hit['path']}:{hit['line']}: {hit['text']}",file=sys.stderr)
    raise SystemExit(1)
print(f"Authorship-attribution scan passed for {root}")
