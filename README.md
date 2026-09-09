# RemarkableMyscriptLocal — handwriting → Joplin on reMarkable 2

Turn reMarkable 2 notebooks into **Joplin notes that sync with Joplin Cloud** (or WebDAV / Nextcloud / Joplin Server) **on the tablet itself**.

Pipeline:

1. **`rm2hwr`** (Go, on-device) reads xochitl `.rm` pages → MyScript HWR and/or content-fit SVGs → `NOTE.md` + `HANDOFF.json`
2. **`jonobones`** (on-device Joplin-compatible sync daemon) keeps a local Joplin vault and **syncs directly with your Joplin account**
3. **`joplin-upsert`** (or `rm2hwr --joplin-upsert`) creates/updates the note by **exact notebook title** (`visibleName`), **replacing** the marked HWR section (not forever-append), then jonobones syncs it upstream

You do **not** need desktop Joplin open for the sync path. The tablet talks to Joplin Cloud (or your sync target) through jonobones.

> **Wi-Fi required** for Joplin Cloud sync (and MyScript). Install can use the **offline npm Release asset** (no registry on the tablet). USB is fine for SSH/deploy.

Offline bundle docs: [docs/offline-npm-bundle.md](docs/offline-npm-bundle.md).

## Quick install

**One-liner** (Windows PC, USB `10.11.99.1` by default — no local clone or Go required):

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.0/scripts/install-from-web.ps1 | iex"
```

Downloads the `v0.3.0` source + release assets over HTTPS, then runs `install-rm2-stack.ps1 -SkipBuild`.

From a local clone (optional):

```powershell
cd RemarkableMyscriptLocal
powershell -NoProfile -File .\scripts\install-rm2-stack.ps1
```

Have ready (see [docs/install-checklist.md](docs/install-checklist.md)):

- **USB cable** (or set `HOST` to the tablet Wi-Fi IP)
- reMarkable SSH password (installer installs your PC SSH key once — no manual key setup)
- MyScript `APP_KEY` (optional `HMAC_KEY`) from [developer.myscript.com](https://developer.myscript.com/)
- Joplin Cloud email + password (or another sync target)
- Joplin upload mode: text / SVG / both (installer default: both)
- Periodic sync interval hours (installer default: **6**; `0` disables systemd timer)
- Joplin notebook for **NEW** notes: blank = auto (notebook with most notes); or exact title / 32-hex id
- Optional E2EE master password
- **Tablet on Wi-Fi with internet**

The installer collects credentials up front, deploys `rm2hwr` + Node/jonobones/sqlite, runs the long steps under `nohup` (survives dropped SSH), and scripted `jonobones init` + start.

## Day-to-day: HWR → Joplin

```bash
export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH

# recognize a notebook (title = visibleName, e.g. 9-8-26)
/home/root/hwr/bin/rm2hwr --name "9-8"

# push into local Joplin vault (jonobones must be running), then it syncs to Cloud
/home/root/hwr/bin/rm2hwr --name "9-8" --joplin-upsert

# or separately:
node /home/root/hwr/scripts/joplin-upsert.js /home/root/hwr/out/<doc-uuid>
jonobones sync
```

Matching rule: **exact title** = reMarkable `visibleName`. Existing Joplin note → **replace** `<!-- rm2hwr:begin -->`…`<!-- rm2hwr:end -->` block (preserves content outside); missing → create with markers under `JONOBONES_PARENT_ID` / `JONOBONES_PARENT_TITLE`, or (if unset) the notebook with the **most notes**.

Manual one-shot is above. **Automatic:** systemd timer `hwr-sync-recent.timer` runs `sync-recent.sh` every `SYNC_INTERVAL_HOURS` (default 6; RM2 has no crond): last-30-day notebooks, skip unchanged pages via state sidecars, else `rm2hwr --joplin-upsert`.

Handoff / replace markers / systemd timer: [docs/joplin-sync.md](docs/joplin-sync.md) · RM2 port notes: [docs/jonobones-rm2.md](docs/jonobones-rm2.md)

## What runs on the tablet

| Piece | Role |
|-------|------|
| `rm2hwr` | Parse `.rm` (v5 + v6 auto-detect), call MyScript, write `out/<uuid>/` |
| Node 20 + jonobones | Local Joplin vault + **direct sync** to Joplin Cloud/Server/WebDAV |
| Revcord `node_sqlite3.node` | ARMv7 sqlite binding (vendored in `third_party/revcord/`) |
| `joplin-upsert.js` | Title-match upsert into jonobones API (`127.0.0.1:26637`) |

### Device layout

```
/home/root/hwr/
  bin/rm2hwr
  conf/hwr.env              # MyScript keys + UPLOAD_MODE + SYNC_INTERVAL_HOURS (0600)
  conf/jonobones.env        # API token + optional JONOBONES_PARENT_ID/TITLE (written by installer)
  scripts/joplin-upsert.js
  scripts/sync-recent.sh    # systemd timer: recent notebooks → HWR → Joplin
  state/<doc-uuid>.json     # lastUploadedAt + per-page sha256/mtime
  out/<doc-uuid>/NOTE.md
  out/<doc-uuid>/HANDOFF.json
  out/<doc-uuid>/<page>.txt|.svg
