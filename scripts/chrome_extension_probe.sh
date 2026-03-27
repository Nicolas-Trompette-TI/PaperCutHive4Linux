#!/usr/bin/env bash
set -euo pipefail

EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
EXT_URL="https://chromewebstore.google.com/detail/papercut-hive-secure-prin/${EXT_ID}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/chrome-extension-probe-$TS.txt"

have() { command -v "$1" >/dev/null 2>&1; }

{
  echo "=== Chrome Extension Probe (Path A) ==="
  echo "timestamp_utc=$TS"
  echo "extension_id=$EXT_ID"
  echo "extension_url=$EXT_URL"
  echo

  browser_bin=""
  for b in google-chrome chromium chromium-browser; do
    if have "$b"; then
      browser_bin="$b"
      echo "browser=$b ($(command -v "$b"))"
      break
    fi
  done
  if [[ -z "$browser_bin" ]]; then
    echo "browser=missing"
  fi

  echo
  echo "[Local extension paths]"
  paths=(
    "$HOME/.config/google-chrome/Default/Extensions/$EXT_ID"
    "$HOME/.config/chromium/Default/Extensions/$EXT_ID"
    "$HOME/.config/chromium-browser/Default/Extensions/$EXT_ID"
  )

  installed="no"
  for p in "${paths[@]}"; do
    if [[ -d "$p" ]]; then
      installed="yes"
      echo "$p=present"
      find "$p" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's/^/  version_dir=/'
    else
      echo "$p=missing"
    fi
  done

  echo
  echo "extension_installed_local=$installed"
  echo

  echo "[Manual step commands]"
  echo "Open extension page: $EXT_URL"
  if [[ -n "$browser_bin" ]]; then
    echo "Example: $browser_bin '$EXT_URL'"
  fi
  echo
  echo "After install/linking, record outcomes in templates/test-log.md:"
  echo "- PaperCut Printer appears"
  echo "- Print A4 from browser"
  echo "- Secure release"
  echo "- Job Log fields"
} | tee "$OUT"

echo "Wrote: $OUT"
