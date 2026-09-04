#!/usr/bin/env python3
from __future__ import annotations
import argparse, re
from pathlib import Path
PATTERNS=[
    re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(r'\bsk-[A-Za-z0-9_-]{20,}\b'),
    re.compile(r'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
    re.compile(r"(?i)(api[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*['\"](?!\$\{|__|<)[^'\"]{12,}['\"]"),
]
EXCLUDED_PREFIXES=('.git/','.build/','.forge-qwen-state/','.forge-qwen-remediation/inputs/')
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--repo',default='.'); args=ap.parse_args(); repo=Path(args.repo).resolve(); hits=[]
    for p in repo.rglob('*'):
        if not p.is_file() or p.stat().st_size>4*1024*1024: continue
        rel=p.relative_to(repo).as_posix()
        if any(rel.startswith(x) for x in EXCLUDED_PREFIXES): continue
        text=p.read_text(errors='ignore')
        for rx in PATTERNS:
            if rx.search(text): hits.append(rel); break
    if hits: print('\n'.join(sorted(set(hits)))); return 1
    print('secret scan passed'); return 0
if __name__=='__main__': raise SystemExit(main())
