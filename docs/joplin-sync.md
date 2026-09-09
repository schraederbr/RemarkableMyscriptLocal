# HWR → Joplin (direct sync via jonobones)

After `rm2hwr` recognizes a notebook, it writes:

```
/home/root/hwr/out/<doc-uuid>/
  <page-uuid>.txt      # MyScript plaintext per page (if UPLOAD_MODE includes text)
  <page-uuid>.svg      # content-fit ink SVG (if UPLOAD_MODE includes svg)
  INDEX.txt            # # <visibleName> (<uuid>) + page status lines
  NOTE.md              # concatenated markdown (Joplin-ready)
  HANDOFF.json         # machine-readable payload for agents / upsert
```

## Upload mode (`UPLOAD_MODE`)

Controls what `rm2hwr` produces and what `joplin-upsert` sends to Joplin:

| Mode | Behavior |
|------|----------|
| `text` | MyScript plaintext only (default when unset — backward compatible) |
| `svg` | Content-fit page SVGs only (uploaded as Joplin resources) |
| `both` | Text + SVGs per page (fresh installer default) |

Set in `hwr.env` at install time, override per run with `rm2hwr --upload-mode text|svg|both`, or set `UPLOAD_MODE` in the environment for `joplin-upsert.js`.

### Content-fit SVG

SVGs are ink-bbox + ~40px padding at 1:1 pixel size (no downscale). White background, black polylines with round caps. **No** grey dashed page frame. Empty ink pages produce no `.svg` file.

## Title matching

`title` is the reMarkable `visibleName` from xochitl `.metadata` (e.g. `9-8-26`).
Joplin upsert uses **exact** title match: append if a note exists, otherwise create.

## HANDOFF.json schema

```json
{
  "title": "<visibleName>",
  "docUuid": "...",
  "generated": "2026-09-09T02:00:00Z",
  "uploadMode": "both",
  "pages": [
    {"index": 0, "pageUuid": "...", "status": "OK|EMPTY|SKIP|...", "text": "...", "svgPath": "<pageUuid>.svg"}
  ],
  "fullText": "# title\n\n## Page 1\n\n![Page 1](<pageUuid>.svg)\n\nrecognized text\n"
}
```

`NOTE.md` / `HANDOFF.json` remain the on-device source of truth if messaging fails.

## SVG resources in Joplin

When mode is `svg` or `both`, `joplin-upsert.js`:

1. Reads each page `svgPath` under the doc out dir
2. `POST {JONOBONES_URL}/resources` multipart (`data` = file, `props` = `{"title":"Page N — <title>.svg"}`)
3. Rewrites `![Page N](file.svg)` → `![Page N](:/RESOURCE_ID)` in the note body
4. Creates/appends the note as today, then triggers sync

Missing SVG files log a warning and are skipped. Mode `text` skips resource upload entirely.

Auth uses `Authorization: Bearer` (same as notes). Endpoint is under the same `/v1` base; if `/resources` 404s, confirm jonobones exposes the Joplin Clipper-compatible resources API.

## Upsert on device

jonobones holds a local Joplin vault on the tablet and **syncs directly** with Joplin Cloud (or your sync target). Upsert writes into that local vault; the next sync cycle pushes upstream.

Requires jonobones daemon listening on `127.0.0.1:26637` and an API token from init:

```bash
export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
# after HWR:
node /home/root/hwr/scripts/joplin-upsert.js /home/root/hwr/out/<doc-uuid>
# or automatically:
rm2hwr --name "9-8" --joplin-upsert
```

Optional env: `JONOBONES_URL`, `JONOBONES_TOKEN`, `JONOBONES_PARENT_ID`, `JONOBONES_PROFILE`, `UPLOAD_MODE`.

Append separator includes an HTML comment with UTC timestamp and doc UUID so repeats are visible in Joplin history.
