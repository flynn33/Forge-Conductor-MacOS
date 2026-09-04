#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--repo',default='.'); args=ap.parse_args(); repo=Path(args.repo).resolve()
    plan=json.loads((repo/'.forge-qwen-remediation/plans/work-packages.json').read_text())['work_packages']
    state=json.loads((repo/'.forge-qwen-state/run-state.json').read_text()); done=set(state['completed_work_packages'])
    current=state.get('current_work_package')
    if current and current not in done:
        wp=next(x for x in plan if x['id']==current); print(json.dumps({'selected':wp,'reason':'resume_current'},indent=2)); return 0
    ready=[x for x in plan if x['id'] not in done and all(d in done for d in x.get('depends_on',[]))]
    if not ready: print(json.dumps({'selected':None,'reason':'no_ready_work','completed':sorted(done)},indent=2)); return 1
    priority={'critical':0,'high':1,'medium':2,'low':3}; ready.sort(key=lambda x:(priority.get(x.get('priority','medium'),9),x['id']))
    selected=ready[0]; print(json.dumps({'selected':selected,'other_ready':[x['id'] for x in ready[1:]]},indent=2)); return 0
if __name__=='__main__': raise SystemExit(main())
