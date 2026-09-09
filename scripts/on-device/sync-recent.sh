#!/bin/sh
# Periodic HWR → Joplin sync for DocumentType notebooks touched in the last 30 days.
# BusyBox-safe outer shell; uses node (on tablet) for JSON + hashing.
#
# State sidecars (written only after successful upsert):
#   /home/root/hwr/state/<doc-uuid>.json
#   { lastUploadedAt, joplinNoteId?, pages: [{pageUuid, sha256, mtime}] }
#
# Systemd timer (host installer): every SYNC_INTERVAL_HOURS hours (default 6).
# Units: hwr-sync-recent.service + hwr-sync-recent.timer under /etc/systemd/system/.
# Change: set SYNC_INTERVAL_HOURS in hwr.env and re-run installer, or edit the timer.
# Disable: SYNC_INTERVAL_HOURS=0 + re-run installer, or systemctl disable --now hwr-sync-recent.timer.

set -e

HWR="${HWR_ROOT:-/home/root/hwr}"
XOCHITL="${XOCHITL_DIR:-/home/root/.local/share/remarkable/xochitl}"
STATE_DIR="$HWR/state"
BIN="$HWR/bin/rm2hwr"
UPSERT="$HWR/scripts/joplin-upsert.js"
ENV_FILE="$HWR/conf/hwr.env"
LOG="${SYNC_RECENT_LOG:-/tmp/hwr-sync-recent.log}"
DAYS="${SYNC_RECENT_DAYS:-30}"

export PATH="/home/root/.npm-global/bin:/home/root/opt/node/bin:/home/root/hwr/bin:$PATH"

mkdir -p "$STATE_DIR"

if [ -f "$ENV_FILE" ]; then
  ENV_CLEAN="/tmp/hwr-sync-env.$$"
  tr -d '\r' < "$ENV_FILE" > "$ENV_CLEAN"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_CLEAN"
  set +a
  rm -f "$ENV_CLEAN"
fi

UPLOAD_MODE="${UPLOAD_MODE:-both}"
export UPLOAD_MODE

if [ -f "$HWR/conf/jonobones.env" ]; then
  JB_CLEAN="/tmp/hwr-jb-env.$$"
  tr -d '\r' < "$HWR/conf/jonobones.env" > "$JB_CLEAN"
  set -a
  # shellcheck disable=SC1090
  . "$JB_CLEAN"
  set +a
  rm -f "$JB_CLEAN"
fi

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"
}

if ! command -v node >/dev/null 2>&1; then
  log "ERROR: node not in PATH"
  exit 1
fi
if [ ! -x "$BIN" ]; then
  log "ERROR: missing $BIN"
  exit 1
fi
if [ ! -f "$UPSERT" ]; then
  log "ERROR: missing $UPSERT"
  exit 1
fi
if [ ! -d "$XOCHITL" ]; then
  log "ERROR: xochitl dir missing: $XOCHITL"
  exit 1
fi

log "sync-recent start days=$DAYS upload_mode=$UPLOAD_MODE"

PLAN="/tmp/hwr-sync-plan.$$"
XOCHITL="$XOCHITL" STATE_DIR="$STATE_DIR" DAYS="$DAYS" node << 'NODE' > "$PLAN"
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const xochitl = process.env.XOCHITL;
const stateDir = process.env.STATE_DIR;
const days = parseInt(process.env.DAYS, 10) || 30;
const cutoff = Date.now() - days * 86400000;

function sha256File(p) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(p));
  return h.digest('hex');
}

function loadJSON(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (_) { return null; }
}

function lastModifiedMs(meta) {
  const candidates = [meta.lastModified, meta.lastOpened, meta.created];
  for (const c of candidates) {
    if (c == null || c === '') continue;
    const n = typeof c === 'number' ? c : parseInt(String(c), 10);
    if (!isNaN(n) && n > 0) return n;
  }
  return 0;
}

function pageSnapshot(docUuid, pages) {
  const out = [];
  for (const pageUuid of pages || []) {
    const rm = path.join(xochitl, docUuid, pageUuid + '.rm');
    if (!fs.existsSync(rm)) continue;
    const st = fs.statSync(rm);
    out.push({
      pageUuid,
      sha256: sha256File(rm),
      mtime: Math.floor(st.mtimeMs),
    });
  }
  return out;
}

function pagesMatch(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  const byId = new Map(b.map((p) => [p.pageUuid, p]));
  for (const p of a) {
    const o = byId.get(p.pageUuid);
    if (!o || o.sha256 !== p.sha256 || Number(o.mtime) !== Number(p.mtime)) return false;
  }
  return true;
}

for (const name of fs.readdirSync(xochitl)) {
  if (!name.endsWith('.metadata')) continue;
  const id = name.slice(0, -'.metadata'.length);
  const meta = loadJSON(path.join(xochitl, id + '.metadata'));
  if (!meta || meta.deleted || meta.type !== 'DocumentType') continue;
  const lm = lastModifiedMs(meta);
  if (lm && lm < cutoff) continue;
  const content = loadJSON(path.join(xochitl, id + '.content'));
  if (!content) continue;
  if (content.fileType && content.fileType !== 'notebook' && !(content.pages && content.pages.length)) continue;

  const pages = pageSnapshot(id, content.pages || []);
  const statePath = path.join(stateDir, id + '.json');
  let skip = false;
  if (fs.existsSync(statePath)) {
    const st = loadJSON(statePath);
    if (st && pagesMatch(pages, st.pages || [])) skip = true;
  }
  fs.writeFileSync(path.join(stateDir, id + '.pending.json'), JSON.stringify({ pages }, null, 2));
  console.log((skip ? 'SKIP' : 'RUN') + ' ' + id);
}
NODE

ran=0
skipped=0
failed=0

while read -r action uuid; do
  [ -n "$action" ] || continue
  [ -n "$uuid" ] || continue
  if [ "$action" = "SKIP" ]; then
    log "skip $uuid (state match)"
    skipped=$((skipped + 1))
    rm -f "$STATE_DIR/$uuid.pending.json"
    continue
  fi
  [ "$action" = "RUN" ] || continue

  log "run $uuid"
  set +e
  "$BIN" --uuid "$uuid" --joplin-upsert --upload-mode "$UPLOAD_MODE" >>"$LOG" 2>&1
  ec=$?
  set -e
  if [ "$ec" -ne 0 ]; then
    log "FAIL rm2hwr $uuid exit=$ec"
    failed=$((failed + 1))
    rm -f "$STATE_DIR/$uuid.pending.json"
    continue
  fi

  note_id=$(tail -n 80 "$LOG" | sed -n 's/^NOTE_ID=//p' | tail -n1)
  PENDING="$STATE_DIR/$uuid.pending.json"
  if [ -f "$PENDING" ]; then
    NOTE_ID_CAP="$note_id" PENDING_PATH="$PENDING" STATE_PATH="$STATE_DIR/$uuid.json" node << 'NODE'
const fs = require('fs');
const pending = JSON.parse(fs.readFileSync(process.env.PENDING_PATH, 'utf8'));
const out = {
  lastUploadedAt: new Date().toISOString(),
  pages: pending.pages || [],
};
if (process.env.NOTE_ID_CAP) out.joplinNoteId = process.env.NOTE_ID_CAP;
fs.writeFileSync(process.env.STATE_PATH, JSON.stringify(out, null, 2) + '\n');
NODE
    rm -f "$PENDING"
  else
    log "warn: missing pending snapshot for $uuid"
  fi
  log "ok $uuid"
  ran=$((ran + 1))
done < "$PLAN"

rm -f "$PLAN"
log "sync-recent done ran=$ran skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
