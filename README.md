# rm2hwr â€” on-device MyScript HWR for reMarkable 2

Go client that runs **on the reMarkable 2** (firmware 2.x): parse v5 `.rm` pages under xochitl, build a MyScript iink batch JSON body, POST with HMAC auth, and write plaintext under `/home/root/hwr/out/`.

No Node, Python, or JVM â€” one static `linux/arm` (`GOARM=7`) binary.


## Quick install (RM2 stack)

From a Windows PC that can SSH to the tablet (USB `10.11.99.1` or Wiâ€‘Fi):

```powershell
cd RemarkableMyscriptLocal
powershell -NoProfile -File .\scripts\install-rm2-stack.ps1
```

The installer walks you through:

1. SSH check (armv7l)
2. Cross-compile + deploy `rm2hwr`
3. On-device **Node 20** + Revcord **sqlite3** drop-in + **jonobones**
4. Deploy `joplin-upsert.js` and env template
5. Up-front credential collection + nohup on-device job (see docs/install-checklist.md)

On-device only (already SSHâ€™d as root):

```bash
sh /home/root/hwr/scripts/install-node-jonobones.sh
```

Full port notes: [docs/jonobones-rm2.md](docs/jonobones-rm2.md) Â· HWRâ†’Joplin: [docs/joplin-sync.md](docs/joplin-sync.md)


## Device layout

```
/home/root/hwr/
  bin/rm2hwr
  conf/hwr.env          # mode 0600 â€” never commit real keys
  scripts/joplin-upsert.js
  out/<doc-uuid>/<page-uuid>.txt
  out/<doc-uuid>/<page-uuid>.json   # optional debug body
  out/<doc-uuid>/INDEX.txt
  out/<doc-uuid>/NOTE.md            # concatenated markdown for Joplin
  out/<doc-uuid>/HANDOFF.json       # agent / upsert payload
  README
```

### `hwr.env`

```
APP_KEY=
HMAC_KEY=
LANG=en_US
CONTENT_TYPE=Text
API_URL=https://cloud.myscript.com/api/v4.0/iink/batch
```

See `conf/hwr.env.example`. Copy to the tablet and `chmod 0600`.

### HMAC (critical)

```
secret  = APP_KEY + HMAC_KEY     # string concatenation â€” NOT HMAC_KEY alone
digest  = HMAC-SHA512(secret, raw_body_bytes)
header  = hex(digest)            # lowercase
```

HTTP headers: `applicationKey: <APP_KEY>`, `hmac: <hex>`.

## CLI

```
rm2hwr --all | --name SUBSTR | --uuid DOC
       [--page PAGE] [--dry-run] [--joplin-upsert]
       [--xochitl DIR] [--outdir DIR] [--env FILE]
```

Exactly one of `--all` / `--name` / `--uuid` is required.

| Flag | Default |
|------|---------|
| `--xochitl` | `/home/root/.local/share/remarkable/xochitl/` |
| `--outdir` | `/home/root/hwr/out/` |
| `--env` | `/home/root/hwr/conf/hwr.env` |
| `--dry-run` | write MyScript JSON only; skip HTTP |
| `--page` | limit to one page UUID |
| `--joplin-upsert` | after HWR, run `scripts/joplin-upsert.js` against the doc out dir |
| `--joplin-upsert-bin` | default `/home/root/hwr/scripts/joplin-upsert.js` |

Pages whose output `.txt` is **newer** than the `.rm` are skipped. Empty pages write an empty `.txt` and skip HTTP. Never writes into `.rm` / `.content` / `.metadata`.

### HTTP behaviour

1. `Accept: text/plain`
2. On empty body or `406`, retry `Accept: application/vnd.myscript.jiix` and take `.label`
3. Backoff on `429` / `5xx`: 5s then 15s, max 3 attempts
4. `401` / `403` â†’ abort

## Build

### Host tests

```bash
go test ./...
```

### Cross-compile for the tablet

```bash
make build-armv7
# or: ./scripts/build-armv7.sh
# or on Windows: powershell -File scripts/build-armv7.ps1
```

Produces `dist/rm2hwr-linux-armv7` (`CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7`).

### Install on device

USB ethernet default gateway is `10.11.99.1`:

```bash
ssh root@10.11.99.1 'mkdir -p /home/root/hwr/{bin,conf,out}'
scp dist/rm2hwr-linux-armv7 root@10.11.99.1:/home/root/hwr/bin/rm2hwr
scp conf/hwr.env.example root@10.11.99.1:/home/root/hwr/conf/hwr.env
ssh root@10.11.99.1 'chmod 0755 /home/root/hwr/bin/rm2hwr; chmod 0600 /home/root/hwr/conf/hwr.env'
# edit APP_KEY / HMAC_KEY on device
ssh root@10.11.99.1 '/home/root/hwr/bin/rm2hwr --name "9-8" --dry-run'
```



## Joplin / jonobones sync

After recognition, `rm2hwr` always writes `NOTE.md` + `HANDOFF.json` next to `INDEX.txt`.
Title is the notebook `visibleName` (exact match in Joplin).

See [docs/joplin-sync.md](docs/joplin-sync.md) for the handoff schema and upsert details.

```bash
# on device, with jonobones running:
scp scripts/joplin-upsert.js root@10.11.99.1:/home/root/hwr/scripts/
ssh root@10.11.99.1 'export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
  /home/root/hwr/bin/rm2hwr --name "9-8" --joplin-upsert'
```

Agent pipeline: RemarkableMyScript finishes HWR â†’ SendToAgent Jonobones with `HANDOFF.json` fields â†’ Jonobones appends/creates the Joplin note.

## Packages

| Package | Role |
|---------|------|
| `internal/rmv5` | v5 `.rm` parser (LE); keeps brushes 12â€“17; drops highlighter/eraser |
| `internal/myscript` | batch JSON, HMAC-SHA512, HTTP client |
| `internal/notebook` | xochitl discovery via `.metadata` / `.content` |
| `internal/handoff` | NOTE.md + HANDOFF.json assembly |
| `cmd/rm2hwr` | CLI |

### Parser notes

v5 stroke header includes an extra `u32` unknown field (absent in v3). Each point is six `float32`s: `x, y, speed, tilt, width, pressure`. Strokes with `npoints > 400` are resampled (keep first/last + every 2nd). Strokes with fewer than 2 points after filtering are dropped. v3/v6 headers are rejected with a clear error.

## Fixtures

`testdata/fixtures/` includes a real public sample page (`d94c0b46-â€¦`.rm, notebook visibleName `9-8-26`) plus a tiny synthetic v5 file for fast unit tests.

## License

Personal / experimental tooling for your own tablet and MyScript credentials.
