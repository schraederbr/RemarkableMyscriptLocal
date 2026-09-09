#!/usr/bin/env bash
# Linux/macOS host helper. For full credential collection prefer the PowerShell
# installer on Windows, or export the same env vars and use conf/install.secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-10.11.99.1}"
USER="${2:-root}"
echo "==> This bash helper deploys files and starts a nohup job."
echo "    Put credentials in $ROOT/conf/install.secrets first (see docs/install-checklist.md)."
if [[ ! -f "$ROOT/conf/install.secrets" || ! -f "$ROOT/conf/hwr.env" ]]; then
  echo "ERROR: create conf/install.secrets and conf/hwr.env first (or run scripts/install-rm2-stack.ps1)."
  exit 1
fi
ssh "$USER@$HOST" 'mkdir -p /home/root/hwr/scripts /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/out /home/root/hwr/third_party/revcord /home/root/downloads'
scp "$ROOT/scripts/on-device/install-node-jonobones.sh" \
    "$ROOT/scripts/on-device/jonobones-init-cloud.sh" \
    "$ROOT/scripts/on-device/install-job.sh" \
    "$ROOT/scripts/joplin-upsert.js" \
    "$USER@$HOST:/home/root/hwr/scripts/"
scp "$ROOT/third_party/revcord/node_sqlite3.node" "$USER@$HOST:/home/root/hwr/third_party/revcord/node_sqlite3.node"
scp "$ROOT/conf/hwr.env" "$USER@$HOST:/home/root/hwr/conf/hwr.env"
# answers must be prepared (PowerShell does this); optional here
if [[ -f "$ROOT/conf/jonobones-init-answers.txt" ]]; then
  scp "$ROOT/conf/jonobones-init-answers.txt" "$USER@$HOST:/home/root/hwr/conf/jonobones-init-answers.txt"
fi
printf 'SKIP_JONOBONES_INIT=0\nSTART_JONOBONES=1\n' | ssh "$USER@$HOST" 'cat > /home/root/hwr/conf/install.meta'
if [[ -f "$ROOT/dist/rm2hwr-linux-armv7" ]]; then
  scp "$ROOT/dist/rm2hwr-linux-armv7" "$USER@$HOST:/home/root/hwr/bin/rm2hwr"
  ssh "$USER@$HOST" 'chmod 0755 /home/root/hwr/bin/rm2hwr'
fi
ssh "$USER@$HOST" 'chmod +x /home/root/hwr/scripts/*.sh; chmod 0600 /home/root/hwr/conf/hwr.env; rm -f /tmp/rm2-install.status; nohup sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.nohup.out 2>&1 & echo started'
echo "==> Job running on tablet. Poll: ssh $USER@$HOST 'cat /tmp/rm2-install.status; tail -n 20 /tmp/rm2-install.log'"