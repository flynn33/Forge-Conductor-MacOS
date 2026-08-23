#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVIDENCE="$ROOT/.forge-codex/scripts/record_command.py"
mkdir -p "$ROOT/.forge-codex/evidence"

if [[ -f "$ROOT/Package.swift" ]]; then
  "$EVIDENCE" --repo "$ROOT" --kind swift-package-describe --related-gate G00 -- swift package describe --type json
  "$EVIDENCE" --repo "$ROOT" --kind swift-build-debug --related-gate G12 -- swift build
  "$EVIDENCE" --repo "$ROOT" --kind swift-test-debug --related-gate G12 -- swift test --parallel
  "$EVIDENCE" --repo "$ROOT" --kind swift-build-release --related-gate G11 -- swift build -c release
fi

workspace="$(find "$ROOT" -name '*.xcworkspace' -print | sed -n '1p')"
project="$(find "$ROOT" -name '*.xcodeproj' -print | sed -n '1p')"
container_args=()
if [[ -n "$workspace" ]]; then
  container_args=(-workspace "$workspace")
elif [[ -n "$project" ]]; then
  container_args=(-project "$project")
fi

if [[ ${#container_args[@]} -gt 0 && "$(uname -s)" == "Darwin" ]]; then
  scheme="${FORGE_SCHEME:-}"
  if [[ -z "$scheme" ]]; then
    scheme="$(xcodebuild "${container_args[@]}" -list -json | python3 -c '
import json,sys
d=json.load(sys.stdin); v=next(iter(d.values())); ss=v.get("schemes",[])
print(next((s for s in ss if "Forge" in s),ss[0] if ss else ""))
')"
  fi
  [[ -n "$scheme" ]] || { echo "No Xcode scheme found" >&2; exit 65; }
  derived="$ROOT/.build/DerivedData"
  "$EVIDENCE" --repo "$ROOT" --kind xcode-build-debug --related-gate G12 -- \
    xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
  "$EVIDENCE" --repo "$ROOT" --kind xcode-test-debug --related-gate G12 -- \
    xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO test
  "$EVIDENCE" --repo "$ROOT" --kind xcode-build-release --related-gate G11 -- \
    xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Release -derivedDataPath "$derived-release" CODE_SIGNING_ALLOWED=NO build

  # Sanitizers run separately to preserve signal quality.
  "$EVIDENCE" --repo "$ROOT" --kind address-sanitizer --related-gate G05 -- \
    xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived-asan" CODE_SIGNING_ALLOWED=NO -enableAddressSanitizer YES test
  "$EVIDENCE" --repo "$ROOT" --kind thread-sanitizer --related-gate G05 -- \
    xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived-tsan" CODE_SIGNING_ALLOWED=NO -enableThreadSanitizer YES test
fi
