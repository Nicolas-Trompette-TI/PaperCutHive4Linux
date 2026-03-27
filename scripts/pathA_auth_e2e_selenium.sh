#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BASE/outputs/pathA-auth-e2e-$TS.txt"
EXT_DIR="$BASE/tools/extensions/pdlopiakikhioinbeibaachakgdgllff/unpacked"
UD="$BASE/tools/chromium-user-data-auth"
TARGET_URL="${PAPERCUT_HIVE_SETUP_URL:-https://eu.hive.papercut.com/setup-instructions}"
LOGIN_URL="${PAPERCUT_LOGIN_URL:-}"

mkdir -p "$BASE/outputs" "$UD"

source "$BASE/scripts/papercut_auth_load.sh"

{
  echo "=== Path A Auth E2E (Selenium) ==="
  echo "timestamp_utc=$TS"
  echo "target_url=$TARGET_URL"
  echo "login_url=${LOGIN_URL:-<derived-by-script>}"
  echo "user_data_dir=$UD"
  echo "extension_dir=$EXT_DIR"
  echo "login_len=${#PAPERCUT_LOGIN}"
  echo "password_len=${#PAPERCUT_PASSWORD}"
  echo
} | tee "$OUT"

LOGIN_ARGS=()
if [ -n "$LOGIN_URL" ]; then
  LOGIN_ARGS+=(--login-url "$LOGIN_URL")
fi

python3 "$BASE/scripts/pathA_auth_e2e_selenium.py" \
  --login "$PAPERCUT_LOGIN" \
  --password "$PAPERCUT_PASSWORD" \
  --base-url "$TARGET_URL" \
  "${LOGIN_ARGS[@]}" \
  --user-data-dir "$UD" \
  --ext-dir "$EXT_DIR" \
  --outputs-dir "$BASE/outputs" 2>&1 | tee -a "$OUT"

echo | tee -a "$OUT"
echo "=== Path A post-auth extension smoke ===" | tee -a "$OUT"
CHROMIUM_USER_DATA_DIR="$UD" PATHA_SMOKE_URL="$TARGET_URL" \
  "$BASE/scripts/pathA_chromium_extension_smoke.sh" 2>&1 | tee -a "$OUT"

echo "Wrote: $OUT"
