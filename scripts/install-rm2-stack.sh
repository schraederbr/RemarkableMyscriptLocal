#!/usr/bin/env bash
# Linux/macOS host installer for rm2hwr + jonobones on reMarkable 2.
# Collects credentials up front (upload mode, MyScript if needed, Joplin),
# verifies Joplin Cloud login early, recovers from SSH failures (USB / Wi-Fi IP / re-enter password),
# deploys under nohup, and prints heartbeats.
#
# Usage:
#   ./scripts/install-rm2-stack.sh [--host IP] [--user root] [--repo-root PATH]
#                                  [--skip-build] [--non-interactive]
#   HOST=10.11.99.1 ./scripts/install-rm2-stack.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${HOST:-}"
USER_NAME="${SSH_USER:-root}"
SKIP_BUILD=0
NONINTERACTIVE="${NONINTERACTIVE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --repo-root) ROOT="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --non-interactive|--noninteractive) NONINTERACTIVE=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *)
      # positional host for backward compat
      if [[ -z "$HOST" && "$1" != -* ]]; then HOST="$1"; shift; else echo "Unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

ROOT="$(cd "$ROOT" && pwd)"
mkdir -p "$ROOT/conf" "$ROOT/dist"

info() { printf '==> %s\n' "$*"; }
ok() { printf 'OK  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }

ask() {
  local prompt="$1" default="${2:-}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf '%s\n' "$default"
    return
  fi
  local v
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " v || true
    if [[ -z "${v// }" ]]; then v="$default"; fi
  else
    read -r -p "$prompt: " v || true
  fi
  printf '%s\n' "$v"
}

ask_secret() {
  local prompt="$1"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "ERROR: NonInteractive requires $prompt in conf/install.secrets" >&2
    exit 1
  fi
  local v
  read -r -s -p "$prompt: " v || true
  echo >&2
  printf '%s\n' "$v"
}

ask_yes() {
  local prompt="$1" default_yes="${2:-1}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$default_yes" == "1" ]]
    return $?
  fi
  local hint="Y/n"
  [[ "$default_yes" == "1" ]] || hint="y/N"
  local v
  read -r -p "$prompt [$hint]: " v || true
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$v" ]]; then
    [[ "$default_yes" == "1" ]]
    return $?
  fi
  [[ "$v" == "y" || "$v" == "yes" ]]
}

dotenv_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true
}

json_payload() {
  local email="$1" pass="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2]}))' "$email" "$pass"
  elif command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2]}))' "$email" "$pass"
  elif command -v jq >/dev/null 2>&1; then
    jq -n --arg e "$email" --arg p "$pass" '{email:$e,password:$p}'
  else
    # minimal escape
    local ee pp
    ee=${email//\\/\\\\}; ee=${ee//\"/\\\"}
    pp=${pass//\\/\\\\}; pp=${pp//\"/\\\"}
    printf '{"email":"%s","password":"%s"}' "$ee" "$pp"
  fi
}

SECRETS="$ROOT/conf/install.secrets"

ssh_reachable() {
  local err
  err=$(mktemp)
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
      -o NumberOfPasswordPrompts=0 "${USER_NAME}@${HOST}" "echo ok" 2>"$err" | grep -qx ok; then
    rm -f "$err"; return 0
  fi
  if grep -Eiq 'Permission denied|Authentication failed|Too many authentication|Host key verification failed' "$err"; then
    rm -f "$err"; return 0
  fi
  rm -f "$err"; return 1
}

ssh_key_auth_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "${USER_NAME}@${HOST}" "echo ok" 2>/dev/null | grep -qx ok
}

update_secrets_host() {
  local newhost="$1"
  [[ -f "$SECRETS" ]] || return 0
  local tmp
  tmp=$(mktemp)
  if grep -q '^HOST=' "$SECRETS"; then
    sed "s/^HOST=.*/HOST=$newhost/" "$SECRETS" >"$tmp" && mv "$tmp" "$SECRETS"
  else
    echo "HOST=$newhost" | cat - "$SECRETS" >"$tmp" && mv "$tmp" "$SECRETS"
  fi
}

update_secrets_password() {
  local newpw="$1"
  [[ -f "$SECRETS" ]] || return 0
  local tmp
  tmp=$(mktemp)
  if grep -q '^SSH_PASSWORD=' "$SECRETS"; then
    # Use awk to avoid sed special-char issues in passwords
    awk -v p="$newpw" 'BEGIN{done=0} /^SSH_PASSWORD=/{print "SSH_PASSWORD=" p; done=1; next} {print} END{if(!done) print "SSH_PASSWORD=" p}' "$SECRETS" >"$tmp" && mv "$tmp" "$SECRETS"
  else
    echo "SSH_PASSWORD=$newpw" | cat - "$SECRETS" >"$tmp" && mv "$tmp" "$SECRETS"
  fi
}

