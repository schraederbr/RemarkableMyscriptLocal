#!/usr/bin/env bash
# One-liner Linux/macOS bootstrap: download RemarkableMyscriptLocal release + assets,
# then run install-rm2-stack.sh --skip-build.
#
# Intended for:
#   curl -fsSL https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.8/scripts/install-from-web.sh | bash
#
# Defaults (override via env):
#   RELEASE_TAG / RM2_RELEASE_TAG = v0.3.8
#   HOST                           = 10.11.99.1
set -euo pipefail

RELEASE_TAG="${RELEASE_TAG:-${RM2_RELEASE_TAG:-v0.3.8}}"
HOST="${HOST:-10.11.99.1}"
REPO_OWNER="schraederbr"
REPO_NAME="RemarkableMyscriptLocal"
RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}"
ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${RELEASE_TAG}.zip"

OFFLINE_NAME="jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz"
NODE_TAR_NAME="node-v20.20.2-linux-armv7l.tar.xz"
BINARY_NAME="rm2hwr-linux-armv7"
SQLITE_NAME="node_sqlite3.node"
LIBATOMIC_NAME="libatomic.so.1"

info() { printf '==> %s\n' "$*"; }
ok() { printf 'OK  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }

echo
echo "============================================================"
echo " RemarkableMyscriptLocal one-liner install (${RELEASE_TAG})"
echo "============================================================"
echo
echo "Have these ready BEFORE continuing:"
echo "  1) USB cable to the reMarkable 2 (default host ${HOST})"
echo "     Or set env HOST=<tablet-wifi-ip> before running."
echo "  2) reMarkable SSH password (Settings -> Help -> Copyrights and licenses)"
echo "  3) Joplin upload mode choice: SVG only / handwriting text / both"
echo "  4) MyScript APP_KEY (HMAC optional) - only if you want handwriting text (text or both)"
echo "  5) Joplin Cloud email + password"
echo "  6) Tablet Wi-Fi ON with internet (Joplin Cloud; MyScript only if text/HWR)"
echo
echo "This script downloads release source + assets over HTTPS,"
echo "then runs install-rm2-stack.sh --skip-build so Go is not required."
echo
echo "If SSH fails, the stack installer prompts to enable USB, enter a Wi-Fi IP / change HOST, re-enter the SSH password, or abort."
echo "Works on Linux and macOS (bash + curl/wget + ssh/scp)."
echo

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: need '$1' on PATH" >&2; exit 1; }
}
need_cmd unzip
need_cmd ssh
need_cmd scp
if command -v curl >/dev/null 2>&1; then
  DL=curl
elif command -v wget >/dev/null 2>&1; then
  DL=wget
else
  echo "ERROR: need curl or wget" >&2
  exit 1
fi

download() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  info "Downloading $url"
  if [[ "$DL" == curl ]]; then
    curl -fsSL -o "$out" "$url"
  else
    wget -q -O "$out" "$url"
  fi
  local sz
  sz=$(wc -c <"$out" | tr -d ' ')
  if [[ -z "$sz" || "$sz" -lt 100 ]]; then
    echo "ERROR: download failed or too small: $out" >&2
    exit 1
  fi
  ok "Saved $out ($sz bytes)"
}

DEST_ROOT="${HOME}/RemarkableMyscriptLocal-${RELEASE_TAG}"
ZIP_PATH="${TMPDIR:-/tmp}/RemarkableMyscriptLocal-${RELEASE_TAG}.zip"
EXTRACT_PARENT="${TMPDIR:-/tmp}/RemarkableMyscriptLocal-extract-${RELEASE_TAG}"

info "Fetching source zip for ${RELEASE_TAG}"
rm -rf "$EXTRACT_PARENT"
mkdir -p "$EXTRACT_PARENT"
download "$ZIP_URL" "$ZIP_PATH"

info "Expanding source to $DEST_ROOT"
rm -rf "$DEST_ROOT"
unzip -q "$ZIP_PATH" -d "$EXTRACT_PARENT"
INNER=$(find "$EXTRACT_PARENT" -mindepth 1 -maxdepth 1 -type d | head -n1)
if [[ -z "$INNER" ]]; then
  echo "ERROR: zip expand produced no directory under $EXTRACT_PARENT" >&2
  exit 1
fi
mv "$INNER" "$DEST_ROOT"
ok "Source ready at $DEST_ROOT"

DIST_DIR="$DEST_ROOT/dist"
REVCORD_DIR="$DEST_ROOT/third_party/revcord"
mkdir -p "$DIST_DIR" "$REVCORD_DIR"

download_asset() {
  local name="$1" minsize="$2"
  local out="$DIST_DIR/$name"
  download "${RELEASE_BASE}/${name}" "$out"
  local sz
  sz=$(wc -c <"$out" | tr -d ' ')
  if [[ "$sz" -lt "$minsize" ]]; then
    echo "ERROR: asset too small: $out (expected >= $minsize)" >&2
    exit 1
  fi
}

download_asset "$BINARY_NAME" 100000
download_asset "$OFFLINE_NAME" 1000000
download_asset "$NODE_TAR_NAME" 1000000
download_asset "$SQLITE_NAME" 100000
download_asset "$LIBATOMIC_NAME" 10000
cp -f "$DIST_DIR/$SQLITE_NAME" "$REVCORD_DIR/$SQLITE_NAME"
ok "Copied $SQLITE_NAME into third_party/revcord"

export RM2_RELEASE_TAG="$RELEASE_TAG"
export HOST

INSTALL_SH="$DEST_ROOT/scripts/install-rm2-stack.sh"
if [[ ! -f "$INSTALL_SH" ]]; then
  echo "ERROR: missing installer after extract: $INSTALL_SH" >&2
  exit 1
fi
chmod +x "$INSTALL_SH" "$DEST_ROOT/scripts/"*.sh 2>/dev/null || true

info "Launching install-rm2-stack.sh --skip-build (Go not required)"
echo "  Repo: $DEST_ROOT"
echo "  Host: $HOST"
echo

bash "$INSTALL_SH" --repo-root "$DEST_ROOT" --host "$HOST" --skip-build
ok "One-liner install finished"
