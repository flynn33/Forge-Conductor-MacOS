#!/usr/bin/env bash
# Compilation and regression evidence only; no installation or distribution.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  integrity|swift-debug|swift-release|xcode-debug|xcode-release) ;;
  *) echo "usage: $0 integrity|swift-debug|swift-release|xcode-debug|xcode-release" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${FORGE_CI_OUTPUT_DIR:?Set an absolute, unique evidence output directory}"
case "$OUT" in /*) ;; *) echo "FORGE_CI_OUTPUT_DIR must be absolute" >&2; exit 2 ;; esac
mkdir -p "$OUT"
cd "$ROOT_DIR"
export PYTHONDONTWRITEBYTECODE=1

run_logged() {
  local log_name="$1"
  shift
  "$@" 2>&1 | tee "$OUT/$log_name.log"
}

{
  git rev-parse HEAD
  sw_vers
  uname -m
  xcodebuild -version
  swift --version
} > "$OUT/source-toolchain.txt"
echo "Native CI records compilation and test evidence; signed runtime and distribution gates remain separate."

case "$MODE" in
  integrity)
    run_logged utility-tests python3 -m unittest discover -s .forge-codex/shipping/tests -v
    run_logged attribution-policy-tests python3 -m unittest discover -s .forge-codex/scripts -p test_attribution_policy_examples.py -v
    run_logged attribution-scanner-tests python3 -m unittest discover -s .forge-codex/scripts -p test_release_scanners_hardening.py -v
    run_logged attribution python3 .forge-codex/scripts/scan_attribution.py --root "$ROOT_DIR"
    run_logged versions python3 .forge-codex/shipping/scripts/shipping_guard.py versions --repo "$ROOT_DIR"
    run_logged membership python3 .forge-codex/shipping/scripts/shipping_guard.py xcode --repo "$ROOT_DIR"
    run_logged project-list xcodebuild -list -workspace ForgeConductor.xcworkspace
    ;;
  swift-*)
    CONFIGURATION="${MODE#swift-}"
    run_logged swift-tests swift test --configuration "$CONFIGURATION" --jobs 3 \
      --scratch-path "$OUT/SwiftPM" -Xswiftc -warnings-as-errors \
      --xunit-output "$OUT/swift-tests.xml"
    test -s "$OUT/swift-tests.xml"
    ;;
  xcode-*)
    case "$MODE" in xcode-debug) CONFIGURATION=Debug ;; xcode-release) CONFIGURATION=Release ;; esac
    for SCHEME in ForgeConductor forge-conductor; do
      run_logged "$SCHEME-build" xcodebuild -workspace ForgeConductor.xcworkspace \
        -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination "platform=macOS,arch=$(uname -m)" -jobs 3 \
        -derivedDataPath "$OUT/DerivedData" \
        -resultBundlePath "$OUT/$SCHEME-build.xcresult" \
        CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES build
      xcodebuild -workspace ForgeConductor.xcworkspace -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" CODE_SIGNING_ALLOWED=NO \
        -showBuildSettings -json > "$OUT/$SCHEME-settings.json" 2> "$OUT/$SCHEME-settings.log"
    done
    run_logged artifact-versions python3 .forge-codex/shipping/scripts/shipping_guard.py versions \
      --repo "$ROOT_DIR" --settings "$OUT/ForgeConductor-settings.json" \
      --app "$OUT/DerivedData/Build/Products/$CONFIGURATION/Forge Conductor.app"
    ;;
esac