ssh_recovery_menu() {
  echo
  echo "SSH connection failed. What do you want to do?"
  echo "  1) Check USB / enable USB networking / plug in tablet, then retry  [default]"
  echo "  2) Enter the tablet Wi-Fi IP address / change HOST and retry"
  echo "  3) Re-enter SSH password (password changes after factory reset)"
  echo "  4) Abort"
  local choice newip
  choice=$(ask "Choice" "1")
  if [[ "$choice" == "4" || "$choice" == "a" || "$choice" == "abort" ]]; then
    echo "Aborted: could not SSH to tablet at $HOST" >&2
    exit 1
  fi
  if [[ "$choice" == "2" || "$choice" == "w" ]]; then
    newip=$(ask "Tablet Wi-Fi IP")
    if [[ -z "${newip// }" ]]; then
      warn "No IP entered - keeping $HOST"
    else
      HOST="$newip"
      update_secrets_host "$HOST"
      info "Updated target ${USER_NAME}@${HOST}"
    fi
  elif [[ "$choice" == "3" || "$choice" == "p" ]]; then
    SSH_PASSWORD=$(ask_secret "reMarkable SSH password")
    update_secrets_password "$SSH_PASSWORD"
    ok "Updated stored SSH password"
  else
    echo "Plug in the tablet, unlock it, and enable USB networking if needed; then retry."
    ask "Press Enter to retry USB/default host ($HOST)" "" >/dev/null
  fi
}

ensure_ssh_ready() {
  while true; do
    info "Probing SSH to ${USER_NAME}@${HOST}..."
    if ! ssh_reachable; then
      warn "Cannot reach reMarkable over SSH at ${USER_NAME}@${HOST}."
      if [[ "$NONINTERACTIVE" == "1" ]]; then
        echo "ERROR: SSH to ${USER_NAME}@${HOST} failed (NonInteractive). Enable USB networking (default 10.11.99.1) or set HOST to the tablet Wi-Fi IP, then re-run." >&2
        exit 1
      fi
      ssh_recovery_menu
      continue
    fi
    ok "SSH host reachable at $HOST"

    info "Ensuring SSH key auth (password used at most once per success)..."
    if ssh_key_auth_ok; then
      ok "SSH key auth already works"
      ok "SSH ready at ${USER_NAME}@${HOST}"
      return 0
    fi

    export RM_SSH_PASSWORD="${SSH_PASSWORD:-}"
    if [[ -n "${RM_SSH_PASSWORD:-}" ]]; then
      if "$ROOT/scripts/ensure-rm-ssh-key.sh" "${USER_NAME}@${HOST}"; then
        if ssh_key_auth_ok; then
          ok "SSH ready at ${USER_NAME}@${HOST}"
          return 0
        fi
        warn "SSH key install attempted but BatchMode auth still fails"
      else
        warn "SSH auth/key install failed (ensure-rm-ssh-key.sh)"
      fi
    else
      warn "SSH key auth failed and no SSH password was provided"
    fi

    if [[ "$NONINTERACTIVE" == "1" ]]; then
      echo "ERROR: SSH auth to ${USER_NAME}@${HOST} failed (NonInteractive). Fix SSH password / HOST and re-run." >&2
      exit 1
    fi
    ssh_recovery_menu
  done
}


HWR_ENV="$ROOT/conf/hwr.env"
ANSWERS="$ROOT/conf/jonobones-init-answers.txt"

info "Repo: $ROOT"
echo
echo "What this installer will ask for (have these ready):"
echo "  1) Tablet IP (USB default 10.11.99.1) + reMarkable SSH password"
echo "  2) Joplin upload mode: SVG only / handwriting text / both (default both)"
echo "  3) MyScript APP_KEY (HMAC optional) - only if handwriting text (text or both)"
echo "  4) Periodic sync interval hours (default 6; 0=disable systemd timer)"
echo "  5) Joplin notebook for NEW notes (blank=auto most notes; or title/id)"
echo "  6) Joplin Cloud email + password"
echo "  7) Optional: Joplin E2EE master password"
echo "  8) Tablet on Wi-Fi with internet"
echo "  See docs/install-checklist.md"
echo

