#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Forge Conductor"
BUILD_PRODUCT="forge-conductor-app"
BINARY_CONFIGURATION="${FORGE_BUILD_CONFIGURATION:-debug}"
BUNDLE_ID="com.forge-conductor.app"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
VERSION_SOURCE="$ROOT_DIR/Sources/ForgeConductorCore/Application/ForgeApp.swift"
APP_MARKETING_VERSION="$(sed -n 's/.*public static let version = "\([0-9][0-9.]*\)".*/\1/p' "$VERSION_SOURCE" | head -1)"
APP_BUILD_VERSION="${FORGE_BUILD_NUMBER:-1}"

if [[ ! "$APP_MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "unable to read a semantic version from $VERSION_SOURCE" >&2
  exit 1
fi
if [[ ! "$APP_BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "FORGE_BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
if [[ "$BINARY_CONFIGURATION" != "debug" && "$BINARY_CONFIGURATION" != "release" ]]; then
  echo "FORGE_BUILD_CONFIGURATION must be debug or release" >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build --configuration "$BINARY_CONFIGURATION" --product "$BUILD_PRODUCT"
BUILD_DIR="$(swift build --configuration "$BINARY_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$BUILD_PRODUCT"

if [[ ! -x "$BUILD_BINARY" ]]; then
  echo "built GUI executable was not found at $BUILD_BINARY" >&2
  exit 1
fi

# APP_BUNDLE is deliberately fixed beneath this repository's dist directory.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Sources/ForgeConductorApp/Resources/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Sources/ForgeConductorApp/Resources/Forge-Conductor.icns" "$APP_RESOURCES/Forge-Conductor.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_MARKETING_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$INFO_PLIST" >/dev/null 2>&1 || true

codesign --force --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_project_gui() {
  # Stop only the project-local GUI. The manager and LM Studio connectors share
  # the executable name and must remain uninterrupted during a UI relaunch.
  pkill -f "^$APP_BINARY$" >/dev/null 2>&1 || true
}

case "$MODE" in
  --build-only|build-only)
    echo "$APP_NAME staged at $APP_BUNDLE"
    ;;
  run)
    stop_project_gui
    open_app
    ;;
  --debug|debug)
    stop_project_gui
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_project_gui
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_project_gui
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\" OR subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_project_gui
    open_app
    for _ in {1..20}; do
      if pgrep -f "^$APP_BINARY$" >/dev/null; then
        echo "$APP_NAME launched from $APP_BUNDLE"
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
