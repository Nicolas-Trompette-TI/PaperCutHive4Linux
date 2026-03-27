#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$BASE/.secrets"
AUTH_FILE="$SECRETS_DIR/papercut_auth.env"

if [[ -f "$AUTH_FILE" ]]; then
  if command -v shred >/dev/null 2>&1; then
    shred -u "$AUTH_FILE"
  else
    rm -f "$AUTH_FILE"
  fi
fi

rmdir "$SECRETS_DIR" 2>/dev/null || true
unset PAPERCUT_LOGIN PAPERCUT_PASSWORD || true

echo "PaperCut secret file removed."
