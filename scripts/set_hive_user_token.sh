#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE="$(cd "$(dirname "$0")/.." && pwd)"
LINUX_USER=""
TOKEN=""
SET_DEFAULT=0
USE_ID_TOKEN=0
ROOT_HELPER="/usr/local/sbin/papercut-hive-token-sync"

usage() {
  cat <<EOF
Usage:
  $0 --linux-user <username> [--token-stdin] [--id-token]
  $0 --default [--token-stdin] [--id-token]

Stores token in:
- /etc/papercut-hive-lite/tokens/<linux-user>.jwt
- /etc/papercut-hive-lite/tokens/default.jwt (with --default)

By default token is treated as USER JWT.
`--id-token` plaintext config storage is deprecated and blocked unless
PAPERCUT_ALLOW_PLAINTEXT_TOKEN=1 is explicitly set.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --token-stdin) IFS= read -r TOKEN || true; shift ;;
    --default) SET_DEFAULT=1; shift ;;
    --id-token) USE_ID_TOKEN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$SET_DEFAULT" -eq 0 && -z "$LINUX_USER" ]]; then
  echo "Need --linux-user or --default" >&2
  usage
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  read -r -s -p "Enter token: " TOKEN
  echo
fi

if [[ -z "$TOKEN" ]]; then
  echo "Token is empty" >&2
  exit 1
fi

if [[ "$USE_ID_TOKEN" -eq 1 ]]; then
  if [[ "${PAPERCUT_ALLOW_PLAINTEXT_TOKEN:-0}" != "1" ]]; then
    echo "Refusing plaintext id-token config storage by default." >&2
    echo "Set PAPERCUT_ALLOW_PLAINTEXT_TOKEN=1 only for temporary break-glass debugging." >&2
    exit 1
  fi
  CFG="/etc/papercut-hive-lite/config.env"
  if [[ ! -f "$CFG" ]]; then
    echo "Missing config: $CFG" >&2
    exit 1
  fi
  if ! printf '%s\n' "$TOKEN" | sudo /bin/bash -c '
set -euo pipefail
umask 077
CFG="$1"

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

if [[ -L "$CFG" || ! -f "$CFG" ]]; then
  echo "Refusing insecure config path: $CFG" >&2
  exit 1
fi

stat_out="$(stat -Lc "%U %G %a" "$CFG" 2>/dev/null || true)"
if [[ -z "$stat_out" ]]; then
  echo "Unable to stat config: $CFG" >&2
  exit 1
fi
IFS=" " read -r owner group mode <<<"$stat_out"
if [[ "$owner" != "root" || "$group" != "lp" ]]; then
  echo "Config ownership must be root:lp (found $owner:$group)." >&2
  exit 1
fi
if ! mode_is_subset "$mode" 640; then
  echo "Config permissions too broad: $mode (expected <= 640)." >&2
  exit 1
fi

IFS= read -r token || true
if [[ -z "$token" ]]; then
  echo "Empty id token." >&2
  exit 1
fi

tmp_cfg="$(mktemp "$(dirname "$CFG")/.config.env.XXXXXX.tmp")"
grep -v "^PAPERCUT_ID_TOKEN=" "$CFG" > "$tmp_cfg" || true
printf "PAPERCUT_ID_TOKEN=\"%s\"\\n" "$token" >> "$tmp_cfg"
chown root:lp "$tmp_cfg"
chmod 640 "$tmp_cfg"
mv -f "$tmp_cfg" "$CFG"
' _ "$CFG"; then
    echo "Failed to store PAPERCUT_ID_TOKEN in $CFG" >&2
    exit 1
  fi
  unset TOKEN
  echo "Stored PAPERCUT_ID_TOKEN in $CFG"
  exit 0
fi

TARGET=""
if [[ "$SET_DEFAULT" -eq 1 ]]; then
  TARGET="/etc/papercut-hive-lite/tokens/default.jwt"
else
  TARGET="/etc/papercut-hive-lite/tokens/${LINUX_USER}.jwt"
fi

helper_path="$ROOT_HELPER"
if [[ ! -x "$helper_path" ]]; then
  helper_path="$BASE/scripts/papercut_hive_token_sync_root.sh"
fi
if [[ ! -x "$helper_path" ]]; then
  echo "Missing token sync helper: $ROOT_HELPER (and local fallback script)." >&2
  exit 1
fi

helper_cmd=(sudo "$helper_path" --stdin)
if [[ "$SET_DEFAULT" -eq 1 ]]; then
  helper_cmd+=(--default)
else
  helper_cmd+=(--linux-user "$LINUX_USER")
fi
printf '%s\n' "$TOKEN" | "${helper_cmd[@]}" >/dev/null
unset TOKEN
echo "Stored JWT in $TARGET"
