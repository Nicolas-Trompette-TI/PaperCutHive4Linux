#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/runtime-prereqs-$TS.txt"

have() { command -v "$1" >/dev/null 2>&1; }

{
  echo "=== Runtime Prerequisites ==="
  echo "timestamp_utc=$TS"
  echo

  echo "[System]"
  uname -a
  if [[ -f /etc/os-release ]]; then
    cat /etc/os-release
  fi
  echo

  echo "[Path A: Chrome extension path prerequisites]"
  for b in google-chrome chromium chromium-browser; do
    if have "$b"; then
      echo "$b=present ($(command -v "$b"))"
    else
      echo "$b=missing"
    fi
  done
  if have xdg-open; then
    echo "xdg-open=present"
  else
    echo "xdg-open=missing"
  fi
  echo

  echo "[Path B: CUPS direct IPP/IPPS prerequisites]"
  for b in lp lpstat lpadmin cupsctl ipptool; do
    if have "$b"; then
      echo "$b=present ($(command -v "$b"))"
    else
      echo "$b=missing"
    fi
  done
  echo

  echo "[Generic tools]"
  for b in curl openssl python3; do
    if have "$b"; then
      echo "$b=present ($(command -v "$b"))"
    else
      echo "$b=missing"
    fi
  done
} | tee "$OUT"

echo "Wrote: $OUT"
