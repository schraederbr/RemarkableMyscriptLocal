#!/bin/sh
# On-device installer: Node 20 armv7l + jonobones (+ Revcord sqlite3).
# Prefers offline release tarball when present; otherwise npm (needs Wi-Fi).
# Run as root on reMarkable 2. BusyBox-friendly.
# Updates /tmp/rm2-install.status (phase=...) when the host nohup job is running.
set -e

STATUS="${STATUS:-/tmp/rm2-install.status}"
rm2_phase() {
  printf 'phase=%s\n' "$1" > "$STATUS"
}

NODE_VER="${NODE_VER:-20.20.2}"
NODE_URL="${NODE_URL:-https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-armv7l.tar.xz}"
SQLITE_URL="${SQLITE_URL:-https://github.com/mayudev/revcord/releases/download/v1.2/node_sqlite3.node}"
OPT=/home/root/opt
NPM_PREFIX=/home/root/.npm-global
DOWNLOADS=/home/root/downloads
HWR=/home/root/hwr
LIB_DIR=$HWR/lib
USED_OFFLINE=0

export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "==> identity"
uname -m
test "$(uname -m)" = "armv7l" || { echo "not armv7l — abort"; exit 1; }

mkdir -p "$OPT" "$NPM_PREFIX" "$DOWNLOADS" "$HWR/bin" "$HWR/conf" "$HWR/scripts" "$HWR/out"

rm2_phase node
if command -v node >/dev/null 2>&1 && node -p "process.versions.napi" >/dev/null 2>&1; then
  echo "==> node already present: $(node -v) arch=$(node -p process.arch)"
else
  echo "==> installing Node $NODE_VER"
  cd "$DOWNLOADS"
  TARBALL="node-v${NODE_VER}-linux-armv7l.tar.xz"
  if [ ! -f "$TARBALL" ]; then
    if command -v wget >/dev/null 2>&1; then
      wget -O "$TARBALL" "$NODE_URL"
    elif command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$TARBALL" "$NODE_URL"
    else
      echo "ERROR: missing $DOWNLOADS/$TARBALL and no wget/curl"
      exit 1
    fi
  fi
  tar -xJf "$TARBALL" -C "$OPT"
  ln -sfn "$OPT/node-v${NODE_VER}-linux-armv7l" "$OPT/node"
fi

export PATH="$NPM_PREFIX/bin:$OPT/node/bin:$PATH"
grep -q '/home/root/opt/node/bin' /home/root/.profile 2>/dev/null || \
  echo 'export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH' >> /home/root/.profile
grep -q '/home/root/hwr/lib' /home/root/.profile 2>/dev/null || \
  echo 'export LD_LIBRARY_PATH=/home/root/hwr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}' >> /home/root/.profile

npm config set prefix "$NPM_PREFIX"
node -p "process.arch+' napi='+process.versions.napi+' '+process.version"

OFFLINE_TGZ=""
for f in "$DOWNLOADS"/jonobones-rm2-npm-offline-*.tar.gz \
         "$HWR/third_party"/jonobones-rm2-npm-offline-*.tar.gz; do
  if [ -f "$f" ]; then OFFLINE_TGZ="$f"; break; fi
done

if [ -n "$OFFLINE_TGZ" ]; then
  echo "==> install jonobones from offline tarball: $OFFLINE_TGZ"
  rm2_phase jonobones-offline
  rm -rf "$NPM_PREFIX"
  mkdir -p "$NPM_PREFIX"
  TMP_OFF=/tmp/jonobones-offline-extract
  rm -rf "$TMP_OFF"
  mkdir -p "$TMP_OFF"
  # BusyBox tar often lacks -z; gunzip pipe is portable
  if tar -tzf "$OFFLINE_TGZ" >/dev/null 2>&1; then
    tar -xzf "$OFFLINE_TGZ" -C "$TMP_OFF"
  else
    gzip -dc "$OFFLINE_TGZ" | tar -x -C "$TMP_OFF"
  fi
  if [ ! -d "$TMP_OFF/npm-global" ]; then
    echo "ERROR: offline tarball missing npm-global/"
    exit 1
  fi
  cp -a "$TMP_OFF/npm-global/." "$NPM_PREFIX/"
  chmod 755 "$NPM_PREFIX/bin/jonobones" 2>/dev/null || true
  rm -rf "$TMP_OFF"
  USED_OFFLINE=1
  echo "offline jonobones tree installed"
