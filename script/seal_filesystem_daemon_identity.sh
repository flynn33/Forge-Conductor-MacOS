#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <filesystem-daemon> <source-info-plist> <sealed-info-plist>" >&2
    exit 64
fi

daemon_path=$1
source_plist=$2
sealed_plist=$3

if [[ ! -f "$daemon_path" || -L "$daemon_path" ]]; then
    echo "filesystem daemon is missing or linked: $daemon_path" >&2
    exit 66
fi
if [[ ! -f "$source_plist" || -L "$source_plist" ]]; then
    echo "source Info.plist is missing or linked: $source_plist" >&2
    exit 66
fi

/usr/bin/codesign --verify --strict "$daemon_path"

architectures=$(/usr/bin/lipo -archs "$daemon_path")
if [[ -z "$architectures" ]]; then
    echo "filesystem daemon has no Mach-O architecture" >&2
    exit 65
fi

hash_keys=()
hashes=()
for architecture in $architectures; do
    signing_details=$(/usr/bin/codesign --display --verbose=4 --arch "$architecture" "$daemon_path" 2>&1)
    code_directory_hash=$(printf '%s\n' "$signing_details" \
        | /usr/bin/awk -F= '$1 == "CDHash" { print tolower($2); exit }')
    if [[ ! "$code_directory_hash" =~ ^[0-9a-f]{40}$ ]]; then
        echo "filesystem daemon has no valid CodeDirectory hash for $architecture" >&2
        exit 65
    fi
    case "$architecture" in
        arm64)
            hash_keys+=("ForgeFilesystemDaemonCDHashArm64")
            ;;
        x86_64)
            hash_keys+=("ForgeFilesystemDaemonCDHashX86_64")
            ;;
        *)
            echo "unsupported filesystem daemon architecture: $architecture" >&2
            exit 65
            ;;
    esac
    hashes+=("$code_directory_hash")
done

/bin/mkdir -p "$(/usr/bin/dirname "$sealed_plist")"
temporary_plist="${sealed_plist}.tmp.$$"
trap '/bin/rm -f "$temporary_plist"' EXIT
/bin/cp "$source_plist" "$temporary_plist"
/usr/bin/plutil -remove ForgeFilesystemDaemonCDHashArm64 "$temporary_plist" 2>/dev/null || true
/usr/bin/plutil -remove ForgeFilesystemDaemonCDHashX86_64 "$temporary_plist" 2>/dev/null || true
for index in "${!hashes[@]}"; do
    /usr/bin/plutil -insert "${hash_keys[$index]}" \
        -string "${hashes[$index]}" "$temporary_plist"
done
/usr/bin/plutil -lint "$temporary_plist"
/bin/mv -f "$temporary_plist" "$sealed_plist"
trap - EXIT
