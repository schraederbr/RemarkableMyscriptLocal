#!/bin/sh
# Full on-device install job for: nohup sh /home/root/hwr/scripts/install-job.sh &
# Writes /tmp/rm2-install.status as phase=<name> for host heartbeat polling.
set -e
LOG=/tmp/rm2-install.log
STATUS=/tmp/rm2-install.status
HWR=/home/root/hwr
META=$HWR/conf/install.meta

rm2_phase() {
  printf 'phase=%s\n' "$1" > "$STATUS"
}

on_exit() {
  ec=$?
  if [ "$ec" -ne 0 ]; then
    rm2_phase fail
  fi
}
trap on_exit EXIT

echo "==== rm2 install job start $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$ ====" | tee -a "$LOG"
rm2_phase starting
exec >>"$LOG" 2>&1

export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
mkdir -p "$HWR/conf" "$HWR/bin" "$HWR/scripts" "$HWR/out" "$HWR/state" "$HWR/third_party/revcord"
chmod +x "$HWR/scripts/"*.sh 2>/dev/null || true

START_JONOBONES=1
SKIP_JONOBONES_INIT=0
if [ -f "$META" ]; then
  # Windows hosts may write CRLF; strip before sourcing and rewrite clean
  META_CLEAN=/tmp/rm2-install.meta.clean
  tr -d '\r' < "$META" > "$META_CLEAN"
  mv "$META_CLEAN" "$META"
  # shellcheck disable=SC1090
  . "$META"
fi

echo "==> Node + jonobones + sqlite drop-in"
rm2_phase install-node
sh "$HWR/scripts/install-node-jonobones.sh"

echo "==> jonobones init"
rm2_phase jonobones-init
sh "$HWR/scripts/jonobones-init-cloud.sh" || {
  echo "jonobones init failed — see log"
  rm2_phase fail
  exit 1
}

if [ "${START_JONOBONES:-1}" = "1" ]; then
  echo "==> start jonobones"
  rm2_phase start-jonobones
  jonobones stop 2>/dev/null || true
  if command -v nohup >/dev/null 2>&1; then
    nohup jonobones start > /tmp/jonobones-start.log 2>&1 &
  else
    jonobones start > /tmp/jonobones-start.log 2>&1 &
  fi
  sleep 3
  jonobones status || true
fi

rm2_phase ok
trap - EXIT
echo "==== rm2 install job done $(date -u +%Y-%m-%dT%H:%M:%SZ) ===="
