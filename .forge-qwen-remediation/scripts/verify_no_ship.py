#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from pathlib import Path
PROHIBITED=[r'gh\s+release\s+create',r'git\s+push\s+[^\n]*--tags',r'xcrun\s+notarytool\s+submit',r'altool\s+--upload-app',r'transporter[^\n]*upload']
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--repo',default='.'); args=ap.parse_args(); repo=Path(args.repo).resolve(); state=json.loads((repo/'.forge-qwen-state/run-state.json').read_text()); errors=[]
    if state.get('shipped') is not False: errors.append('shipped must remain false')
    for p in (repo/'.forge-qwen-state/evidence').glob('*.json'):
        text=p.read_text(errors='ignore')
        for pattern in PROHIBITED:
            if re.search(pattern,text,re.I): errors.append(f'prohibited publication command in {p.name}: {pattern}')
    if errors: print(json.dumps({'passed':False,'errors':errors},indent=2)); return 1
    print(json.dumps({'passed':True,'shipped':False},indent=2)); return 0
if __name__=='__main__': raise SystemExit(main())
