#!/usr/bin/env bash
set -euo pipefail
umask 077

LINUX_USER=""
READ_STDIN=0
SET_DEFAULT=0
TOKENS_DIR="/etc/papercut-hive-lite/tokens"
TARGET=""
TMP_TARGET=""

usage() {
  cat <<EOF
Usage: $0 --linux-user <username> --stdin

Reads a PaperCut JWT from stdin and writes:
  /etc/papercut-hive-lite/tokens/<username>.jwt
or (with --default):
  /etc/papercut-hive-lite/tokens/default.jwt

This script is intended to be run as root via restricted sudoers.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --default) SET_DEFAULT=1; shift ;;
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

cleanup() {
  if [[ -n "$TMP_TARGET" && -f "$TMP_TARGET" ]]; then
    rm -f "$TMP_TARGET" || true
  fi
  unset TOKEN TMP_TARGET
}
trap cleanup EXIT

mode_is_subset() {
  local mode="$1"
  local allowed="$2"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$allowed" =~ ^[0-7]{3,4}$ ]] || return 1
  local mode_int allowed_int
  mode_int=$((8#$mode))
  allowed_int=$((8#$allowed))
  (( (mode_int | allowed_int) == allowed_int ))
}

check_secure_path() {
  local path="$1"
  local expected_type="$2"
  local expected_owner="$3"
  local expected_group="$4"
  local max_mode="$5"
  local label="$6"
  local stat_out owner group mode

  if [[ -L "$path" ]]; then
    echo "$label must not be a symlink: $path" >&2
    return 1
  fi
  if [[ "$expected_type" == "dir" ]]; then
    [[ -d "$path" ]] || { echo "$label is not a directory: $path" >&2; return 1; }
  else
    [[ -f "$path" ]] || { echo "$label is not a regular file: $path" >&2; return 1; }
  fi

  stat_out="$(stat -Lc '%U %G %a' "$path" 2>/dev/null || true)"
  if [[ -z "$stat_out" ]]; then
    echo "Unable to stat $label: $path" >&2
    return 1
  fi
  IFS=' ' read -r owner group mode <<<"$stat_out"
  if [[ "$owner" != "$expected_owner" || "$group" != "$expected_group" ]]; then
    echo "$label ownership must be $expected_owner:$expected_group (found $owner:$group): $path" >&2
    return 1
  fi
  if ! mode_is_subset "$mode" "$max_mode"; then
    echo "$label permissions too broad (mode $mode, expected <= $max_mode): $path" >&2
    return 1
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

if [[ "$READ_STDIN" -ne 1 ]]; then
  usage
  exit 1
fi
if [[ "$SET_DEFAULT" -eq 1 && -n "$LINUX_USER" ]]; then
  echo "Choose only one target: --linux-user or --default." >&2
  exit 1
fi
if [[ "$SET_DEFAULT" -ne 1 && -z "$LINUX_USER" ]]; then
  usage
  exit 1
fi

CALLER_USER="${SUDO_USER:-}"
if [[ -n "$CALLER_USER" && "$CALLER_USER" != "root" ]]; then
  if [[ "$SET_DEFAULT" -eq 1 ]]; then
    echo "Refusing --default token sync from sudo caller '$CALLER_USER'." >&2
    echo "Use direct root execution for default token management." >&2
    exit 1
  fi
  if [[ "$LINUX_USER" != "$CALLER_USER" ]]; then
    echo "Refusing cross-user token sync (requested=$LINUX_USER caller=$CALLER_USER)." >&2
    exit 1
  fi
fi

if [[ "$SET_DEFAULT" -ne 1 ]]; then
  if ! [[ "$LINUX_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Invalid linux user value." >&2
    exit 1
  fi
  if ! id "$LINUX_USER" >/dev/null 2>&1; then
    echo "Linux user does not exist: $LINUX_USER" >&2
    exit 1
  fi
fi

IFS= read -r TOKEN || true
if [[ -z "${TOKEN:-}" ]]; then
  echo "Empty token from stdin." >&2
  exit 1
fi

if ! [[ "$TOKEN" =~ ^eyJ[[:alnum:]_-]+\.[[:alnum:]_-]+\.[[:alnum:]_-]+$ ]]; then
  echo "Token does not look like a JWT." >&2
  exit 1
fi

install -d -m 750 -o root -g lp "$TOKENS_DIR"
if ! check_secure_path "$TOKENS_DIR" dir root lp 750 "tokens directory"; then
  exit 1
fi

if [[ "$SET_DEFAULT" -eq 1 ]]; then
  TARGET="$TOKENS_DIR/default.jwt"
  tmp_prefix="default"
else
  TARGET="$TOKENS_DIR/${LINUX_USER}.jwt"
  tmp_prefix="$LINUX_USER"
fi
if [[ -e "$TARGET" ]]; then
  if [[ -L "$TARGET" ]]; then
    echo "Refusing to overwrite symlink token file: $TARGET" >&2
    exit 1
  fi
  if [[ ! -f "$TARGET" ]]; then
    echo "Refusing to overwrite non-regular token path: $TARGET" >&2
    exit 1
  fi
  if ! check_secure_path "$TARGET" file root lp 640 "existing token file"; then
    exit 1
  fi
fi

TMP_TARGET="$(mktemp "$TOKENS_DIR/.${tmp_prefix}.jwt.XXXXXX.tmp")"
printf '%s\n' "$TOKEN" > "$TMP_TARGET"
chown root:lp "$TMP_TARGET"
chmod 640 "$TMP_TARGET"
mv -f "$TMP_TARGET" "$TARGET"
TMP_TARGET=""

unset TOKEN
if [[ "$SET_DEFAULT" -eq 1 ]]; then
  echo "Synced default token to $TARGET"
else
  echo "Synced token for user '$LINUX_USER' to $TARGET"
fi
unset CALLER_USER
