#!/bin/bash
# Double-clickable macOS Terminal launcher for RemarkableMyscriptLocal v1.0.0
cd "$(dirname "$0")" 2>/dev/null || true
echo "============================================================"
echo " RemarkableMyscriptLocal one-liner install (v1.0.0)"
echo "============================================================"
echo
set -euo pipefail
curl -fsSL "https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v1.0.0/scripts/install-from-web.sh" | bash
echo
echo "OK  Finished — press Enter to close"
read -r _
