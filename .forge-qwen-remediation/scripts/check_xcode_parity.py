#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--repo',default='.'); args=ap.parse_args(); repo=Path(args.repo).resolve(); pbx=(repo/'ForgeConductor.xcodeproj/project.pbxproj').read_text(errors='ignore')
    swiftpm=[p.relative_to(repo).as_posix() for base in ['Sources','Tests'] for p in (repo/base).rglob('*.swift')]
    missing=[rel for rel in swiftpm if Path(rel).name not in pbx]
    report={'total_swift_files':len(swiftpm),'missing_from_xcode_by_filename':missing,'passed':not missing}
    print(json.dumps(report,indent=2)); return 0 if not missing else 1
if __name__=='__main__': raise SystemExit(main())
