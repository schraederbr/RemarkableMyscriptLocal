# Install checklist — what each person needs

Gather these **before** running `scripts/install-rm2-stack.ps1`. The installer asks for credentials up front, installs your PC SSH key from the tablet password (no manual key setup), then runs the long tablet work under `nohup`.

## Required

| Item | Where it comes from | Used for |
|------|---------------------|----------|
| **Tablet Wi-Fi + internet** | Tablet network settings | Joplin Cloud sync + MyScript API (npm only if the offline Release asset is missing) |
| Tablet reachability for SSH | USB → `10.11.99.1`, or Wi‑Fi IP | `ssh` / `scp` (USB OK for deploy; Wi-Fi still required for the steps above) |
| reMarkable SSH password | Settings → Help → Copyrights and licenses | One-time PC SSH key install |
| MyScript account + `APP_KEY` | [Sign up / console](https://developer.myscript.com/) | HWR (required) |
| MyScript `HMAC_KEY` | Same app (optional) | Blank OK if HMAC disabled |
| Joplin Cloud email + password | [joplincloud.com](https://joplincloud.com/) | **Direct sync** via jonobones on the tablet |

WebDAV / Nextcloud / Joplin Server: use URL + username + password instead (`SYNC_TARGET` in `conf/install.secrets.example`).

## Optional

| Item | When |
|------|------|
| Joplin E2EE master password | Vault uses end-to-end encryption |
| Overwrite existing jonobones config | Tablet was set up before |

## Already on the PC / in this repo

- Go (cross-compile `rm2hwr`), OpenSSH, **Git for Windows** recommended (Git Bash for password→key)
- Bundled `third_party/revcord/node_sqlite3.node`
- Node 20 armv7l tarball fetched on the PC and copied over

## After install

On-device logs: `/tmp/rm2-install.log`, `/tmp/jonobones-start.log`.  
Upsert uses `http://127.0.0.1:26637` and the token in `/home/root/hwr/conf/jonobones.env`.  
Recognized notes sync to Joplin through jonobones — keep Wi-Fi on for ongoing sync.
