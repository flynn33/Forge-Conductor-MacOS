#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

SKIP_DIRS={".git",".build","DerivedData","build","dist",".forge-codex","node_modules","Pods"}

def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""): h.update(block)
    return h.hexdigest()

def files(root: Path, suffix: str|None=None) -> Iterable[Path]:
    for p in root.rglob("*"):
        if not p.is_file(): continue
        if any(part in SKIP_DIRS for part in p.relative_to(root).parts): continue
        if suffix and p.suffix != suffix: continue
        yield p

def item_id(prefix: str, key: str) -> str:
    digest=hashlib.sha256(key.encode()).hexdigest()[:10].upper()
    return f"{prefix}-{digest}"

def add(items, seen, category, key, path, line, detail, prefix):
    identity=f"{category}|{key}"
    if identity in seen: return
    seen.add(identity)
    items.append({
        "id":item_id(prefix,identity),
        "category":category,
        "key":key,
        "source":{"path":path,"line":line},
        "detail":detail,
        "baseline_status":"discovered_static",
        "parity_status":"unknown",
        "tests":[],
    })

def command(root: Path, argv: list[str]) -> dict:
    try:
        p=subprocess.run(argv,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        return {"command":" ".join(argv),"exit_code":p.returncode,"output":p.stdout[-50000:]}
    except Exception as exc:
        return {"command":" ".join(argv),"exit_code":-1,"output":repr(exc)}

parser=argparse.ArgumentParser()
parser.add_argument("--repo",default=".")
parser.add_argument("--output")
args=parser.parse_args()
root=Path(args.repo).resolve()
out=Path(args.output).resolve() if args.output else root/".forge-codex/state/feature-baseline.json"
out.parent.mkdir(parents=True,exist_ok=True)

items=[]
seen=set()
swift_files=list(files(root,".swift"))

patterns=[
    ("scene",re.compile(r'\b(WindowGroup|Window|Settings|MenuBarExtra|DocumentGroup)\s*(?:\(|\{)'),"UI"),
    ("command",re.compile(r'\bCommandMenu\s*\(\s*"([^"]+)"|\.commands\s*\{'),"CMD"),
    ("keyboard_shortcut",re.compile(r'\.keyboardShortcut\s*\(([^)\n]+)'),"CMD"),
    ("setting_key",re.compile(r'@AppStorage\s*\(\s*"([^"]+)"|UserDefaults(?:\.standard)?\.(?:object|bool|integer|double|string|data|set)\s*\(\s*(?:[^,]+,\s*forKey:\s*)?"([^"]+)"'),"DATA"),
    ("notification",re.compile(r'Notification\.Name\s*\(\s*"([^"]+)"|extension\s+Notification\.Name'),"EVENT"),
    ("url_scheme",re.compile(r'\bonOpenURL\b|CFBundleURLSchemes'),"UI"),
    ("telemetry",re.compile(r'\b(?:Telemetry|Metric|Gauge)[A-Za-z0-9_]*\b'),"TEL"),
    ("process",re.compile(r'\bProcess\s*\(|\bPipe\s*\(|readabilityHandler'),"PROC"),
    ("memory",re.compile(r'\b(?:Memory|ProjectMemory|Continuity|Handoff)[A-Za-z0-9_]*\b'),"MEM"),
    ("mcp",re.compile(r'\b(?:MCP|Mcp|ModelContextProtocol)[A-Za-z0-9_]*\b'),"MCP"),
]

tool_patterns=[
    re.compile(r'(?:name|toolName)\s*:\s*"([a-zA-Z0-9_.-]+)"'),
    re.compile(r'case\s+"([a-zA-Z0-9_.-]+)"\s*:'),
    re.compile(r'\b(?:Tool|MCPTool)\s*\(\s*"([a-zA-Z0-9_.-]+)"'),
]

for path in swift_files:
    rel=str(path.relative_to(root))
    try: text=path.read_text(encoding="utf-8",errors="replace")
    except Exception: continue
    lines=text.splitlines()
    for index,line in enumerate(lines,1):
        for category,pattern,prefix in patterns:
            for match in pattern.finditer(line):
                values=[v for v in match.groups() if v] if match.groups() else []
                key=values[0] if values else match.group(0).strip()
                add(items,seen,category,key,rel,index,line.strip()[:500],prefix)
        if any(token in text for token in ("MCP","Mcp","Tool")):
            for pattern in tool_patterns:
                for match in pattern.finditer(line):
                    name=match.group(1)
                    if "." in name or "_" in name or "memory" in name.lower() or "continu" in name.lower():
                        add(items,seen,"mcp_tool_candidate",name,rel,index,line.strip()[:500],"MCP")

# Xcode/package product discovery
project_markers={
    "workspaces":[str(p.relative_to(root)) for p in root.rglob("*.xcworkspace") if not any(x in SKIP_DIRS for x in p.relative_to(root).parts)],
    "projects":[str(p.relative_to(root)) for p in root.rglob("*.xcodeproj") if not any(x in SKIP_DIRS for x in p.relative_to(root).parts)],
    "package_swift":str((root/"Package.swift").relative_to(root)) if (root/"Package.swift").exists() else None,
}
commands=[]
if (root/"Package.swift").exists():
    result=command(root,["swift","package","describe","--type","json"])
    commands.append(result)
    if result["exit_code"]==0:
        try:
            d=json.loads(result["output"])
            for p in d.get("products",[]):
                name=p.get("name")
                if name: add(items,seen,"product",name,"Package.swift",1,json.dumps(p,sort_keys=True)[:500],"BUILD")
            for t in d.get("targets",[]):
                name=t.get("name")
                if name: add(items,seen,"target",name,"Package.swift",1,json.dumps(t,sort_keys=True)[:500],"BUILD")
        except Exception:
            pass

for workspace in project_markers["workspaces"][:1]:
    commands.append(command(root,["xcodebuild","-list","-json","-workspace",workspace]))
for project in project_markers["projects"][:1]:
    commands.append(command(root,["xcodebuild","-list","-json","-project",project]))

file_hashes=[]
for p in files(root):
    try:
        file_hashes.append({"path":str(p.relative_to(root)),"sha256":sha256(p),"bytes":p.stat().st_size})
    except Exception: pass

payload={
    "schema_version":1,
    "generated_at":datetime.now(timezone.utc).isoformat(),
    "repository_root":str(root),
    "source_snapshot":{
        "file_count":len(file_hashes),
        "swift_file_count":len(swift_files),
        "swift_line_count":sum(len(p.read_text(encoding="utf-8",errors="replace").splitlines()) for p in swift_files),
        "files":file_hashes,
    },
    "project_markers":project_markers,
    "discovery_commands":commands,
    "features":sorted(items,key=lambda x:(x["category"],x["key"],x["source"]["path"],x["source"]["line"])),
    "runtime_completion_required":True,
    "required_runtime_surfaces":["app scenes and windows","menus commands and shortcuts","settings persistence","MCP initialize/list/tools/resources/prompts","project format round trips","model/provider integrations","telemetry-to-gauge mappings","import/export","accessibility"],
    "parity_summary":{"preserved":0,"additive":0,"migrated":0,"unknown":len(items),"removed":0,"untested":len(items)}
}
tmp=out.with_suffix(".tmp")
tmp.write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n")
os.replace(tmp,out)
print(json.dumps({"output":str(out),"features":len(items),"swift_files":len(swift_files)},indent=2))
