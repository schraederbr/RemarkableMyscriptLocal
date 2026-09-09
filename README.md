# RemarkableMyscriptLocal — handwriting → Joplin on reMarkable 2

Turn reMarkable 2 notebooks into **Joplin notes that sync with Joplin Cloud** (or WebDAV / Nextcloud / Joplin Server) **on the tablet itself**.

Pipeline:

1. **`rm2hwr`** (Go, on-device) reads xochitl `.rm` pages → MyScript HWR → `NOTE.md` + `HANDOFF.json`
2. **`jonobones`** (on-device Joplin-compatible sync daemon) keeps a local Joplin vault and **syncs directly with your Joplin account**
3. **`joplin-upsert`** (or `rm2hwr --joplin-upsert`) creates/appends the note by **exact notebook title** (`visibleName`), then jonobones syncs it upstream

You do **not** need desktop Joplin open for the sync path. The tablet talks to Joplin Cloud (or your sync target) through jonobones.

> **Wi-Fi required** on the tablet for install (`npm`) and for Joplin sync. USB is fine for SSH/deploy, but the tablet still needs internet.

## Quick install

From a Windows PC that can SSH to the tablet (USB `10.11.99.1` or Wi-Fi IP):

```powershell
cd RemarkableMyscriptLocal
powershell -NoProfile -File .\scripts\install-rm2-stack.ps1
```

Have ready (see [docs/install-checklist.md](docs/install-checklist.md)):

- reMarkable SSH password (installer installs your PC SSH key once — no manual key setup)
- MyScript `APP_KEY` + `HMAC_KEY`
- Joplin Cloud email + password (or another sync target)
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

Matching rule: **exact title** = reMarkable `visibleName`. Existing Joplin note → append; missing → create.

Handoff details: [docs/joplin-sync.md](docs/joplin-sync.md) · RM2 port notes: [docs/jonobones-rm2.md](docs/jonobones-rm2.md)

## What runs on the tablet

| Piece | Role |
|-------|------|
| `rm2hwr` | Parse `.rm`, call MyScript, write `out/<uuid>/` |
| Node 20 + jonobones | Local Joplin vault + **direct sync** to Joplin Cloud/Server/WebDAV |
| Revcord `node_sqlite3.node` | ARMv7 sqlite binding (vendored in `third_party/revcord/`) |
| `joplin-upsert.js` | Title-match upsert into jonobones API (`127.0.0.1:26637`) |

### Device layout

```
/home/root/hwr/
  bin/rm2hwr
  conf/hwr.env              # MyScript keys (0600)
  conf/jonobones.env        # API token for upsert (written by installer)
  scripts/joplin-upsert.js
  out/<doc-uuid>/NOTE.md
  out/<doc-uuid>/HANDOFF.json
/home/root/.config/jonobones/default/   # jonobones profile + synced vault
```

### MyScript `hwr.env`

```
APP_KEY=
HMAC_KEY=
LANG=en_US
CONTENT_TYPE=Text
API_URL=https://cloud.myscript.com/api/v4.0/iink/batch
```

HMAC: `secret = APP_KEY + HMAC_KEY` (concatenation), then HMAC-SHA512 over the raw body; headers `applicationKey` + `hmac`.

## CLI (`rm2hwr`)

```
rm2hwr --all | --name SUBSTR | --uuid DOC
       [--page PAGE] [--dry-run] [--joplin-upsert]
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

## Packages

| Package | Role |
|---------|------|
| `internal/rmv5` | v5 `.rm` parser |
| `internal/myscript` | batch JSON, HMAC-SHA512, HTTP |
| `internal/notebook` | xochitl discovery |
| `internal/handoff` | `NOTE.md` + `HANDOFF.json` |
| `cmd/rm2hwr` | CLI |

## License

Personal / experimental tooling for your own tablet, MyScript credentials, and Joplin account.
