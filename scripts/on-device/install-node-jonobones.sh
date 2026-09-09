#!/bin/sh
# On-device installer: Node 20 armv7l + Revcord sqlite3 + jonobones.
# Run as root on reMarkable 2. BusyBox-friendly.
set -e

NODE_VER="${NODE_VER:-20.20.2}"
NODE_URL="${NODE_URL:-https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-armv7l.tar.xz}"
SQLITE_URL="${SQLITE_URL:-https://github.com/mayudev/revcord/releases/download/v1.2/node_sqlite3.node}"
OPT=/home/root/opt
NPM_PREFIX=/home/root/.npm-global
DOWNLOADS=/home/root/downloads
HWR=/home/root/hwr

echo "==> identity"
uname -m
test "$(uname -m)" = "armv7l" || { echo "not armv7l — abort"; exit 1; }
ls /lib/libc.so.6 2>/dev/null || true

mkdir -p "$OPT" "$NPM_PREFIX" "$DOWNLOADS" "$HWR/bin" "$HWR/conf" "$HWR/scripts" "$HWR/out"

if command -v node >/dev/null 2>&1 && node -p "process.versions.napi" >/dev/null 2>&1; then
  echo "==> node already present: $(node -v) arch=$(node -p process.arch)"
else
  echo "==> downloading Node $NODE_VER"
  cd "$DOWNLOADS"
  TARBALL="node-v${NODE_VER}-linux-armv7l.tar.xz"
  if [ ! -f "$TARBALL" ]; then
    wget -O "$TARBALL" "$NODE_URL" 2>/dev/null || curl -fsSL -o "$TARBALL" "$NODE_URL"
  fi
  tar -xJf "$TARBALL" -C "$OPT"
  ln -sfn "$OPT/node-v${NODE_VER}-linux-armv7l" "$OPT/node"
fi

export PATH="$NPM_PREFIX/bin:$OPT/node/bin:$PATH"
grep -q '/home/root/opt/node/bin' /home/root/.profile 2>/dev/null || \
  echo 'export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH' >> /home/root/.profile

npm config set prefix "$NPM_PREFIX"
node -p "process.arch+' napi='+process.versions.napi+' '+process.version"
node -e "require('fs'); console.log('core ok')"

echo "==> npm install jonobones (JS only)"
npm install -g jonobones --ignore-scripts --ignore-engines --no-fund --no-audit

echo "==> fetch Revcord sqlite3 binary"
cd "$DOWNLOADS"
if [ ! -f node_sqlite3.node ]; then
  wget -O node_sqlite3.node "$SQLITE_URL" 2>/dev/null || curl -fsSL -o node_sqlite3.node "$SQLITE_URL"
fi

echo "==> install binding into every sqlite3 tree"
find "$NPM_PREFIX" -type d -path '*/node_modules/sqlite3' 2>/dev/null | while read ROOT; do
  mkdir -p "$ROOT/lib/binding/napi-v6-linux-glibc-arm"
  cp "$DOWNLOADS/node_sqlite3.node" "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
  chmod 755 "$ROOT/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node"
  echo "patched $ROOT"
done

SQLITE3="$(find "$NPM_PREFIX" -type d -path '*/jonobones/node_modules/sqlite3' 2>/dev/null | head -n 1)"
echo "==> smoke-test $SQLITE3"
node -e "const s=require('$SQLITE3'); console.log('VERSION', s.VERSION); console.log('ok')"

echo "==> optional @joplin/lib 3.7.1 for Joplin Cloud"
if [ "${BUMP_JOPLIN_LIB:-1}" = "1" ]; then
  JB="$(npm root -g)/jonobones"
  (cd "$JB" && npm install @joplin/lib@3.7.1 --ignore-scripts --ignore-engines --no-fund --no-audit) || true
  # re-patch sqlite after npm may nest another copy
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

echo "==> done. Next: jonobones init (interactive), then start:"
echo "  export PATH=$NPM_PREFIX/bin:$OPT/node/bin:\$PATH"
echo "  jonobones init"
echo "  nohup jonobones start > /tmp/jonobones-start.log 2>&1 &"
