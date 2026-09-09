#!/usr/bin/env bash
# Install this machine's SSH public key on a reMarkable using the tablet password once.
# Prefer: sshpass. Fallback: SSH_ASKPASS helper (works with OpenSSH / Git Bash).
# Usage:
#   RM_SSH_PASSWORD='...' ./scripts/ensure-rm-ssh-key.sh root@10.11.99.1
#   ./scripts/ensure-rm-ssh-key.sh --password-file /path root@10.11.99.1
set -euo pipefail

PASSWORD_FILE=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --password-file)
      PASSWORD_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0"; exit 0 ;;
    *)
      TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "usage: $0 [--password-file PATH] user@host" >&2
  exit 2
fi

if [[ -n "$PASSWORD_FILE" ]]; then
  RM_SSH_PASSWORD="$(cat "$PASSWORD_FILE")"
  export RM_SSH_PASSWORD
fi

if [[ -z "${RM_SSH_PASSWORD:-}" ]]; then
  echo "ERROR: set RM_SSH_PASSWORD or pass --password-file" >&2
  exit 2
fi

USER_HOST="$TARGET"
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
KEY_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)

key_auth_ok() {
  ssh "${KEY_OPTS[@]}" "$USER_HOST" "echo ok" 2>/dev/null | grep -qx ok
}

if key_auth_ok; then
  echo "key auth already works"
  exit 0
fi

SSH_DIR="${HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true
PUB=""
if [[ -f "$SSH_DIR/id_ed25519.pub" ]]; then
  PUB="$SSH_DIR/id_ed25519.pub"
elif [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
  PUB="$SSH_DIR/id_rsa.pub"
else
  ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "rm2-installer" >/dev/null
  PUB="$SSH_DIR/id_ed25519.pub"
fi
PUBKEY="$(tr -d '\r\n' < "$PUB")"
if [[ -z "$PUBKEY" ]]; then
  echo "ERROR: empty public key at $PUB" >&2
  exit 1
fi

# Escape for single-quoted remote shell fragment
PUB_ESC="${PUBKEY//\'/\'\\\'\'}"
REMOTE_CMD="mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh && touch /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys && grep -Fqx '${PUB_ESC}' /home/root/.ssh/authorized_keys 2>/dev/null || echo '${PUB_ESC}' >> /home/root/.ssh/authorized_keys && echo installed"

run_with_password() {
  local cmd=("$@")
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$RM_SSH_PASSWORD" "${cmd[@]}"
    return $?
  fi

  # SSH_ASKPASS fallback (Git Bash / OpenSSH). No TTY → askpass is used.
  local askpass
  askpass="$(mktemp "${TMPDIR:-/tmp}/rm-askpass.XXXXXX")"
  cat >"$askpass" <<'ASK'
#!/usr/bin/env bash
printf '%s\n' "${RM_SSH_PASSWORD}"
ASK
  chmod 700 "$askpass"
  # export password into askpass environment
  export RM_SSH_PASSWORD
  # rewrite askpass to embed nothing; read from env
  cat >"$askpass" <<ASK
#!/usr/bin/env bash
printf '%s\\n' "\$RM_SSH_PASSWORD"
ASK
  chmod 700 "$askpass"
  export SSH_ASKPASS="$askpass"
  export SSH_ASKPASS_REQUIRE=force
  export DISPLAY="${DISPLAY:-:0}"
  # stdin not a tty so OpenSSH consults askpass
  "${cmd[@]}" </dev/null
  local rc=$?
  rm -f "$askpass"
  return $rc
}

echo "installing $(basename "$PUB") on $USER_HOST (password once)"
run_with_password ssh "${SSH_OPTS[@]}" "$USER_HOST" "$REMOTE_CMD"

if ! key_auth_ok; then
  echo "ERROR: key installed (or attempted) but BatchMode SSH still fails" >&2
  exit 1
fi
echo "key auth ok"