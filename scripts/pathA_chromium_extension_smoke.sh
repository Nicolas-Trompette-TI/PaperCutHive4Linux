#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
BIN_DIR="$BASE/tools/chromium-local/extracted/usr/lib/chromium"
BIN="$BIN_DIR/chromium"
EXT_DIR="$BASE/tools/extensions/$EXT_ID/unpacked"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
UD="${CHROMIUM_USER_DATA_DIR:-$BASE/tools/chromium-user-data-ext}"
TARGET_URL="${PATHA_SMOKE_URL:-chrome-extension://$EXT_ID/manifest.json}"
OUT="$BASE/outputs/pathA-smoke-$TS.txt"
DOM="$BASE/outputs/pathA-chromium-extension-dom-$TS.txt"
ERR="$BASE/outputs/pathA-chromium-extension-stderr-$TS.txt"

LD_PATH="$BIN_DIR:$BASE/tools/chromium-local/sysroot/lib/x86_64-linux-gnu:$BASE/tools/chromium-local/sysroot/usr/lib/x86_64-linux-gnu:$BASE/tools/chromium-local/sysroot/usr/lib:$BASE/tools/chromium-local/sysroot/lib"
mkdir -p "$UD"

(
  cd "$BIN_DIR"
  LD_LIBRARY_PATH="$LD_PATH" "$BIN" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --enable-logging=stderr --v=1 \
    --user-data-dir="$UD" \
    --disable-extensions-except="$EXT_DIR" \
    --load-extension="$EXT_DIR" \
    --dump-dom "$TARGET_URL" \
    > "$DOM" 2> "$ERR" || true
)

{
  echo "=== Path A Smoke ==="
  echo "timestamp_utc=$TS"
  echo "extension_id=$EXT_ID"
  echo "user_data_dir=$UD"
  echo "target_url=$TARGET_URL"
  echo
  echo "[Extension service-worker evidence]"
  grep -E "starting printprovider|\[linking\]|auth-token|PMITC Printer\(Chrome\)|claim print client identity|application is linked|failed to link application|token_not_found|retrieved auth-token cookie|no auth-token cookie found" "$ERR" || true
  echo
  echo "[Blocked URL evidence]"
  grep -E "ERR_BLOCKED_BY_CLIENT|This page has been blocked by Chromium" "$DOM" || true
  echo
  echo "[Output files]"
  echo "stderr=$ERR"
  echo "dom=$DOM"
} | tee "$OUT"

echo "Wrote: $OUT"
