#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-10.11.99.1}"
USER="${2:-root}"
echo "==> sync scripts to $USER@$HOST"
ssh "$USER@$HOST" 'mkdir -p /home/root/hwr/scripts /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/out /home/root/hwr/third_party/revcord'
scp "$ROOT/scripts/on-device/install-node-jonobones.sh" "$ROOT/scripts/joplin-upsert.js" \
  "$USER@$HOST:/home/root/hwr/scripts/"
scp "$ROOT/third_party/revcord/node_sqlite3.node" \
  "$USER@$HOST:/home/root/hwr/third_party/revcord/node_sqlite3.node"
if [[ -f "$ROOT/dist/rm2hwr-linux-armv7" ]]; then
  scp "$ROOT/dist/rm2hwr-linux-armv7" "$USER@$HOST:/home/root/hwr/bin/rm2hwr"
  ssh "$USER@$HOST" 'chmod 0755 /home/root/hwr/bin/rm2hwr'
fi
ssh "$USER@$HOST" 'chmod +x /home/root/hwr/scripts/*.sh; sh /home/root/hwr/scripts/install-node-jonobones.sh'
echo "==> next: edit hwr.env, jonobones init, rm2hwr --name …"
echo "    see docs/jonobones-rm2.md"