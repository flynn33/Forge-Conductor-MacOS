#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: check_privileged_filesystem_bundle.sh APP_BUNDLE [Debug|Release]}"
CONFIGURATION="${2:-Debug}"
DAEMON="$APP_BUNDLE/Contents/MacOS/forge-filesystem-daemon"
DAEMON_PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.forge-conductor.filesystem-daemon.plist"

case "$CONFIGURATION" in
  Debug)
    TEAM_IDENTIFIER="9AQ2C2838M"
    CERTIFICATE_REQUIREMENT='certificate leaf[field.1.2.840.113635.100.6.1.12] exists'
    ;;
  Release)
    TEAM_IDENTIFIER="2Y25RTLZET"
    CERTIFICATE_REQUIREMENT='(certificate leaf[field.1.2.840.113635.100.6.1.13] exists or certificate leaf[field.1.2.840.113635.100.6.1.12] exists)'
    ;;
  *)
    echo "unsupported build configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac

[[ -d "$APP_BUNDLE" ]]
[[ -x "$DAEMON" ]]
[[ -f "$DAEMON_PLIST" ]]

/usr/bin/plutil -lint "$DAEMON_PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST")" == "com.forge-conductor.filesystem-daemon" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$DAEMON_PLIST")" == "Contents/MacOS/forge-filesystem-daemon" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.forge-conductor.filesystem-daemon' "$DAEMON_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :UserName' "$DAEMON_PLIST")" == "root" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Umask' "$DAEMON_PLIST")" == "63" ]]
if /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$DAEMON_PLIST" >/dev/null 2>&1; then
  echo "LaunchDaemon plist must not set RunAtLoad" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$DAEMON_PLIST" >/dev/null 2>&1; then
  echo "LaunchDaemon plist must not set KeepAlive" >&2
  exit 1
fi

APP_REQUIREMENT="anchor apple generic and identifier \"com.forge-conductor.app\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and $CERTIFICATE_REQUIREMENT"
DAEMON_REQUIREMENT="anchor apple generic and identifier \"com.forge-conductor.filesystem-daemon\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and $CERTIFICATE_REQUIREMENT"

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=4 "-R=$APP_REQUIREMENT" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=4 "-R=$DAEMON_REQUIREMENT" "$DAEMON"

TEMPORARY_DIRECTORY="$(mktemp -d /tmp/forge-filesystem-bundle-check.XXXXXX)"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
/usr/bin/codesign -d --entitlements :- "$DAEMON" \
  >"$TEMPORARY_DIRECTORY/daemon-entitlements.plist" 2>"$TEMPORARY_DIRECTORY/codesign-display.txt" || true
EXPECTED_APPLICATION_IDENTIFIER="$TEAM_IDENTIFIER.com.forge-conductor.filesystem-daemon"
ACTUAL_APPLICATION_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$TEMPORARY_DIRECTORY/daemon-entitlements.plist" 2>/dev/null || true)"
if [[ "$ACTUAL_APPLICATION_IDENTIFIER" != "$EXPECTED_APPLICATION_IDENTIFIER" ]]; then
  echo "filesystem daemon application identifier is not exact" >&2
  /bin/cat "$TEMPORARY_DIRECTORY/daemon-entitlements.plist" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c 'Delete :com.apple.application-identifier' "$TEMPORARY_DIRECTORY/daemon-entitlements.plist"
if /usr/bin/grep -q '<key>' "$TEMPORARY_DIRECTORY/daemon-entitlements.plist"; then
  echo "filesystem daemon has unexpected entitlements" >&2
  /bin/cat "$TEMPORARY_DIRECTORY/daemon-entitlements.plist" >&2
  exit 1
fi

/usr/bin/codesign -d --verbose=4 -r- "$APP_BUNDLE" 2>&1
/usr/bin/codesign -d --verbose=4 -r- "$DAEMON" 2>&1
echo "privileged filesystem bundle inspection passed for $CONFIGURATION"