# Load existing secrets
SSH_PASSWORD="$(dotenv_get SSH_PASSWORD "$SECRETS")"
APP_KEY="$(dotenv_get APP_KEY "$SECRETS")"
HMAC_KEY="$(dotenv_get HMAC_KEY "$SECRETS")"
LANG_VAL="$(dotenv_get LANG "$SECRETS")"; LANG_VAL="${LANG_VAL:-en_US}"
UPLOAD_MODE="$(dotenv_get UPLOAD_MODE "$SECRETS")"
SYNC_INTERVAL_HOURS="$(dotenv_get SYNC_INTERVAL_HOURS "$SECRETS")"
PARENT_ID="$(dotenv_get JONOBONES_PARENT_ID "$SECRETS")"
PARENT_TITLE="$(dotenv_get JONOBONES_PARENT_TITLE "$SECRETS")"
SYNC_TARGET="$(dotenv_get SYNC_TARGET "$SECRETS")"; SYNC_TARGET="${SYNC_TARGET:-joplinCloud}"
JOPLIN_EMAIL="$(dotenv_get JOPLIN_EMAIL "$SECRETS")"
JOPLIN_PASSWORD="$(dotenv_get JOPLIN_PASSWORD "$SECRETS")"
SYNC_URL="$(dotenv_get SYNC_URL "$SECRETS")"
SYNC_USERNAME="$(dotenv_get SYNC_USERNAME "$SECRETS")"
SYNC_PASSWORD="$(dotenv_get SYNC_PASSWORD "$SECRETS")"
E2EE="$(dotenv_get E2EE_MASTER_PASSWORD "$SECRETS")"
OVERWRITE="$(dotenv_get OVERWRITE_JONOBONES_CONFIG "$SECRETS")"; OVERWRITE="${OVERWRITE:-y}"
if [[ -z "$HOST" ]]; then HOST="$(dotenv_get HOST "$SECRETS")"; fi
SU="$(dotenv_get SSH_USER "$SECRETS")"; [[ -n "$SU" ]] && USER_NAME="$SU"

# --- host selection ---
if [[ -z "$HOST" ]]; then
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    HOST="10.11.99.1"
  else
    echo "How is the tablet connected?"
    echo "  1) USB  (10.11.99.1)"
    echo "  2) Wi-Fi (enter IP)"
    choice=$(ask "Choice" "1")
    if [[ "$choice" == "2" ]]; then
      HOST=$(ask "Tablet IP")
    else
      HOST="10.11.99.1"
    fi
  fi
fi
info "Target ${USER_NAME}@${HOST}"

if [[ -z "$SSH_PASSWORD" && "$NONINTERACTIVE" != "1" ]]; then
  SSH_PASSWORD=$(ask_secret "reMarkable SSH password (blank if key auth already works)")
fi

# Early SSH check (before long credential / download / deploy steps)
info "Checking SSH now (before long install steps)..."
ensure_ssh_ready

# Upload mode first
UPLOAD_MODE=$(printf '%s' "$UPLOAD_MODE" | tr '[:upper:]' '[:lower:]')
if [[ "$UPLOAD_MODE" != "text" && "$UPLOAD_MODE" != "svg" && "$UPLOAD_MODE" != "both" ]]; then
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    UPLOAD_MODE="both"
  else
    echo
    echo "What should rm2hwr upload to Joplin?"
    echo "  1) Handwriting text only (MyScript HWR - needs APP_KEY)"
    echo "  2) SVG only (page images - no MyScript keys)"
    echo "  3) Both text and SVG  [default]"
    um=$(ask "Choice" "3")
    case "$um" in
      1) UPLOAD_MODE=text ;;
      2) UPLOAD_MODE=svg ;;
      *) UPLOAD_MODE=both ;;
    esac
  fi
fi

if [[ "$UPLOAD_MODE" == "svg" ]]; then
  ok "UPLOAD_MODE=svg - skipping MyScript APP_KEY/HMAC_KEY prompts"
  APP_KEY=""
  HMAC_KEY=""
else
  if [[ -z "$APP_KEY" ]]; then
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      echo "ERROR: NonInteractive requires APP_KEY in secrets when UPLOAD_MODE is text or both" >&2
      exit 1
    fi
    echo
    echo "MyScript Cloud - create a free app and copy keys:"
    echo "  https://developer.myscript.com/"
    APP_KEY=$(ask "MyScript APP_KEY")
    HMAC_KEY=$(ask "MyScript HMAC_KEY (optional, blank OK)" "")
  fi
fi

