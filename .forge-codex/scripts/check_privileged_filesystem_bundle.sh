#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

USAGE="usage: check_privileged_filesystem_bundle.sh APP_BUNDLE [Debug|DevelopmentRelease|Release] [CLI_EXECUTABLE]"
if (( $# < 1 || $# > 3 )); then
  printf '%s\n' "$USAGE" >&2
  exit 2
fi

APP_BUNDLE="$1"
CONFIGURATION="${2:-Debug}"
CLI_EXECUTABLE="${3:-}"
CLI_ARGUMENT_SUPPLIED=0
if (( $# == 3 )); then
  CLI_ARGUMENT_SUPPLIED=1
fi
DAEMON="$APP_BUNDLE/Contents/MacOS/forge-filesystem-daemon"
DAEMON_PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.forge-conductor.filesystem-daemon.plist"
APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Forge Conductor"
EMBEDDED_CLI="$APP_BUNDLE/Contents/Helpers/forge-conductor"
RUNTIME_LAUNCHER="$APP_BUNDLE/Contents/Helpers/forge-runtime-launcher"
CORE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/ForgeConductorCore.framework"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

supported_architectures() {
  local role="$1"
  local executable="$2"
  local architectures
  local architecture

  if ! architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)"; then
    fail "cannot inspect $role architectures: $executable"
  fi
  [[ -n "$architectures" ]] || fail "$role has no Mach-O architectures: $executable"
  for architecture in $architectures; do
    case "$architecture" in
      arm64|x86_64) ;;
      *) fail "$role has unsupported architecture $architecture: $executable" ;;
    esac
  done
  printf '%s\n' "$architectures"
}

has_architecture() {
  local architectures="$1"
  local expected="$2"
  local architecture

  for architecture in $architectures; do
    [[ "$architecture" == "$expected" ]] && return 0
  done
  return 1
}

printed_plist_string() {
  local printed_plist="$1"
  local key="$2"

  /usr/bin/awk -v key="$key" '
    BEGIN { prefix = "  \"" key "\" => " }
    index($0, prefix) == 1 {
      count += 1
      raw = substr($0, length(prefix) + 1)
      if (raw !~ /^\"[^\"]*\"$/) {
        malformed = 1
      } else {
        sub(/^\"/, "", raw)
        sub(/\"$/, "", raw)
        value = raw
      }
    }
    END {
      if (count == 0) exit 1
      if (count != 1 || malformed) exit 2
      print value
    }
  ' "$printed_plist"
}

reject_unknown_daemon_seal_keys() {
  local role="$1"
  local printed_plist="$2"
  local unknown_keys

  unknown_keys="$(/usr/bin/awk '
    /^  \"ForgeFilesystemDaemonCDHash/ {
      key = $0
      sub(/^  \"/, "", key)
      sub(/\".*$/, "", key)
      if (key != "ForgeFilesystemDaemonCDHashArm64" &&
          key != "ForgeFilesystemDaemonCDHashX86_64") {
        print key
      }
    }
  ' "$printed_plist")"
  [[ -z "$unknown_keys" ]] || fail "$role has unsupported daemon CDHash seal keys: $unknown_keys"
}

require_cli_runpaths() {
  local role="$1"
  local executable="$2"
  local load_commands
  local runpaths
  local required_runpath

  if ! load_commands="$(/usr/bin/otool -l "$executable" 2>/dev/null)"; then
    fail "cannot inspect $role Mach-O load commands: $executable"
  fi
  runpaths="$(printf '%s\n' "$load_commands" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { awaiting_path = 1; next }
    awaiting_path && $1 == "path" { print $2; awaiting_path = 0 }
  ')"
  for required_runpath in \
    "@executable_path" \
    "@executable_path/../Frameworks"; do
    if ! printf '%s\n' "$runpaths" | /usr/bin/grep -Fqx "$required_runpath"; then
      fail "$role is missing required LC_RPATH $required_runpath: $executable"
    fi
  done
}

validate_cli_artifact() {
  local role="$1"
  local executable="$2"
  local printed_plist="$3"
  local declared_version
  local version_output

  [[ -f "$executable" ]] || fail "$role is missing or not a regular file: $executable"
  [[ ! -L "$executable" ]] || fail "$role must not be a symbolic link: $executable"
  [[ -x "$executable" ]] || fail "$role is not executable: $executable"
  /usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
    "-R=$CLI_REQUIREMENT" "$executable"
  supported_architectures "$role" "$executable" >/dev/null
  require_cli_runpaths "$role" "$executable"
  if ! /usr/bin/plutil -p "$executable" >"$printed_plist"; then
    fail "cannot read the $role embedded Info.plist"
  fi
  reject_unknown_daemon_seal_keys "$role" "$printed_plist"
  if ! declared_version="$(printed_plist_string \
    "$printed_plist" "CFBundleShortVersionString")"; then
    fail "$role has no single string CFBundleShortVersionString"
  fi
  if ! version_output="$(/usr/bin/env -i PATH=/usr/bin:/bin \
    "$executable" version 2>&1)"; then
    fail "$role version smoke failed: $version_output"
  fi
  [[ "$version_output" == "$declared_version" ]] \
    || fail "$role version smoke does not match its embedded Info.plist"
}

require_matching_daemon_seal() {
  local role="$1"
  local printed_plist="$2"
  local key="$3"
  local expected_hash="$4"
  local actual_hash

  if ! actual_hash="$(printed_plist_string "$printed_plist" "$key")"; then
    fail "$role is missing a single string $key seal"
  fi
  if [[ ! "$actual_hash" =~ ^[0-9a-f]{40}$ ]]; then
    fail "$role has malformed $key seal: $actual_hash"
  fi
  [[ "$actual_hash" == "$expected_hash" ]] \
    || fail "$role $key seal does not match the embedded daemon CodeDirectory hash"
}

require_absent_daemon_seal() {
  local role="$1"
  local printed_plist="$2"
  local key="$3"
  local status

  if printed_plist_string "$printed_plist" "$key" >/dev/null; then
    fail "$role has an extra $key seal without a corresponding daemon architecture"
  else
    status=$?
  fi
  [[ "$status" -eq 1 ]] || fail "$role has malformed or duplicate $key seal state"
}

daemon_code_directory_hash() {
  local architecture="$1"
  local signature_details
  local code_directory_hash

  if ! signature_details="$(/usr/bin/codesign --display --verbose=4 --arch "$architecture" "$DAEMON" 2>&1)"; then
    fail "cannot inspect the embedded daemon $architecture CodeDirectory hash"
  fi
  if ! code_directory_hash="$(printf '%s\n' "$signature_details" | /usr/bin/awk -F= '
    $1 == "CDHash" { count += 1; value = $2 }
    END {
      if (count != 1) exit 1
      print value
    }
  ')"; then
    fail "embedded daemon has no single $architecture CodeDirectory hash"
  fi
  if [[ ! "$code_directory_hash" =~ ^[0-9a-f]{40}$ ]]; then
    fail "embedded daemon has malformed $architecture CodeDirectory hash: $code_directory_hash"
  fi
  printf '%s\n' "$code_directory_hash"
}

case "$CONFIGURATION" in
  Debug|DevelopmentRelease)
    TEAM_IDENTIFIER="9AQ2C2838M"
    CERTIFICATE_REQUIREMENT='certificate leaf[field.1.2.840.113635.100.6.1.12] exists'
    ;;
  Release)
    TEAM_IDENTIFIER="2Y25RTLZET"
    CERTIFICATE_REQUIREMENT='certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    ;;
  *)
    echo "unsupported build configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac

[[ -d "$APP_BUNDLE" ]]
[[ -x "$DAEMON" ]]
[[ -f "$DAEMON_PLIST" ]]
[[ -f "$APP_INFO_PLIST" ]]
[[ -f "$APP_EXECUTABLE" ]] || fail "app main executable is missing or not a regular file: $APP_EXECUTABLE"
[[ ! -L "$APP_EXECUTABLE" ]] || fail "app main executable must not be a symbolic link: $APP_EXECUTABLE"
[[ -x "$APP_EXECUTABLE" ]] || fail "app main executable is not executable: $APP_EXECUTABLE"
[[ -f "$RUNTIME_LAUNCHER" ]] || fail "runtime launcher is missing or not a regular file: $RUNTIME_LAUNCHER"
[[ ! -L "$RUNTIME_LAUNCHER" ]] || fail "runtime launcher must not be a symbolic link: $RUNTIME_LAUNCHER"
[[ -x "$RUNTIME_LAUNCHER" ]] || fail "runtime launcher is not executable: $RUNTIME_LAUNCHER"
[[ -d "$CORE_FRAMEWORK" ]] || fail "core framework is missing: $CORE_FRAMEWORK"
[[ ! -L "$CORE_FRAMEWORK" ]] || fail "core framework must not be a symbolic link: $CORE_FRAMEWORK"
supported_architectures "app main executable" "$APP_EXECUTABLE" >/dev/null
supported_architectures "runtime launcher" "$RUNTIME_LAUNCHER" >/dev/null

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
CLI_REQUIREMENT="anchor apple generic and identifier \"com.forge-conductor.cli\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and $CERTIFICATE_REQUIREMENT"
RUNTIME_LAUNCHER_REQUIREMENT="anchor apple generic and identifier \"com.forge-conductor.runtime-launcher\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and $CERTIFICATE_REQUIREMENT"
CORE_FRAMEWORK_REQUIREMENT="anchor apple generic and identifier \"com.forge-conductor.core\" and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and $CERTIFICATE_REQUIREMENT"

/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=4 "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
  "-R=$APP_REQUIREMENT" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
  "-R=$DAEMON_REQUIREMENT" "$DAEMON"
/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
  "-R=$RUNTIME_LAUNCHER_REQUIREMENT" "$RUNTIME_LAUNCHER"
/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
  "-R=$CORE_FRAMEWORK_REQUIREMENT" "$CORE_FRAMEWORK"

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

/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \
  "-R=$DAEMON_REQUIREMENT" "$DAEMON"
DAEMON_ARCHITECTURES="$(supported_architectures "embedded filesystem daemon" "$DAEMON")"

if ! /usr/bin/plutil -p "$APP_INFO_PLIST" \
  >"$TEMPORARY_DIRECTORY/app-info.txt"; then
  fail "cannot read the app Info.plist"
fi
validate_cli_artifact \
  "embedded manager CLI" "$EMBEDDED_CLI" \
  "$TEMPORARY_DIRECTORY/embedded-cli-info.txt"
reject_unknown_daemon_seal_keys \
  "Forge Conductor app" "$TEMPORARY_DIRECTORY/app-info.txt"

if (( CLI_ARGUMENT_SUPPLIED == 1 )); then
  [[ -n "$CLI_EXECUTABLE" ]] || fail "CLI executable path is empty"
  validate_cli_artifact \
    "standalone manager CLI" "$CLI_EXECUTABLE" \
    "$TEMPORARY_DIRECTORY/standalone-cli-info.txt"
fi

for ARCHITECTURE in arm64 x86_64; do
  case "$ARCHITECTURE" in
    arm64) SEAL_KEY="ForgeFilesystemDaemonCDHashArm64" ;;
    x86_64) SEAL_KEY="ForgeFilesystemDaemonCDHashX86_64" ;;
  esac
  if has_architecture "$DAEMON_ARCHITECTURES" "$ARCHITECTURE"; then
    DAEMON_CDHASH="$(daemon_code_directory_hash "$ARCHITECTURE")"
    require_matching_daemon_seal \
      "Forge Conductor app" "$TEMPORARY_DIRECTORY/app-info.txt" \
      "$SEAL_KEY" "$DAEMON_CDHASH"
    require_matching_daemon_seal \
      "embedded manager CLI" "$TEMPORARY_DIRECTORY/embedded-cli-info.txt" \
      "$SEAL_KEY" "$DAEMON_CDHASH"
    if (( CLI_ARGUMENT_SUPPLIED == 1 )); then
      require_matching_daemon_seal \
        "standalone manager CLI" "$TEMPORARY_DIRECTORY/standalone-cli-info.txt" \
        "$SEAL_KEY" "$DAEMON_CDHASH"
    fi
  else
    require_absent_daemon_seal \
      "Forge Conductor app" "$TEMPORARY_DIRECTORY/app-info.txt" "$SEAL_KEY"
    require_absent_daemon_seal \
      "embedded manager CLI" "$TEMPORARY_DIRECTORY/embedded-cli-info.txt" \
      "$SEAL_KEY"
    if (( CLI_ARGUMENT_SUPPLIED == 1 )); then
      require_absent_daemon_seal \
        "standalone manager CLI" "$TEMPORARY_DIRECTORY/standalone-cli-info.txt" \
        "$SEAL_KEY"
    fi
  fi
done

/usr/bin/codesign -d --verbose=4 -r- "$APP_BUNDLE" 2>&1
/usr/bin/codesign -d --verbose=4 -r- "$DAEMON" 2>&1
/usr/bin/codesign -d --verbose=4 -r- "$EMBEDDED_CLI" 2>&1
/usr/bin/codesign -d --verbose=4 -r- "$RUNTIME_LAUNCHER" 2>&1
/usr/bin/codesign -d --verbose=4 -r- "$CORE_FRAMEWORK" 2>&1
if (( CLI_ARGUMENT_SUPPLIED == 1 )); then
  /usr/bin/codesign -d --verbose=4 -r- "$CLI_EXECUTABLE" 2>&1
fi
echo "privileged filesystem bundle inspection passed for $CONFIGURATION"
