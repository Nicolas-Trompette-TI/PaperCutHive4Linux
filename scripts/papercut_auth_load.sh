#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTH_FILE="$BASE/.secrets/papercut_auth.env"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Missing auth file: $AUTH_FILE" >&2
  echo "Run: $BASE/scripts/papercut_auth_store.sh" >&2
  return 1 2>/dev/null || exit 1
fi

set -a
# shellcheck disable=SC1090
source "$AUTH_FILE"
set +a

if [[ -z "${PAPERCUT_LOGIN:-}" || -z "${PAPERCUT_PASSWORD:-}" ]]; then
  echo "Auth file loaded but PAPERCUT_LOGIN/PAPERCUT_PASSWORD are empty." >&2
  return 1 2>/dev/null || exit 1
fi

echo "PaperCut credentials exported for current shell."
