# Install checklist — what each person needs

Gather these **before** running `scripts/install-rm2-stack.ps1`. The installer asks for all of them up front, writes gitignored local files, then runs the long tablet work under `nohup` so a dropped SSH session does not stop it.

## Required

| Item | Where it comes from | Used for |
|------|---------------------|----------|
| Tablet reachability | USB → `10.11.99.1`, or Wi‑Fi IP | `ssh` / `scp` |
| SSH as `root` | reMarkable SSH password (tablet Settings → Help → …) or an SSH key you already installed | Deploy + remote job |
| MyScript `APP_KEY` | [developer.myscript.com](https://developer.myscript.com/) application | `hwr.env` / `rm2hwr` HMAC |
| MyScript `HMAC_KEY` | Same MyScript application | `hwr.env` / `rm2hwr` HMAC |
| Joplin Cloud email | Account at [joplincloud.com](https://joplincloud.com/) | `jonobones init` |
| Joplin Cloud password | Same account | `jonobones init` |

If they sync with **WebDAV / Nextcloud / Joplin Server** instead of Joplin Cloud, collect **server URL + username + password** instead of the Cloud email/password pair (`SYNC_TARGET` in `conf/install.secrets.example`).

## Optional

| Item | When |
|------|------|
| Joplin **E2EE master password** | Only if their vault uses end-to-end encryption. Can skip; encrypted notes stay unreadable on the tablet. |
| Overwrite existing jonobones config | If the tablet was set up before |
| Skip first sync / init | Advanced; leave default unless you know you want it |

## Already provided by this repo / PC

- This git clone (`RemarkableMyscriptLocal`)
- Go toolchain (to cross-compile `rm2hwr`)
- OpenSSH client (`ssh`, `scp`)
- Bundled `third_party/revcord/node_sqlite3.node` (ARMv7)
- Node 20 armv7l tarball (downloaded on the PC and copied over — tablet often has no `curl`/`wget`)

## What the installer does after prompts

1. Saves `conf/install.secrets` + `conf/hwr.env` locally (**gitignored** — do not commit)
2. Builds/deploys `rm2hwr`, scripts, sqlite binary, Node tarball
3. Starts `install-job.sh` on the tablet with **`nohup`**
4. Polls `/tmp/rm2-install.status` over short SSH calls (safe to Ctrl+C the poller; the tablet job keeps going)
5. Scripted `jonobones init` + optional `jonobones start`

Logs on tablet: `/tmp/rm2-install.log`, `/tmp/jonobones-start.log`.