if [[ -z "$SYNC_INTERVAL_HOURS" ]]; then
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    SYNC_INTERVAL_HOURS=6
  else
    echo
    echo "How often should the tablet auto-sync recent notebooks to Joplin?"
    echo "  Enter hours between runs (default 6). Use 0 to skip installing systemd timer."
    SYNC_INTERVAL_HOURS=$(ask "Sync interval hours" "6")
  fi
fi

if [[ -z "$PARENT_ID" && -z "$PARENT_TITLE" && "$NONINTERACTIVE" != "1" ]]; then
  echo
  echo "Joplin notebook for NEW notes [auto=most notes]"
  echo "  Blank = auto-pick notebook with the most notes at create time."
  echo "  Or enter a notebook title (exact match) or a 32-hex notebook id."
  nb=$(ask "Notebook title or id (blank=auto)" "")
  if [[ -n "$nb" ]]; then
    if [[ "$nb" =~ ^[0-9a-fA-F]{32}$ ]]; then PARENT_ID="$nb"; else PARENT_TITLE="$nb"; fi
  fi
fi

if [[ "$NONINTERACTIVE" != "1" && -z "$(dotenv_get SYNC_TARGET "$SECRETS")" ]]; then
  SYNC_TARGET=$(ask "Sync target (joplinCloud/webdav/nextcloud/joplinServer)" "joplinCloud")
fi

if [[ "$SYNC_TARGET" == "joplinCloud" ]]; then
  [[ -n "$JOPLIN_EMAIL" ]] || JOPLIN_EMAIL=$(ask "Joplin Cloud email")
  [[ -n "$JOPLIN_PASSWORD" ]] || JOPLIN_PASSWORD=$(ask_secret "Joplin Cloud password")
elif [[ "$SYNC_TARGET" == "webdav" || "$SYNC_TARGET" == "nextcloud" || "$SYNC_TARGET" == "joplinServer" ]]; then
  [[ -n "$SYNC_URL" ]] || SYNC_URL=$(ask "Sync server URL")
  [[ -n "$SYNC_USERNAME" ]] || SYNC_USERNAME=$(ask "Sync username")
  [[ -n "$SYNC_PASSWORD" ]] || SYNC_PASSWORD=$(ask_secret "Sync password")
else
  echo "ERROR: Automated init does not support SYNC_TARGET=$SYNC_TARGET" >&2
  exit 1
fi

# --- early Joplin Cloud verify ---
verify_joplin_cloud() {
  local email="$1" pass="$2"
  local payload code tmp
  payload=$(json_payload "$email" "$pass")
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json; charset=utf-8' \
    --connect-timeout 20 --max-time 30 \
    -d "$payload" \
    "https://api.joplincloud.com/api/sessions" || echo "000")
  if [[ "$code" == "200" ]] && grep -q '"id"' "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  echo "$code"
  return 1
}

if [[ "$SYNC_TARGET" == "joplinCloud" ]]; then
  while true; do
    info "Verifying Joplin Cloud password for $JOPLIN_EMAIL..."
    if code=$(verify_joplin_cloud "$JOPLIN_EMAIL" "$JOPLIN_PASSWORD"); then
      ok "Joplin Cloud credentials verified"
      break
    fi
    warn "Joplin Cloud login failed (HTTP ${code:-unknown})."
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      echo "ERROR: NonInteractive: Joplin Cloud login failed for $JOPLIN_EMAIL" >&2
      exit 1
    fi
    echo "  1) Re-enter email/password and retry  [default]"
    echo "  2) Abort"
    c=$(ask "Choice" "1")
    if [[ "$c" == "2" || "$c" == "a" || "$c" == "abort" ]]; then
      echo "Aborted: Joplin Cloud credentials not verified" >&2
      exit 1
    fi
    JOPLIN_EMAIL=$(ask "Joplin Cloud email" "$JOPLIN_EMAIL")
    JOPLIN_PASSWORD=$(ask_secret "Joplin Cloud password")
  done
elif [[ "$SYNC_TARGET" == "joplinServer" ]]; then
  while true; do
    info "Verifying Joplin Server login at $SYNC_URL ..."
    payload=$(json_payload "$SYNC_USERNAME" "$SYNC_PASSWORD")
    base=${SYNC_URL%/}
    tmp=$(mktemp)
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json; charset=utf-8' \
      --connect-timeout 20 --max-time 30 \
      -d "$payload" \
      "${base}/api/sessions" || echo "000")
    if [[ "$code" == "200" ]] && grep -q '"id"' "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      ok "Joplin Server credentials verified"
      break
    fi
    rm -f "$tmp"
    warn "Joplin Server verify failed (HTTP $code)"
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      echo "ERROR: NonInteractive: Joplin Server login failed" >&2
      exit 1
    fi
    if ! ask_yes "Re-enter Joplin Server URL/username/password?" 1; then
      echo "Aborted: Joplin Server credentials not verified" >&2
      exit 1
    fi
    SYNC_URL=$(ask "Sync server URL" "$SYNC_URL")
    SYNC_USERNAME=$(ask "Sync username" "$SYNC_USERNAME")
    SYNC_PASSWORD=$(ask_secret "Sync password")
  done