else
  echo "==> npm install jonobones (needs Wi-Fi/internet)"
  rm2_phase jonobones-npm
  npm install -g jonobones --ignore-scripts --ignore-engines --no-fund --no-audit
fi

echo "==> ensure Revcord sqlite3 binary"
rm2_phase sqlite
cd "$DOWNLOADS"
if [ -f /home/root/hwr/third_party/revcord/node_sqlite3.node ]; then
  cp /home/root/hwr/third_party/revcord/node_sqlite3.node "$DOWNLOADS/node_sqlite3.node"
elif [ ! -f node_sqlite3.node ]; then
  if command -v wget >/dev/null 2>&1; then
    wget -O node_sqlite3.node "$SQLITE_URL"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o node_sqlite3.node "$SQLITE_URL"
  else
    echo "ERROR: no node_sqlite3.node and no wget/curl"
    exit 1
  fi
fi

find "$NPM_PREFIX" -type d -path '*/node_modules/sqlite3' 2>/dev/null | while read ROOT; do
  mkdir -p "$ROOT/lib/binding/napi-v6-linux-glibc-arm"
  cp "$DOWNLOADS/node_sqlite3.node" "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
  chmod 755 "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
  echo "patched $ROOT"
done

SQLITE3="$(find "$NPM_PREFIX" -type d -path '*/jonobones/node_modules/sqlite3' 2>/dev/null | head -n 1)"
echo "==> smoke-test $SQLITE3"
node -e "const s=require('$SQLITE3'); console.log('VERSION', s.VERSION); console.log('ok')"

if [ "$USED_OFFLINE" = "1" ]; then
  echo "==> offline bundle already includes @joplin/lib 3.7.1 + bootstrap patch"
else
  echo "==> optional @joplin/lib 3.7.1 for Joplin Cloud"
  if [ "${BUMP_JOPLIN_LIB:-1}" = "1" ]; then
    rm2_phase joplin-lib
    JB="$(npm root -g)/jonobones"
    (cd "$JB" && npm install @joplin/lib@3.7.1 --ignore-scripts --ignore-engines --no-fund --no-audit) || true
    find "$NPM_PREFIX" -type d -path '*/node_modules/sqlite3' 2>/dev/null | while read ROOT; do
      mkdir -p "$ROOT/lib/binding/napi-v6-linux-glibc-arm"
      cp "$DOWNLOADS/node_sqlite3.node" "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
      chmod 755 "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
    done
    BOOT="$JB/dist/joplin/bootstrap.js"
    if [ -f "$BOOT" ]; then
      cp -a "$BOOT" "$BOOT.bak-pre37" 2>/dev/null || true
      sed -i \
        -e "s|req('@joplin/lib/SyncTargetNextcloud.js');|req('@joplin/lib/SyncTargetNextcloud.js').default;|" \
        -e "s|req('@joplin/lib/SyncTargetWebDAV.js');|req('@joplin/lib/SyncTargetWebDAV.js').default;|" \
        -e "s|req('@joplin/lib/SyncTargetDropbox.js');|req('@joplin/lib/SyncTargetDropbox.js').default;|" \
        "$BOOT"
      echo "patched bootstrap SyncTarget .default imports"
    fi
  fi
fi

echo "==> done. Next: jonobones init, then start"
echo "  export PATH=$NPM_PREFIX/bin:$OPT/node/bin:\$PATH"
