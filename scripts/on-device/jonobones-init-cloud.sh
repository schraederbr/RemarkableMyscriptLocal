#!/bin/sh
# Non-interactive jonobones init. Prefers a host-built answers file so passwords
# never need to be sourced by the shell.
set -e
export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
HWR=/home/root/hwr
ANSWERS="${JONOBONES_INIT_ANSWERS:-$HWR/conf/jonobones-init-answers.txt}"
PROFILE_DIR="${JONOBONES_PROFILE:-/home/root/.config/jonobones/default}"
CONFIG="$PROFILE_DIR/config.json5"
META="$HWR/conf/install.meta"

SKIP=0
if [ -f "$META" ]; then
  # Windows hosts may write CRLF; strip before sourcing
  META_CLEAN=/tmp/rm2-install.meta.clean
  tr -d '\r' < "$META" > "$META_CLEAN"
  # shellcheck disable=SC1090
  . "$META_CLEAN"
fi
SKIP="${SKIP_JONOBONES_INIT:-$SKIP}"

if [ "$SKIP" = "1" ]; then
  echo "SKIP_JONOBONES_INIT=1 — leaving jonobones config alone"
  exit 0
fi

if [ ! -s "$ANSWERS" ]; then
  echo "ERROR: missing answers file $ANSWERS (host installer should write it)"
  exit 1
fi

# Strip CRLF from Windows-written answers (jonobones reads line-oriented)
ANSWERS_CLEAN=/tmp/jonobones-init-answers.clean
tr -d '\r' < "$ANSWERS" > "$ANSWERS_CLEAN"

echo "==> jonobones init (scripted answers from $ANSWERS)"
jonobones stop 2>/dev/null || true
jonobones init < "$ANSWERS_CLEAN"
rm -f "$ANSWERS_CLEAN"

if [ -f "$CONFIG" ]; then
  TOKEN=$(node -e "const fs=require('fs');const t=fs.readFileSync(process.argv[1],'utf8');const m=t.match(/\"token\"\\s*:\\s*\"([^\"]+)\"/);if(!m)process.exit(2);process.stdout.write(m[1])" "$CONFIG")
  umask 077
  cat > "$HWR/conf/jonobones.env" <<EOF
JONOBONES_URL=http://127.0.0.1:26637/v1
JONOBONES_TOKEN=$TOKEN
JONOBONES_PROFILE=$PROFILE_DIR
EOF
  chmod 0600 "$HWR/conf/jonobones.env"
  rm -f "$ANSWERS"
  echo "wrote $HWR/conf/jonobones.env ; removed answers file"
fi
echo "==> jonobones init finished"