elif [[ "$SYNC_TARGET" == "webdav" || "$SYNC_TARGET" == "nextcloud" ]]; then
  info "Best-effort verify of $SYNC_TARGET credentials..."
  code=$(curl -sS -o /dev/null -w '%{http_code}' -u "${SYNC_USERNAME}:${SYNC_PASSWORD}" \
    -X PROPFIND -H 'Depth: 0' --connect-timeout 15 --max-time 30 "$SYNC_URL" || echo "000")
  if [[ "$code" =~ ^2 ]]; then
    ok "$SYNC_TARGET credentials look OK (HTTP $code)"
  else
    warn "$SYNC_TARGET verify inconclusive or failed (HTTP $code)"
    warn "Installer will continue; fix URL/username/password if jonobones init fails later."
    if [[ "$NONINTERACTIVE" != "1" ]]; then
      ask_yes "Continue with these $SYNC_TARGET credentials anyway?" 1 || exit 1
    fi
  fi
fi

if [[ "$NONINTERACTIVE" != "1" && -z "$(dotenv_get E2EE_MASTER_PASSWORD "$SECRETS")" ]]; then
  if ask_yes "Does this Joplin vault use E2EE (master password)?" 0; then
    E2EE=$(ask_secret "E2EE master password")
  fi
fi

if [[ "$NONINTERACTIVE" != "1" && -z "$(dotenv_get OVERWRITE_JONOBONES_CONFIG "$SECRETS")" ]]; then
  if ask_yes "If jonobones is already configured on the tablet, overwrite it?" 1; then
    OVERWRITE=y
  else
    OVERWRITE=n
  fi
fi

# persist secrets + hwr.env
umask 077
cat > "$SECRETS" <<EOF
HOST=$HOST
SSH_USER=$USER_NAME
SSH_PASSWORD=$SSH_PASSWORD
APP_KEY=$APP_KEY
HMAC_KEY=$HMAC_KEY
LANG=$LANG_VAL
UPLOAD_MODE=$UPLOAD_MODE
SYNC_INTERVAL_HOURS=$SYNC_INTERVAL_HOURS
JONOBONES_PARENT_ID=$PARENT_ID
JONOBONES_PARENT_TITLE=$PARENT_TITLE
SYNC_TARGET=$SYNC_TARGET
JOPLIN_EMAIL=$JOPLIN_EMAIL
JOPLIN_PASSWORD=$JOPLIN_PASSWORD
SYNC_URL=$SYNC_URL
SYNC_USERNAME=$SYNC_USERNAME
SYNC_PASSWORD=$SYNC_PASSWORD
E2EE_MASTER_PASSWORD=$E2EE
OVERWRITE_JONOBONES_CONFIG=$OVERWRITE
SKIP_JONOBONES_INIT=0
START_JONOBONES=1
EOF
cat > "$HWR_ENV" <<EOF
APP_KEY=$APP_KEY
HMAC_KEY=$HMAC_KEY
LANG=$LANG_VAL
CONTENT_TYPE=Text
API_URL=https://cloud.myscript.com/api/v4.0/iink/batch
UPLOAD_MODE=$UPLOAD_MODE
SYNC_INTERVAL_HOURS=$SYNC_INTERVAL_HOURS
EOF
ok "Saved conf/install.secrets + conf/hwr.env (gitignored)"

# SSH already verified early (after password); re-check before deploy
info "Re-checking SSH before deploy..."
ensure_ssh_ready
ok "SSH works"


ARCH=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${USER_NAME}@${HOST}" "uname -m")
if [[ "$ARCH" != "armv7l" ]]; then
  echo "ERROR: Expected armv7l, got '$ARCH'" >&2
  exit 1
fi

info "Checking tablet internet..."
NET=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${USER_NAME}@${HOST}" "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo yes || echo no" || echo no)
if [[ "$NET" != "yes" ]]; then
  warn "Tablet has no internet right now."
  if [[ "$NONINTERACTIVE" == "1" ]] || ! ask_yes "Continue anyway?" 0; then
    echo "Aborted: tablet needs Wi-Fi/internet" >&2
    exit 1
  fi