/home/root/.config/jonobones/default/   # jonobones profile + synced vault
/etc/systemd/system/hwr-sync-recent.service
/etc/systemd/system/hwr-sync-recent.timer   # OnUnitActiveSec from SYNC_INTERVAL_HOURS
```

### MyScript `hwr.env`

Sign up / keys: [developer.myscript.com](https://developer.myscript.com/)

```
APP_KEY=          # required
HMAC_KEY=         # optional
LANG=en_US
CONTENT_TYPE=Text
API_URL=https://cloud.myscript.com/api/v4.0/iink/batch
UPLOAD_MODE=both  # text | svg | both (unset → text for old installs)
SYNC_INTERVAL_HOURS=6  # systemd timer for sync-recent.sh; 0 disables
```

HMAC: `secret = APP_KEY + HMAC_KEY` (concatenation; `HMAC_KEY` may be empty), then HMAC-SHA512 over the raw body; headers `applicationKey` + `hmac`.

## CLI (`rm2hwr`)

```
rm2hwr --all | --name SUBSTR | --uuid DOC
       [--page PAGE] [--dry-run] [--joplin-upsert]
       [--upload-mode text|svg|both]
       [--xochitl DIR] [--outdir DIR] [--env FILE]
```

| Flag | Default |
|------|---------|
| `--xochitl` | `/home/root/.local/share/remarkable/xochitl/` |
| `--outdir` | `/home/root/hwr/out/` |
| `--env` | `/home/root/hwr/conf/hwr.env` |
| `--dry-run` | write MyScript JSON only; skip HTTP |
| `--joplin-upsert` | after HWR, upsert into jonobones by title |

Pages with a `.txt` newer than the `.rm` are skipped. Never writes into `.rm` / `.content` / `.metadata`.

## Build (host)

```bash
go test ./...
make build-armv7   # → dist/rm2hwr-linux-armv7
# Windows: powershell -File scripts/build-armv7.ps1
```

## `.rm` formats

`rm2hwr` reads the 43-byte `.rm` header and auto-dispatches:

| Header | Parser | Notes |
|--------|--------|-------|
| `version=5` | `internal/rmv5` | Classic stroke layers |
| `version=6` | `internal/rmv6` | Firmware 3+ SceneLineItem strokes (typed text ignored for HWR) |
| other | error | Clear unsupported-version message |

v6 coordinates are converted from page-centre X / top Y into the same top-left portrait space MyScript expects (1404×1872).

## Packages

| Package | Role |
|---------|------|
| `internal/rm` | `.rm` auto-dispatch (v5 / v6 by header) |
| `internal/rmv5` | v5 `.rm` parser |
| `internal/rmv6` | v6 `.rm` SceneLineItem → strokes |
| `internal/myscript` | batch JSON, HMAC-SHA512, HTTP |
| `internal/notebook` | xochitl discovery |
| `internal/handoff` | `NOTE.md` + `HANDOFF.json` |
| `cmd/rm2hwr` | CLI |

## License

Personal / experimental tooling for your own tablet, MyScript credentials, and Joplin account.
