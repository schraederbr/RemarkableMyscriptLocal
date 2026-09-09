# rm2hwr — on-device MyScript HWR for reMarkable 2

Go client that runs **on the reMarkable 2** (firmware 2.x): parse v5 `.rm` pages under xochitl, build a MyScript iink batch JSON body, POST with HMAC auth, and write plaintext under `/home/root/hwr/out/`.

No Node, Python, or JVM — one static `linux/arm` (`GOARM=7`) binary.

## Device layout

```
/home/root/hwr/
  bin/rm2hwr
  conf/hwr.env          # mode 0600 — never commit real keys
  out/<doc-uuid>/<page-uuid>.txt
  out/<doc-uuid>/<page-uuid>.json   # optional debug body
  out/<doc-uuid>/INDEX.txt
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
secret  = APP_KEY + HMAC_KEY     # string concatenation — NOT HMAC_KEY alone
digest  = HMAC-SHA512(secret, raw_body_bytes)
header  = hex(digest)            # lowercase
```

HTTP headers: `applicationKey: <APP_KEY>`, `hmac: <hex>`.

## CLI

```
rm2hwr --all | --name SUBSTR | --uuid DOC
       [--page PAGE] [--dry-run]
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

Pages whose output `.txt` is **newer** than the `.rm` are skipped. Empty pages write an empty `.txt` and skip HTTP. Never writes into `.rm` / `.content` / `.metadata`.

### HTTP behaviour

1. `Accept: text/plain`
2. On empty body or `406`, retry `Accept: application/vnd.myscript.jiix` and take `.label`
3. Backoff on `429` / `5xx`: 5s then 15s, max 3 attempts
4. `401` / `403` → abort

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

## Packages

| Package | Role |
|---------|------|
| `internal/rmv5` | v5 `.rm` parser (LE); keeps brushes 12–17; drops highlighter/eraser |
| `internal/myscript` | batch JSON, HMAC-SHA512, HTTP client |
| `internal/notebook` | xochitl discovery via `.metadata` / `.content` |
| `cmd/rm2hwr` | CLI |

### Parser notes

v5 stroke header includes an extra `u32` unknown field (absent in v3). Each point is six `float32`s: `x, y, speed, tilt, width, pressure`. Strokes with `npoints > 400` are resampled (keep first/last + every 2nd). Strokes with fewer than 2 points after filtering are dropped. v3/v6 headers are rejected with a clear error.

## Fixtures

`testdata/fixtures/` includes a real public sample page (`d94c0b46-…`.rm, notebook visibleName `9-8-26`) plus a tiny synthetic v5 file for fast unit tests.

## License

Personal / experimental tooling for your own tablet and MyScript credentials.