else
  ok "Tablet can reach the internet"
fi

# Build jonobones answers
HAS_CONFIG=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${USER_NAME}@${HOST}" \
  'test -f /home/root/.config/jonobones/default/config.json5 && echo yes || echo no' || echo no)
DO_INIT=1
: > "$ANSWERS"
if [[ "$HAS_CONFIG" == "yes" ]]; then
  if [[ "$OVERWRITE" == "y" || "$OVERWRITE" == "Y" || "$OVERWRITE" == "1" ]]; then
    echo "y" >> "$ANSWERS"
  else
    warn "Existing jonobones config will be left alone"
    DO_INIT=0
  fi
fi
if [[ "$DO_INIT" == "1" ]]; then
  case "$SYNC_TARGET" in
    filesystem) echo 1 >> "$ANSWERS" ;;
    webdav) echo 2 >> "$ANSWERS" ;;
    nextcloud) echo 3 >> "$ANSWERS" ;;
    joplinServer) echo 4 >> "$ANSWERS" ;;
    joplinCloud) echo 5 >> "$ANSWERS" ;;
    s3) echo 6 >> "$ANSWERS" ;;
    dropbox) echo 7 >> "$ANSWERS" ;;
    *) echo 5 >> "$ANSWERS" ;;
  esac
  if [[ "$SYNC_TARGET" == "joplinCloud" ]]; then
    printf '%s\n' "$JOPLIN_EMAIL" >> "$ANSWERS"
    printf '%s\n' "$JOPLIN_PASSWORD" >> "$ANSWERS"
  else
    printf '%s\n' "$SYNC_URL" >> "$ANSWERS"
    printf '%s\n' "$SYNC_USERNAME" >> "$ANSWERS"
    printf '%s\n' "$SYNC_PASSWORD" >> "$ANSWERS"
  fi
  printf '%s\n' "${E2EE:-}" >> "$ANSWERS"
  printf '\n' >> "$ANSWERS"
fi

# Binary: prefer dist, else HTTPS release
DIST="$ROOT/dist/rm2hwr-linux-armv7"
RELEASE_TAG="${RM2_RELEASE_TAG:-${RELEASE_TAG:-v0.3.9}}"
RELEASE_BASE="https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/${RELEASE_TAG}"
if [[ -f "$DIST" && $(wc -c <"$DIST") -gt 100000 ]]; then
  ok "Using existing binary $DIST"
elif [[ "$SKIP_BUILD" == "1" ]]; then
  info "Downloading rm2hwr-linux-armv7 from release $RELEASE_TAG"
  BINARY_NAME=rm2hwr-linux-armv7
  mkdir -p "$ROOT/dist"
  if command -v curl >/dev/null; then
    curl -fsSL -o "$DIST" "$RELEASE_BASE/$BINARY_NAME"
  else
    wget -q -O "$DIST" "$RELEASE_BASE/$BINARY_NAME"
  fi
