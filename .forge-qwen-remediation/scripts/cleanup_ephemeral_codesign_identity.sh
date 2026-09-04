#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then echo "usage: $0 /path/to/forge-test.keychain-db" >&2; exit 64; fi
/usr/bin/security delete-keychain "$1" || true
rm -rf "$(dirname "$1")"
