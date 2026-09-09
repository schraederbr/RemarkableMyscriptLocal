#!/usr/bin/env bash
# Linux/macOS host helper. For full credential collection prefer the PowerShell
# installer on Windows, or export the same env vars and use conf/install.secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-10.11.99.1}"
USER="${2:-root}"
if [[ -z "${RM_SSH_PASSWORD:-}" && -f "$ROOT/conf/install.secrets" ]]; then
  # shellcheck disable=SC1091
  RM_SSH_PASSWORD="$(grep -E '^SSH_PASSWORD=' "$ROOT/conf/install.secrets" | head -n1 | cut -d= -f2- || true)"
  export RM_SSH_PASSWORD
fi
if [[ -n "${RM_SSH_PASSWORD:-}" ]]; then
  "$ROOT/scripts/ensure-rm-ssh-key.sh" "$USER@$HOST"
else
  echo "==> RM_SSH_PASSWORD not set — assuming SSH key auth already works"
fi
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
ssh "$USER@$HOST" 'chmod +x /home/root/hwr/scripts/*.sh; chmod 0600 /home/root/hwr/conf/hwr.env; rm -f /tmp/rm2-install.status; : > /tmp/rm2-install.log; nohup sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.nohup.out 2>&1 & echo started'

echo "==> Job running on tablet. Heartbeat every ~60s (Ctrl+C here is safe — job keeps running)."
deadline=$((SECONDS + 6*3600))
last_hb=0
phase=pending
while (( SECONDS < deadline )); do
  sleep 5
  st=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$USER@$HOST" 'cat /tmp/rm2-install.status 2>/dev/null || echo phase=pending' || true)
  if [[ -z "$st" ]]; then
    echo "!!  SSH blip while polling — retrying (on-device job still running)"
    continue
  fi
  if [[ "$st" == phase=* ]]; then
    phase="${st#phase=}"
    phase="${phase%%$'\n'*}"
  elif [[ "$st" == ok || "$st" == fail || "$st" == running || "$st" == pending ]]; then
    phase="$st"
  else
    phase=$(printf '%s\n' "$st" | sed -n 's/^phase=//p' | head -n1)
    [[ -n "$phase" ]] || phase="$st"
  fi
  if [[ "$phase" == "ok" ]]; then
    echo "OK  On-device job finished successfully"
    break
  fi
  if [[ "$phase" == "fail" ]]; then
    echo "!!  On-device job failed — last log lines:"
    ssh "$USER@$HOST" 'tail -n 40 /tmp/rm2-install.log' || true
    exit 1
  fi
  now=$SECONDS
  if (( now - last_hb >= 60 )); then
    last_hb=$now
    elapsed=$now
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    snap=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$USER@$HOST" 'phase=$(sed -n "s/^phase=//p" /tmp/rm2-install.status 2>/dev/null | head -n1); [ -n "$phase" ] || phase=pending; du_k=$(du -sk /home/root/.config/jonobones 2>/dev/null | awk "{print \$1}"); [ -n "$du_k" ] || du_k=0; free_k=$(df -k /home 2>/dev/null | tail -n1 | awk "{print \$4}"); [ -n "$free_k" ] || free_k=?; echo "PHASE=$phase"; echo "DU_K=$du_k"; echo "FREE_K=$free_k"; echo "----LOG----"; tail -n 12 /tmp/rm2-install.log 2>/dev/null || true' || true)
    hb_phase=$(printf '%s\n' "$snap" | sed -n 's/^PHASE=//p' | head -n1)
    du_k=$(printf '%s\n' "$snap" | sed -n 's/^DU_K=//p' | head -n1)
    free_k=$(printf '%s\n' "$snap" | sed -n 's/^FREE_K=//p' | head -n1)
    [[ -n "$hb_phase" ]] || hb_phase="$phase"
    [[ -n "$du_k" ]] || du_k=0
    [[ -n "$free_k" ]] || free_k=?
    if [[ "$du_k" =~ ^[0-9]+$ ]]; then
      du_m=$(awk -v k="$du_k" 'BEGIN{printf "%.1fM", k/1024}')
    else
      du_m="$du_k"
    fi
    if [[ "$free_k" =~ ^[0-9]+$ ]]; then
      free_m=$(awk -v k="$free_k" 'BEGIN{printf "%.1fM", k/1024}')
    else
      free_m="$free_k"
    fi
    printf '\n-- heartbeat  phase=%s  elapsed=%dm%02ds  jonobones=%s  /home free=%s\n' \
      "$hb_phase" "$mins" "$secs" "$du_m" "$free_m"
    printf '%s\n' "$snap" | awk 'f{print "   | "$0} /^----LOG----$/{f=1}'
  fi
done
if [[ "$phase" != "ok" ]]; then
  echo "ERROR: timed out waiting for install-job"
  exit 1
fi
echo "Logs on tablet: /tmp/rm2-install.log  /tmp/jonobones-start.log"
