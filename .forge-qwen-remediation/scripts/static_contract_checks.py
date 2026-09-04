#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from pathlib import Path

def read(repo,rel):
    p=repo/rel
    return p.read_text(errors='ignore') if p.exists() else ''
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--repo',default='.'); args=ap.parse_args(); repo=Path(args.repo).resolve(); checks=[]
    def add(name,passed,detail): checks.append({'name':name,'passed':bool(passed),'detail':detail})
    config=read(repo,'Sources/ForgeConductorCore/Domain/AppConfig.swift')+read(repo,'Sources/ForgeConductorCore/Infrastructure/ConfigStore.swift')
    shell=read(repo,'Sources/ForgeConductorCore/Application/Tools/ShellToolPack.swift')
    add('shell-default-enabled','enabled: Bool = true' in config or 'enabled: true' in config or 'enabled = true' in config,'shell policy source must default enabled')
    add('shell-exec-registered','shell_exec' in shell,'legacy shell tool remains registered')
    runtime=read(repo,'Sources/ForgeConductorCore/Application/ManagedAutonomyRuntime.swift')
    add('generic-completion-validator-removed','EvidenceBoundCompletionValidator' not in runtime,'production runtime must not use generic evidence hashes')
    alltext='\n'.join(p.read_text(errors='ignore') for p in (repo/'Sources').rglob('*.swift'))
    add('package-queue-present','PackageQueueService' in alltext and 'QueueAssignment' in alltext,'missing until P04')
    add('project-reset-service','ProjectResetService' in alltext,'missing until P05')
    add('xpc-runtime','NSXPCConnection' in alltext or 'ForgeRuntimeXPC' in alltext,'missing until P07')
    ui='\n'.join(p.read_text(errors='ignore') for p in (repo/'Sources/ForgeConductorApp').rglob('*.swift'))
    empty_buttons=re.findall(r'Button\("[^"]+"\)\s*\{\s*\}',ui)
    add('no-empty-button-actions',not empty_buttons,f'empty actions: {empty_buttons[:20]}')
    pbx=read(repo,'ForgeConductor.xcodeproj/project.pbxproj')
    missing=[name for name in ['LMStudioContractFixtureTests.swift','LMStudioContractFixtureServer.swift'] if name not in pbx]
    add('xcode-test-parity',not missing,f'missing: {missing}')
    report={'passed':all(c['passed'] for c in checks),'checks':checks}
    state=repo/'.forge-qwen-state'; state.mkdir(exist_ok=True); (state/'static-contract-checks.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2)); return 0 if report['passed'] else 1
if __name__=='__main__': raise SystemExit(main())
