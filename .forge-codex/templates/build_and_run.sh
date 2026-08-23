#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="run"
[[ $# -gt 0 ]] && MODE="$1"

kill_existing() {
  local process_name="${FORGE_PROCESS_NAME:-Forge Conductor}"
  pkill -x "$process_name" 2>/dev/null || true
}

discover_xcode_container() {
  local workspace project
  workspace="$(find "$ROOT" -name '*.xcworkspace' -print | sed -n '1p')"
  project="$(find "$ROOT" -name '*.xcodeproj' -print | sed -n '1p')"
  if [[ -n "$workspace" ]]; then
    printf '%s\n' "-workspace" "$workspace"
  elif [[ -n "$project" ]]; then
    printf '%s\n' "-project" "$project"
  fi
}

build_xcode() {
  local workspace project
  local -a container_args
  workspace="$(find "$ROOT" -name '*.xcworkspace' -print | sed -n '1p')"
  project="$(find "$ROOT" -name '*.xcodeproj' -print | sed -n '1p')"
  if [[ -n "$workspace" ]]; then
    container_args=(-workspace "$workspace")
  elif [[ -n "$project" ]]; then
    container_args=(-project "$project")
  else
    echo "No Xcode container discovered" >&2
    exit 65
  fi
  local scheme="${FORGE_SCHEME:-}"
  if [[ -z "$scheme" ]]; then
    scheme="$(xcodebuild "${container_args[@]}" -list -json | python3 -c '
import json,sys
d=json.load(sys.stdin)
v=next(iter(d.values()))
schemes=v.get("schemes",[])
print(next((s for s in schemes if "Forge" in s), schemes[0] if schemes else ""))
')"
  fi
  [[ -n "$scheme" ]] || { echo "No shared Xcode scheme discovered; set FORGE_SCHEME" >&2; exit 65; }
  local derived="$ROOT/.build/DerivedData"
  xcodebuild "${container_args[@]}" -scheme "$scheme" -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
  local app
  app="$(find "$derived/Build/Products/Debug" -maxdepth 2 -name '*.app' -print | sed -n '1p')"
  [[ -n "$app" ]] || { echo "Build succeeded but no .app was found" >&2; exit 66; }
  kill_existing
  if [[ "$MODE" != "--build-only" ]]; then
    open -n "$app"
  fi
  if [[ "$MODE" == "--verify" ]]; then
    sleep 2
    local executable
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    pgrep -x "$executable" >/dev/null
  fi
}

build_swiftpm() {
  cd "$ROOT"
  swift build
  if [[ "$MODE" == "--build-only" ]]; then return; fi

  local product="${FORGE_PRODUCT:-}"
  if [[ -z "$product" ]]; then
    product="$(swift package describe --type json | python3 -c '
import json,sys
d=json.load(sys.stdin)
products=d.get("products",[])
def is_executable(product):
    kind=product.get("type")
    return kind=="executable" or (isinstance(kind,dict) and "executable" in kind)
execs=[product.get("name") for product in products if is_executable(product)]
print(next((n for n in execs if n and "Forge" in n), execs[0] if execs else ""))
')"
  fi
  [[ -n "$product" ]] || { echo "No executable SwiftPM product discovered; set FORGE_PRODUCT" >&2; exit 65; }
  local bin
  bin="$(swift build --show-bin-path)/$product"
  [[ -x "$bin" ]] || { echo "Executable product not found: $bin" >&2; exit 66; }

  local app_name="${FORGE_APP_NAME:-Forge Conductor}"
  local bundle="$ROOT/dist/$app_name.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$bin" "$bundle/Contents/MacOS/$product"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>${product}</string>
<key>CFBundleIdentifier</key><string>com.forgeconductor.app</string>
<key>CFBundleName</key><string>${app_name}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  kill_existing
  open -n "$bundle"
  if [[ "$MODE" == "--verify" ]]; then
    sleep 2
    pgrep -x "$product" >/dev/null
  fi
}

if find "$ROOT" \( -name '*.xcworkspace' -o -name '*.xcodeproj' \) -print | sed -n '1p' | grep -q .; then
  build_xcode
elif [[ -f "$ROOT/Package.swift" ]]; then
  build_swiftpm
else
  echo "No Xcode project/workspace or Package.swift found" >&2
  exit 65
fi
