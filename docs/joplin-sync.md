# HWR → Joplin (direct sync via jonobones)

# HWR â†’ Joplin (jonobones) pipeline

After `rm2hwr` recognizes a notebook, it writes:

```
/home/root/hwr/out/<doc-uuid>/
  <page-uuid>.txt      # MyScript plaintext per page
  INDEX.txt            # # <visibleName> (<uuid>) + page status lines
  NOTE.md              # concatenated markdown (Joplin-ready)
  HANDOFF.json         # machine-readable payload for agents / upsert
```

## Title matching

`title` is the reMarkable `visibleName` from xochitl `.metadata` (e.g. `9-8-26`).
Joplin upsert uses **exact** title match: append if a note exists, otherwise create.

## HANDOFF.json schema

```json
{
  "title": "<visibleName>",
  "docUuid": "...",
  "generated": "2026-09-09T02:00:00Z",
  "pages": [
    {"index": 0, "pageUuid": "...", "status": "OK|EMPTY|SKIP|...", "text": "..."}
  ],
  "fullText": "# title\n\n## Page 1\n...\n"
}
```

Grok bots (RemarkableMyScript â†’ Jonobones) can SendToAgent this object when a run finishes.
`NOTE.md` / `HANDOFF.json` remain the on-device source of truth if messaging fails.

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

Optional env: `JONOBONES_URL`, `JONOBONES_TOKEN`, `JONOBONES_PARENT_ID`, `JONOBONES_PROFILE`.

Append separator includes an HTML comment with UTC timestamp and doc UUID so repeats are visible in Joplin history.
