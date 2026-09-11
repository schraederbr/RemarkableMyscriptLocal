#!/bin/bash
# Double-clickable macOS Terminal launcher for RemarkableMyscriptLocal v0.3.9
cd "$(dirname "$0")" 2>/dev/null || true
echo "============================================================"
echo " RemarkableMyscriptLocal one-liner install (v0.3.9)"
echo "============================================================"
echo
set -euo pipefail
curl -fsSL "https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.9/scripts/install-from-web.sh" | bash
echo
echo "OK  Finished — press Enter to close"
read -r _
