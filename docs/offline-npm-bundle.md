# Offline jonobones npm bundle (GitHub Release asset)

Asset name pattern:

`jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz`

Contents:

- `MANIFEST.txt`
- `npm-global/` — Linux-style global prefix (`bin/jonobones`, `lib/node_modules/…`)
- jonobones **0.1.5**, `@joplin/lib` **3.7.1**, bootstrap `.default` patch, Revcord sqlite binding

Installer flow:

1. Host downloads the asset from the latest GitHub Release (or uses `dist/` if present)
2. `scp` to `/home/root/downloads/` on the tablet
3. `install-node-jonobones.sh` extracts to `/home/root/.npm-global` (no registry needed)

Rebuild (maintainer): portable Node 20 on the PC → `npm install -g jonobones@0.1.5 --prefix staging/npm-global --ignore-scripts` → install `@joplin/lib@3.7.1` inside the package → reshape Windows `node_modules` to `lib/node_modules` → patch bootstrap → drop `third_party/revcord/node_sqlite3.node` → `tar czf`.
