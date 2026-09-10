# Install checklist â€” what each person needs

Gather these **before** running `scripts/install-rm2-stack.ps1`. The installer asks for credentials up front (upload mode first; MyScript keys only for text/both), verifies Joplin Cloud login early, installs your PC SSH key from the tablet password (no manual key setup), recovers from SSH failures (USB retry or Wi-Fi IP), then runs the long tablet work under `nohup`.

## Required

| Item | Where it comes from | Used for |
|------|---------------------|----------|
| **Tablet Wi-Fi + internet** | Tablet network settings | Joplin Cloud sync; MyScript API only if upload mode includes text (npm only if the offline Release asset is missing) |
| Tablet reachability for SSH | USB â†’ `10.11.99.1`, or Wiâ€‘Fi IP | `ssh` / `scp` (USB OK for deploy; Wi-Fi still required for the steps above) |
| reMarkable **root SSH password** | See **Finding the SSH password** below | One-time PC SSH key install |
| Joplin **upload mode** | Installer prompt (or `UPLOAD_MODE` in secrets) | `text` / `svg` / `both` (default **both**). Ask this first. |
| MyScript account + `APP_KEY` | [Sign up / console](https://developer.myscript.com/) | **Required only** when mode is `text` or `both` (skipped for SVG-only) |
| MyScript `HMAC_KEY` | Same app (optional) | Blank OK if HMAC disabled; not prompted for SVG-only |
| **Sync interval (hours)** | Installer prompt (or `SYNC_INTERVAL_HOURS`) | Default **6**; `0` skips systemd timer |
| Joplin **notebook for NEW notes** | Installer prompt (or `JONOBONES_PARENT_ID` / `JONOBONES_PARENT_TITLE`) | Blank = **auto** (most notes at create); or exact title / 32-hex id |
| Joplin Cloud email + password | [joplincloud.com](https://joplincloud.com/) | **Direct sync** via jonobones on the tablet |

WebDAV / Nextcloud / Joplin Server: use URL + username + password instead (`SYNC_TARGET` in `conf/install.secrets.example`).

## Finding the SSH password

Username is always `root`. The device-specific password is shown on the tablet:

- **RM2 / classic:** Settings → Help → About → **Copyrights and licenses** → look under **GPLv3 compliance**
- **Paper Pro / developer mode:** enable developer mode and reveal the SSH password per [Developer mode](https://support.remarkable.com/s/article/Developer-mode)
- Security note: RM2 ships with SSH on by default and a **device-specific** password — [Security in our products and services](https://support.remarkable.com/s/article/Security-in-our-products-and-services)
- The password **changes after a factory reset**; re-read it from the device if SSH suddenly fails
## Optional
| Item | When |
|------|------|
| Joplin E2EE master password | Vault uses end-to-end encryption |
| Overwrite existing jonobones config | Tablet was set up before |

## Already on the PC / in this repo

- Go (cross-compile `rm2hwr`), OpenSSH, **Git for Windows** recommended (Git Bash for passwordâ†’key)
- Bundled `third_party/revcord/node_sqlite3.node`
- Node 20 armv7l tarball fetched on the PC and copied over


## SSH connection recovery

If the installer cannot SSH to the tablet (default USB `10.11.99.1`):

1. **Retry USB** — plug in the tablet, unlock it, enable USB networking / Ethernet over USB, then retry; **or**
2. **Enter Wi-Fi IP** — type the tablet's Wi-Fi IP and the installer retries with that `HOST`.

Non-interactive runs fail immediately with a clear message (set `-HostName` / `HOST` correctly; do not hang).

## Joplin credentials verified early

For **Joplin Cloud**, the host installer POSTs to `https://api.joplincloud.com/api/sessions` right after you enter email/password (before the long on-device job). Bad passwords re-prompt (or fail fast when `NonInteractive`). Joplin Server uses the same `/api/sessions` check against your sync URL. WebDAV/Nextcloud get a best-effort PROPFIND only.
## Progress while installing

The long on-device job runs under `nohup`. While `install-rm2-stack.ps1` (or `.sh`) waits, it prints a **heartbeat ~every 60 seconds**: current `phase=...` from `/tmp/rm2-install.status`, elapsed time, `du` of the jonobones profile, free space under `/home`, and a short log tail. Failures surface immediately with the last log lines. Ctrl+C on the host does not stop the tablet job.

## After install

> **First jonobones ↔ Joplin Cloud sync may take a long time.** Large vaults / many attachments often need **tens of minutes or more**. Keep Wi-Fi on; **do not unplug** and **do not assume the install failed** while jonobones is still syncing. See `/tmp/jonobones-start.log` and the host install heartbeat (`du` of the jonobones profile).

On-device logs: `/tmp/rm2-install.log`, `/tmp/jonobones-start.log`.  
Upsert uses `http://127.0.0.1:26637` and the token in `/home/root/hwr/conf/jonobones.env` (optional `JONOBONES_PARENT_ID` / `JONOBONES_PARENT_TITLE` for NEW notes; unset = auto most-notes).  
Recognized notes sync to Joplin through jonobones â€” keep Wi-Fi on for ongoing sync.

Periodic job: `sync-recent.sh` via **systemd timer** `hwr-sync-recent.timer` (default every 6h; RM2 has no crond). State: `/home/root/hwr/state/`. Log: `/tmp/hwr-sync-recent.log`. Change/disable: see [joplin-sync.md](joplin-sync.md).
