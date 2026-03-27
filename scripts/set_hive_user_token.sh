#!/usr/bin/env bash
set -euo pipefail

LINUX_USER=""
TOKEN=""
SET_DEFAULT=0
USE_ID_TOKEN=0

usage() {
  cat <<EOF
Usage:
  $0 --linux-user <username> [--jwt <token>] [--id-token]
  $0 --default [--jwt <token>] [--id-token]

Stores token in:
- /etc/papercut-hive-lite/tokens/<linux-user>.jwt
- /etc/papercut-hive-lite/tokens/default.jwt (with --default)

By default token is treated as USER JWT.
Use --id-token to store into /etc/papercut-hive-lite/config.env as PAPERCUT_ID_TOKEN.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --jwt) TOKEN="${2:-}"; shift 2 ;;
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
  CFG="/etc/papercut-hive-lite/config.env"
  if [[ ! -f "$CFG" ]]; then
    echo "Missing config: $CFG" >&2
    exit 1
  fi
  sudo sed -i '/^PAPERCUT_ID_TOKEN=/d' "$CFG"
  printf 'PAPERCUT_ID_TOKEN="%s"\n' "$TOKEN" | sudo tee -a "$CFG" >/dev/null
  sudo chown root:lp "$CFG"
  sudo chmod 640 "$CFG"
  echo "Stored PAPERCUT_ID_TOKEN in $CFG"
  exit 0
fi

TARGET=""
if [[ "$SET_DEFAULT" -eq 1 ]]; then
  TARGET="/etc/papercut-hive-lite/tokens/default.jwt"
else
  TARGET="/etc/papercut-hive-lite/tokens/${LINUX_USER}.jwt"
fi

sudo mkdir -p /etc/papercut-hive-lite/tokens
sudo chown root:lp /etc/papercut-hive-lite/tokens
sudo chmod 750 /etc/papercut-hive-lite/tokens
printf '%s\n' "$TOKEN" | sudo tee "$TARGET" >/dev/null
sudo chown root:lp "$TARGET"
sudo chmod 640 "$TARGET"
echo "Stored JWT in $TARGET"
