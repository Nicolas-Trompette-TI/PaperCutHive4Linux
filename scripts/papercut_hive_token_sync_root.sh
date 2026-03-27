#!/usr/bin/env bash
set -euo pipefail

LINUX_USER=""
READ_STDIN=0

usage() {
  cat <<EOF
Usage: $0 --linux-user <username> --stdin

Reads a PaperCut JWT from stdin and writes:
  /etc/papercut-hive-lite/tokens/<username>.jwt

This script is intended to be run as root via restricted sudoers.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

if [[ -z "$LINUX_USER" || "$READ_STDIN" -ne 1 ]]; then
  usage
  exit 1
fi

if ! [[ "$LINUX_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Invalid linux user value." >&2
  exit 1
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

install -d -m 750 -o root -g lp /etc/papercut-hive-lite/tokens
TARGET="/etc/papercut-hive-lite/tokens/${LINUX_USER}.jwt"
printf '%s\n' "$TOKEN" > "$TARGET"
chown root:lp "$TARGET"
chmod 640 "$TARGET"

unset TOKEN
echo "Synced token for user '$LINUX_USER' to $TARGET"
