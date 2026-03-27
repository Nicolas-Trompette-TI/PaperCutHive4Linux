#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$BASE/.secrets"
AUTH_FILE="$SECRETS_DIR/papercut_auth.env"

umask 077
mkdir -p "$SECRETS_DIR"

read -r -p "PaperCut login: " PAPERCUT_LOGIN
read -r -s -p "PaperCut password: " PAPERCUT_PASSWORD
echo

TMP_FILE="$(mktemp "$SECRETS_DIR/.papercut_auth.XXXXXX")"
{
  printf 'PAPERCUT_LOGIN=%q\n' "$PAPERCUT_LOGIN"
  printf 'PAPERCUT_PASSWORD=%q\n' "$PAPERCUT_PASSWORD"
} > "$TMP_FILE"

mv -f "$TMP_FILE" "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

echo "Stored credentials in: $AUTH_FILE"
echo "Use: source \"$BASE/scripts/papercut_auth_load.sh\""