else
  if command -v go >/dev/null 2>&1; then
    info "Building rm2hwr for armv7..."
    (cd "$ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags '-s -w' -o "$DIST" ./cmd/rm2hwr)
  else
    info "Go not found - downloading release binary $RELEASE_TAG"
    mkdir -p "$ROOT/dist"
    curl -fsSL -o "$DIST" "$RELEASE_BASE/rm2hwr-linux-armv7"
  fi
fi

LIBATOMIC="$ROOT/dist/libatomic.so.1"
if [[ ! -f "$LIBATOMIC" || $(wc -c <"$LIBATOMIC") -lt 10000 ]]; then
  info "Downloading libatomic.so.1 for Node on Codex Linux firmware"
  mkdir -p "$ROOT/dist"
  if command -v curl >/dev/null; then
    curl -fsSL -o "$LIBATOMIC" "$RELEASE_BASE/libatomic.so.1"
  else
    wget -q -O "$LIBATOMIC" "$RELEASE_BASE/libatomic.so.1"
  fi
fi
[[ -f "$LIBATOMIC" && $(wc -c <"$LIBATOMIC") -ge 10000 ]] || { echo "ERROR: missing libatomic.so.1" >&2; exit 1; }

# Deploy
info "Deploying scripts and binary..."
ssh -o BatchMode=yes -o ConnectTimeout=10 "${USER_NAME}@${HOST}" \
  'mkdir -p /home/root/hwr/scripts /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/lib /home/root/hwr/out /home/root/hwr/state /home/root/hwr/third_party/revcord /home/root/downloads'
scp -o BatchMode=yes -o ConnectTimeout=10 \
  "$ROOT/scripts/on-device/install-node-jonobones.sh" \
  "$ROOT/scripts/on-device/jonobones-init-cloud.sh" \
  "$ROOT/scripts/on-device/install-job.sh" \
  "$ROOT/scripts/on-device/sync-recent.sh" \
  "$ROOT/scripts/joplin-upsert.js" \
  "${USER_NAME}@${HOST}:/home/root/hwr/scripts/"
if [[ -f "$ROOT/third_party/revcord/node_sqlite3.node" ]]; then
  scp -o BatchMode=yes "$ROOT/third_party/revcord/node_sqlite3.node" \
    "${USER_NAME}@${HOST}:/home/root/hwr/third_party/revcord/node_sqlite3.node"
fi
scp -o BatchMode=yes "$LIBATOMIC" "${USER_NAME}@${HOST}:/home/root/hwr/lib/libatomic.so.1"
scp -o BatchMode=yes "$HWR_ENV" "${USER_NAME}@${HOST}:/home/root/hwr/conf/hwr.env"
if [[ -f "$ANSWERS" && "$DO_INIT" == "1" ]]; then
  scp -o BatchMode=yes "$ANSWERS" "${USER_NAME}@${HOST}:/home/root/hwr/conf/jonobones-init-answers.txt"
fi
META_EXTRA=""
[[ -n "$PARENT_ID" ]] && META_EXTRA="${META_EXTRA}JONOBONES_PARENT_ID=$PARENT_ID\n"
[[ -n "$PARENT_TITLE" ]] && META_EXTRA="${META_EXTRA}JONOBONES_PARENT_TITLE=$PARENT_TITLE\n"
printf 'SKIP_JONOBONES_INIT=%s\nSTART_JONOBONES=1\n%s' "$([[ $DO_INIT == 1 ]] && echo 0 || echo 1)" "$META_EXTRA" \
  | ssh -o BatchMode=yes "${USER_NAME}@${HOST}" 'cat > /home/root/hwr/conf/install.meta'
scp -o BatchMode=yes "$DIST" "${USER_NAME}@${HOST}:/home/root/hwr/bin/rm2hwr"
ssh -o BatchMode=yes "${USER_NAME}@${HOST}" 'chmod 0755 /home/root/hwr/bin/rm2hwr'

# Optional offline npm + node tarball from dist/
for f in jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz node-v20.20.2-linux-armv7l.tar.xz; do
  if [[ -f "$ROOT/dist/$f" ]]; then
    scp -o BatchMode=yes "$ROOT/dist/$f" "${USER_NAME}@${HOST}:/home/root/downloads/$f" || true
  fi
done

ssh -o BatchMode=yes "${USER_NAME}@${HOST}" \
  'chmod +x /home/root/hwr/scripts/*.sh; chmod 0600 /home/root/hwr/conf/hwr.env; rm -f /tmp/rm2-install.status; : > /tmp/rm2-install.log; nohup sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.nohup.out 2>&1 & echo started'

# systemd timer
HOURS="$SYNC_INTERVAL_HOURS"
HOURS=${HOURS:-6}
scp -o BatchMode=yes \
  "$ROOT/scripts/on-device/hwr-sync-recent.service" \
  "$ROOT/scripts/on-device/hwr-sync-recent.timer" \
  "${USER_NAME}@${HOST}:/tmp/"
ssh -o BatchMode=yes "${USER_NAME}@${HOST}" "HOURS='$HOURS' sh -s" <<'TIMER'
set -e
UNIT_DIR=/etc/systemd/system
chmod 0755 /home/root/hwr/scripts/sync-recent.sh
cp /tmp/hwr-sync-recent.service "$UNIT_DIR/hwr-sync-recent.service"
cp /tmp/hwr-sync-recent.timer "$UNIT_DIR/hwr-sync-recent.timer"
if command -v crontab >/dev/null 2>&1; then
  TMP=/tmp/rm2-crontab.new
  crontab -l 2>/dev/null | grep -v sync-recent.sh | grep -v rm2hwr-sync-recent > "$TMP" || true
  if [ -s "$TMP" ]; then crontab "$TMP" 2>/dev/null || true; else crontab -r 2>/dev/null || true; fi
  rm -f "$TMP"
fi
if [ -n "$HOURS" ] && [ "$HOURS" -gt 0 ] 2>/dev/null; then
  sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${HOURS}h/" "$UNIT_DIR/hwr-sync-recent.timer"
  systemctl daemon-reload
  systemctl enable hwr-sync-recent.timer
  systemctl start hwr-sync-recent.timer
  echo "systemd timer enabled interval=${HOURS}h"
else
  systemctl daemon-reload
  systemctl stop hwr-sync-recent.timer 2>/dev/null || true
  systemctl disable hwr-sync-recent.timer 2>/dev/null || true
  echo "systemd timer disabled (SYNC_INTERVAL_HOURS=0)"
fi
rm -f /tmp/hwr-sync-recent.service /tmp/hwr-sync-recent.timer
TIMER

info "Starting on-device install job under nohup (survives SSH drop)..."
echo "==> Job running on tablet. Heartbeat every ~60s (Ctrl+C here is safe - job keeps running)."
deadline=$((SECONDS + 6*3600))
last_hb=0
phase=pending
while (( SECONDS < deadline )); do
  sleep 5
  st=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "${USER_NAME}@${HOST}" 'cat /tmp/rm2-install.status 2>/dev/null || echo phase=pending' || true)
  if [[ -z "$st" ]]; then
    echo "!!  SSH blip while polling - retrying (on-device job still running)"
    continue
  fi
  if [[ "$st" == phase=* ]]; then
    phase="${st#phase=}"
    phase="${phase%%$'\n'*}"
  elif [[ "$st" == ok || "$st" == fail || "$st" == running || "$st" == pending ]]; then
    phase="$st"
  else
    phase=$(printf '%s\n' "$st" | sed -n 's/^phase=//p' | head -n1)
    [[ -n "$phase" ]] || phase="$st"
  fi
  if [[ "$phase" == "ok" ]]; then
    ok "On-device job finished successfully"
    break
  fi
  if [[ "$phase" == "fail" ]]; then
    warn "On-device job failed - last log lines:"
    ssh "${USER_NAME}@${HOST}" 'tail -n 40 /tmp/rm2-install.log' || true
    exit 1
  fi
  now=$SECONDS
  if (( now - last_hb >= 60 )); then
    last_hb=$now
    elapsed=$now
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    snap=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "${USER_NAME}@${HOST}" 'phase=$(sed -n "s/^phase=//p" /tmp/rm2-install.status 2>/dev/null | head -n1); [ -n "$phase" ] || phase=pending; du_k=$(du -sk /home/root/.config/jonobones 2>/dev/null | awk "{print \$1}"); [ -n "$du_k" ] || du_k=0; free_k=$(df -k /home 2>/dev/null | tail -n1 | awk "{print \$4}"); [ -n "$free_k" ] || free_k=?; echo "PHASE=$phase"; echo "DU_K=$du_k"; echo "FREE_K=$free_k"; echo "----LOG----"; tail -n 12 /tmp/rm2-install.log 2>/dev/null || true' || true)
    hb_phase=$(printf '%s\n' "$snap" | sed -n 's/^PHASE=//p' | head -n1)
    du_k=$(printf '%s\n' "$snap" | sed -n 's/^DU_K=//p' | head -n1)
    free_k=$(printf '%s\n' "$snap" | sed -n 's/^FREE_K=//p' | head -n1)
    [[ -n "$hb_phase" ]] || hb_phase="$phase"
    [[ -n "$du_k" ]] || du_k=0
    [[ -n "$free_k" ]] || free_k=?
    if [[ "$du_k" =~ ^[0-9]+$ ]]; then
      du_m=$(awk -v k="$du_k" 'BEGIN{printf "%.1fM", k/1024}')
    else
      du_m="$du_k"
    fi
    if [[ "$free_k" =~ ^[0-9]+$ ]]; then
      free_m=$(awk -v k="$free_k" 'BEGIN{printf "%.1fM", k/1024}')
    else
      free_m="$free_k"
    fi
    printf '\n-- heartbeat  phase=%s  elapsed=%dm%02ds  jonobones=%s  /home free=%s\n' \
      "$hb_phase" "$mins" "$secs" "$du_m" "$free_m"
    printf '%s\n' "$snap" | awk 'f{print "   | "$0} /^----LOG----$/{f=1}'
  fi
done
if [[ "$phase" != "ok" ]]; then
  echo "ERROR: timed out waiting for install-job" >&2
  exit 1
fi
echo "Logs on tablet: /tmp/rm2-install.log  /tmp/jonobones-start.log"
ok "Install finished"
echo ""
warn "First jonobones <-> Joplin Cloud sync may take a LONG time (large vaults / many attachments: tens of minutes or more)."
warn "Keep Wi-Fi on. Do NOT unplug / do NOT assume install failed while jonobones is still syncing."
warn "Watch: /tmp/jonobones-start.log and install heartbeat du of the jonobones profile."
