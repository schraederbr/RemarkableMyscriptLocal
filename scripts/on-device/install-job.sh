#!/bin/sh
# Full on-device install job for: nohup sh /home/root/hwr/scripts/install-job.sh &
set -e
LOG=/tmp/rm2-install.log
STATUS=/tmp/rm2-install.status
HWR=/home/root/hwr
META=$HWR/conf/install.meta

echo "==== rm2 install job start $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$ ====" | tee -a "$LOG"
echo running > "$STATUS"
exec >>"$LOG" 2>&1

export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
mkdir -p "$HWR/conf" "$HWR/bin" "$HWR/scripts" "$HWR/out" "$HWR/third_party/revcord"
chmod +x "$HWR/scripts/"*.sh 2>/dev/null || true

START_JONOBONES=1
SKIP_JONOBONES_INIT=0
if [ -f "$META" ]; then
  # shellcheck disable=SC1090
  . "$META"
fi

echo "==> Node + jonobones + sqlite drop-in"
sh "$HWR/scripts/install-node-jonobones.sh"

echo "==> jonobones init"
sh "$HWR/scripts/jonobones-init-cloud.sh" || {
  echo "jonobones init failed — see log"
  echo fail > "$STATUS"
  exit 1
}

if [ "${START_JONOBONES:-1}" = "1" ]; then
  echo "==> start jonobones"
  jonobones stop 2>/dev/null || true
  if command -v nohup >/dev/null 2>&1; then
    nohup jonobones start > /tmp/jonobones-start.log 2>&1 &
  else
    jonobones start > /tmp/jonobones-start.log 2>&1 &
  fi
  sleep 3
  jonobones status || true
fi

echo ok > "$STATUS"
echo "==== rm2 install job done $(date -u +%Y-%m-%dT%H:%M:%SZ) ===="