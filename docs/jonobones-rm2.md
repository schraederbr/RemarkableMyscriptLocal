# jonobones on reMarkable 2

Headless Joplin-sync daemon on RM2 (armv7l, glibc, hard-float). Stay on firmware 2.x unless glibc forces a change. Put all userland under `/home/root` (OS updates wipe `/usr`).

## Stack we validated (2026-09)

| Piece | Value |
|-------|--------|
| Device | RM2, `uname -m` = `armv7l`, firmware ~2.15, glibc 2.31 |
| Node | **20.x linux-armv7l** under `/home/root/opt/node` (Fastify 5 floor; ignore `engines: >=24`) |
| Node runtime | Bundled ARMHF `libatomic.so.1` under `/home/root/hwr/lib` for newer Codex Linux firmware |
| jonobones | `0.1.5` global npm, `--ignore-scripts --ignore-engines` |
| sqlite3 | `5.1.6` N-API v6 — Revcord v1.2 unofficial `node_sqlite3.node` |
| Binding path | `…/sqlite3/lib/binding/napi-v6-linux-glibc-arm/node_sqlite3.node` |
| @joplin/lib | **3.7.1** if Joplin Cloud requires `appMinVersion` 3.7.0+ (bootstrap may need `.default` on some SyncTarget requires — see below) |
| API | `http://127.0.0.1:26637/v1` |

## Do not

- Upgrade to OS 3 “just in case”
- Start at Node 23/24 unless 20 fails JS
- Downgrade sqlite3 below 5.x
- Cross-compile sqlite first (try Revcord drop-in)
- Install into `/usr` or use apt/yum
- Use aarch64 Node on RM2

## Bootstrap patch (@joplin/lib 3.7.x)

If `jonobones start` fails with `SyncTargetClass.id is not a function`, edit:

`$(npm root -g)/jonobones/dist/joplin/bootstrap.js`

Add `.default` to:

- `SyncTargetNextcloud`
- `SyncTargetWebDAV`
- `SyncTargetDropbox`

(Amazon S3 stays without `.default` on 3.7.1.)

## HWR → Joplin

See [joplin-sync.md](./joplin-sync.md). Prefer `HANDOFF.json` → `scripts/joplin-upsert.js` or `--joplin-upsert`.

## Manual recovery

```bash
export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:$PATH
jonobones status
jonobones sync
# smoke sqlite:
node -e 'const s=require("/home/root/.npm-global/lib/node_modules/jonobones/node_modules/sqlite3"); console.log(s.VERSION)'
```
