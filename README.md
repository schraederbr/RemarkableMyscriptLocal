# RemarkableMyscriptLocal — handwriting → Joplin on reMarkable 2

Turn reMarkable 2 notebooks into **Joplin notes that sync with Joplin Cloud** (or WebDAV / Nextcloud / Joplin Server) **on the tablet itself**. You do **not** need desktop Joplin open for the sync path — the tablet talks to Joplin Cloud (or your sync target) through jonobones.

## Quick install

### Download and double-click (no paste required)

From the [**v0.3.5** release](https://github.com/schraederbr/RemarkableMyscriptLocal/releases/tag/v0.3.5):

| OS | Asset | How |
|----|-------|-----|
| **Windows** | [`install-rm2-windows.exe`](https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/v0.3.5/install-rm2-windows.exe) | Double-click (console stays open for prompts). Fallback: [`install-rm2-windows.cmd`](https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/v0.3.5/install-rm2-windows.cmd) |
| **Linux** | [`install-rm2-linux`](https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/v0.3.5/install-rm2-linux) | `chmod +x install-rm2-linux && ./install-rm2-linux` (or double-click from a file manager that runs executables in a terminal) |
| **macOS** | [`install-rm2-macos.command`](https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/v0.3.5/install-rm2-macos.command) | Double-click (opens Terminal). First time: right-click → Open if Gatekeeper blocks |

SmartScreen / Gatekeeper may warn on first run — that is normal for unsigned downloadable installers.

### One-liners (same release)

**Windows** (USB `10.11.99.1` by default — no local clone or Go required):

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.5/scripts/install-from-web.ps1 | iex"
```

**Linux / macOS** (bash + curl + OpenSSH):

```
curl -fsSL https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.5/scripts/install-from-web.sh | bash
```

Downloads the **`v0.3.5`** source + release assets over HTTPS (`rm2hwr-linux-armv7`, Node 20 armv7l tarball, `node_sqlite3.node`, jonobones offline npm tarball), then runs the stack installer with `-SkipBuild` / `--skip-build`.

**v0.3.5** includes: clear warning that the **first jonobones ↔ Joplin Cloud sync can take a long time** (large vaults / many attachments — tens of minutes or more); **where to find the root/SSH password** (RM2 Copyrights/GPLv3, Paper Pro [Developer mode](https://support.remarkable.com/s/article/Developer-mode), [security note](https://support.remarkable.com/s/article/Security-in-our-products-and-services), changes after factory reset); plus v0.3.4 quick-install-first README and **no duplicate H1** note body (#16); plus v0.3.3 installer UX and earlier behaviors.

From a local clone (optional):

```powershell
cd RemarkableMyscriptLocal
powershell -NoProfile -File .\scripts\install-rm2-stack.ps1
```

```bash
cd RemarkableMyscriptLocal
./scripts/install-rm2-stack.sh
```

Have ready (see [docs/install-checklist.md](docs/install-checklist.md)):

- **USB cable** (or set `HOST` to the tablet Wi-Fi IP). If SSH to `10.11.99.1` fails, the installer prompts to enable USB networking **or** enter a Wi-Fi IP and retry.
- reMarkable **root SSH password** (installer installs your PC SSH key once — no manual key setup):
  - **RM2 / classic:** Settings → Help → About → **Copyrights and licenses** → password listed under **GPLv3 compliance** (username `root`)
  - **Paper Pro / developer mode:** follow [Developer mode](https://support.remarkable.com/s/article/Developer-mode) (enable developer mode, then reveal the SSH password)
  - Security context: on RM2, SSH is on by default with a **device-specific** password — see [Security in our products and services](https://support.remarkable.com/s/article/Security-in-our-products-and-services)
  - Password **changes after a factory reset** — re-read it from the device if install/SSH suddenly fails
- Joplin upload mode: SVG only / handwriting text / both (installer default: both)
- MyScript `APP_KEY` (optional `HMAC_KEY`) from [developer.myscript.com](https://developer.myscript.com/) — **only if** mode is text or both (SVG-only skips these prompts)
- Joplin Cloud email + password (or another sync target) — **verified up front** for Joplin Cloud before the long on-device install
- Periodic sync interval hours (installer default: **6**; `0` disables systemd timer)
- Joplin notebook for **NEW** notes: blank = auto (notebook with most notes); or exact title / 32-hex id
- Optional E2EE master password
- **Tablet on Wi-Fi with internet**

The installer collects credentials up front, verifies Joplin Cloud login early, deploys `rm2hwr` + Node/jonobones/sqlite, runs the long steps under `nohup` (survives dropped SSH), and scripted `jonobones init` + start.

> **First jonobones ↔ Joplin Cloud sync may take a long time.** Large vaults or many attachments often need **tens of minutes or more**. Keep the tablet on Wi-Fi; **do not unplug** and **do not assume the install failed** while jonobones is still syncing. Check `/tmp/jonobones-start.log` and the install heartbeat (`du` of the jonobones profile) if you are unsure.

## How it works (pipeline)

1. **`rm2hwr`** (Go, on-device) reads xochitl `.rm` pages → MyScript HWR and/or content-fit SVGs → `NOTE.md` + `HANDOFF.json`
2. **`jonobones`** (on-device Joplin-compatible sync daemon) keeps a local Joplin vault and **syncs directly with your Joplin account**
3. **`joplin-upsert`** (or `rm2hwr --joplin-upsert`) **syncs FROM Joplin Cloud first** (`POST /sync` + wait idle) so title match sees Cloud notes, then creates/updates by **exact notebook title** (`visibleName`), **replacing** the marked HWR section (not forever-append), then syncs again to push

> **Wi-Fi required** for Joplin Cloud sync (and MyScript when upload mode includes handwriting text). Install can use the **offline npm Release asset** (no registry on the tablet). USB is fine for SSH/deploy.

Offline bundle docs: [docs/offline-npm-bundle.md](docs/offline-npm-bundle.md).

## Day-to-day: HWR → Joplin

**Supported UI path (optional):** if you use [Oxide](https://oxide.eeems.website/) on the tablet, tap the **Sync Joplin** tile (`syncjoplin.oxide` → `sync-now.sh` → `systemctl start hwr-sync-recent.service`). Oxide is only a launcher — not required for core install; CLI and the systemd timer work without it.

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

> **First sync reminder:** the initial **jonobones ↔ Joplin Cloud** sync after install (or a cold `jonobones start`) can take a **long time** on large vaults / many attachments — **tens of minutes or more**. Leave Wi-Fi on; do not assume failure while sync is still running.

**Pull before match:** `joplin-upsert` always `POST /sync` and waits for idle **before** searching notes by title, so a note that already exists in Joplin Cloud is updated instead of duplicated when the tablet vault was stale; after create/update it syncs again to push. Timeouts: `JONOBONES_SYNC_TIMEOUT_MS` (default 180000), `JONOBONES_SYNC_POLL_MS` (500), `JONOBONES_SYNC_IDLE_GRACE_MS` (2000).

Matching rule: **exact title** = reMarkable `visibleName`. Existing Joplin note → **replace** `<!-- rm2hwr:begin -->`…`<!-- rm2hwr:end -->` block (preserves content outside); missing → create with markers under `JONOBONES_PARENT_ID` / `JONOBONES_PARENT_TITLE`, or (if unset) the notebook with the **most notes**.

HWR markdown uses plain text lines `Remarkable:` and `Page N` (not `##` headings), plus optional `![Page N](….svg)` image embeds. The note body does **not** repeat an `# title` H1 — Joplin already shows `visibleName` as the note title.

Manual one-shot is above. **Automatic:** systemd timer `hwr-sync-recent.timer` runs `sync-recent.sh` every `SYNC_INTERVAL_HOURS` (default 6; RM2 has no crond): last-30-day notebooks, skip unchanged pages via state sidecars, else `rm2hwr --joplin-upsert`.

Handoff / replace markers / systemd timer: [docs/joplin-sync.md](docs/joplin-sync.md) · RM2 port notes: [docs/jonobones-rm2.md](docs/jonobones-rm2.md)

## What runs on the tablet

| Piece | Role |
|-------|------|
| `rm2hwr` | Parse `.rm` (v5 + v6 auto-detect), MyScript HWR and/or SVG, write `out/<uuid>/` |
| Node 20 + jonobones | Local Joplin vault + **direct sync** to Joplin Cloud/Server/WebDAV |
| Revcord `node_sqlite3.node` | ARMv7 sqlite binding (vendored in `third_party/revcord/`) |
| `joplin-upsert.js` | Sync-pull → title-match upsert → sync-push (`127.0.0.1:26637`) |

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
APP_KEY=          # required for text|both; leave empty for SVG-only
HMAC_KEY=         # optional
LANG=en_US
CONTENT_TYPE=Text
API_URL=https://cloud.myscript.com/api/v4.0/iink/batch
UPLOAD_MODE=both  # text | svg | both (unset → text for old installs; svg skips MyScript)
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
| `internal/svg` | content-fit page SVG; stroke-width = mean per-point width / rmc-aligned fineliner fallback |
| `internal/myscript` | batch JSON, HMAC-SHA512, HTTP |
| `internal/notebook` | xochitl discovery |
| `internal/handoff` | `NOTE.md` + `HANDOFF.json` (plain `Remarkable:` / `Page N` lines) |
| `cmd/rm2hwr` | CLI |

## License

Personal / experimental tooling for your own tablet, MyScript credentials, and Joplin account.
