#!/bin/sh
# Install pinned XOVI/AppLoad ARM32 archives already copied to the tablet.
# The host installer rebuilds the firmware-specific hashtable and activates XOVI.
set -eu

XOVI_ARCHIVE=${1:-/tmp/xovi-arm32.tar.gz}
APPLOAD_ARCHIVE=${2:-/tmp/appload-arm32.zip}
SHORTCUT_DIR=${3:-/tmp/appload-sync-joplin}
ICON_FILE=${4:-/tmp/appload-sync-icon.png}

XOVI_SHA256=9aa00537ad41e9be0c3151992bfc25106465318cf5bb4c41cf59b3ddd4866377
APPLOAD_SHA256=dd68c6816c121934da78f59eb497c215e5a9729200de0a8a5bcbeaa5d0aa068b
ICON_SHA256=5fb6481e24bfaac1668bd28b921c5413b4cd0fec0ba8ce4e27dc52610837faab

fail() {
  echo "install-appload: ERROR: $*" >&2
  exit 1
}

verify_file() {
  file=$1
  expected=$2
  [ -f "$file" ] || fail "missing $file"
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $file"
}

[ "$(uname -m)" = "armv7l" ] || fail "AppLoad option currently supports reMarkable 1/2 ARM32 only"
firmware=$(sed -n 's/^REMARKABLE_RELEASE_VERSION=//p' /usr/share/remarkable/update.conf 2>/dev/null | head -n1)
case "$firmware" in
  3.26.*|3.27.*) ;;
  *) fail "firmware $firmware is outside the supported AppLoad range (3.26.x-3.27.x)" ;;
esac

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v unzip >/dev/null 2>&1 || fail "unzip is required"
verify_file "$XOVI_ARCHIVE" "$XOVI_SHA256"
verify_file "$APPLOAD_ARCHIVE" "$APPLOAD_SHA256"
verify_file "$ICON_FILE" "$ICON_SHA256"
[ -f "$SHORTCUT_DIR/external.manifest.json" ] || fail "missing shortcut manifest"
[ -f "$SHORTCUT_DIR/sync-now.sh" ] || fail "missing shortcut script"

# If an older XOVI session is active, return to stock before replacing its files.
pid=$(pidof xochitl 2>/dev/null || true)
if [ -n "$pid" ] && tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -q '^LD_PRELOAD=/home/root/xovi/xovi.so$'; then
  [ -x /home/root/xovi/stock ] || fail "XOVI is active but stock recovery command is missing"
  /home/root/xovi/stock
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/home/root/appload-backups/$stamp
mkdir -p "$backup/xovi/extensions.d" "$backup/xovi/exthome/qt-resource-rebuilder" "$backup/xovi/exthome/appload" "$backup/shims"
for file in \
  /home/root/xovi/xovi.so \
  /home/root/xovi/extensions.d/qt-resource-rebuilder.so \
  /home/root/xovi/extensions.d/appload.so \
  /home/root/xovi/exthome/qt-resource-rebuilder/hashtab \
  /home/root/shims/qtfb-shim.so \
  /home/root/shims/qtfb-shim-32bit.so; do
  if [ -f "$file" ]; then
    rel=${file#/home/root/}
    mkdir -p "$backup/$(dirname "$rel")"
    cp -p "$file" "$backup/$rel"
  fi
done
if [ -d /home/root/xovi/exthome/appload/sync-joplin ]; then
  cp -a /home/root/xovi/exthome/appload/sync-joplin "$backup/xovi/exthome/appload/"
fi

stage=$(mktemp -d /tmp/install-appload.XXXXXX)
trap 'rm -rf "$stage"' 0 HUP INT TERM
mkdir -p "$stage/xovi" "$stage/appload"
tar -xzf "$XOVI_ARCHIVE" -C "$stage"
unzip -oq "$APPLOAD_ARCHIVE" -d "$stage/appload"
[ -f "$stage/xovi/xovi.so" ] || fail "XOVI archive is missing xovi.so"
[ -f "$stage/xovi/extensions.d/qt-resource-rebuilder.so" ] || fail "XOVI archive is missing qt-resource-rebuilder.so"
[ -f "$stage/appload/appload.so" ] || fail "AppLoad archive is missing appload.so"
[ -f "$stage/appload/shims/qtfb-shim.so" ] || fail "AppLoad archive is missing qtfb-shim.so"
[ -f "$stage/appload/shims/qtfb-shim-32bit.so" ] || fail "AppLoad archive is missing qtfb-shim-32bit.so"

mkdir -p /home/root/xovi /home/root/shims /home/root/xovi/exthome/appload/sync-joplin
cp -a "$stage/xovi/." /home/root/xovi/
cp "$stage/appload/appload.so" /home/root/xovi/extensions.d/appload.so
cp "$stage/appload/shims/qtfb-shim.so" "$stage/appload/shims/qtfb-shim-32bit.so" /home/root/shims/
cp "$SHORTCUT_DIR/external.manifest.json" "$SHORTCUT_DIR/sync-now.sh" /home/root/xovi/exthome/appload/sync-joplin/
cp "$ICON_FILE" /home/root/xovi/exthome/appload/sync-joplin/icon.png

chmod 0755 /home/root/xovi/start /home/root/xovi/stock /home/root/xovi/rebuild_hashtable /home/root/xovi/debug
chmod 0755 /home/root/xovi/exthome/appload/sync-joplin/sync-now.sh
chmod 0644 /home/root/xovi/extensions.d/appload.so /home/root/shims/qtfb-shim.so /home/root/shims/qtfb-shim-32bit.so
chmod 0644 /home/root/xovi/exthome/appload/sync-joplin/external.manifest.json /home/root/xovi/exthome/appload/sync-joplin/icon.png

echo "install-appload: files installed for firmware $firmware"
echo "install-appload: backup $backup"
echo "install-appload: next run /home/root/xovi/rebuild_hashtable, then /home/root/xovi/start"
