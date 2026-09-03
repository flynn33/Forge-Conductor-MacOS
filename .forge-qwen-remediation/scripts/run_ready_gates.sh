#!/bin/bash
set -euo pipefail
REPO="${1:-.}"
cd "$REPO"
DESIGN="./.forge-qwen-remediation"
python3 "$DESIGN/scripts/record_evidence.py" --repo . --work-package P00 --gate G00 --kind swiftpm-debug --timeout 7200 -- swift test -Xswiftc -warnings-as-errors --no-parallel
python3 "$DESIGN/scripts/record_evidence.py" --repo . --work-package P00 --gate G01 --kind xcode-parity -- python3 "$DESIGN/scripts/check_xcode_parity.py" --repo .
python3 "$DESIGN/scripts/record_evidence.py" --repo . --work-package P11 --gate G13 --kind publication-hygiene -- python3 "$DESIGN/scripts/scan_publication_hygiene.py" --repo .
python3 "$DESIGN/scripts/record_evidence.py" --repo . --work-package P11 --gate G13 --kind secret-scan -- python3 "$DESIGN/scripts/scan_secrets.py" --repo .
python3 "$DESIGN/scripts/verify_no_ship.py" --repo .
