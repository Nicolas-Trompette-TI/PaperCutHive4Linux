#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/papercut-installer.exe" >&2
  exit 1
fi
BIN="$1"
if [[ ! -f "$BIN" ]]; then
  echo "Binary not found: $BIN" >&2
  exit 1
fi

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/binary-baseline-$TS.txt"

{
  echo "=== Binary Baseline ==="
  echo "timestamp_utc=$TS"
  echo "binary=$BIN"
  echo

  echo "[File + Hash]"
  file "$BIN"
  sha256sum "$BIN"
  echo

  echo "[PE Header Summary]"
  objdump -x "$BIN" | sed -n '1,70p'
  echo

  echo "[Security Directory + Imports]"
  objdump -x "$BIN" | grep -E 'Security Directory|DLL Name:'
  echo

  echo "[Inno Setup markers]"
  strings -n 8 "$BIN" | grep -E 'Inno Setup Setup Data|Inno Setup Messages' || true
  echo

  echo "[Product strings (UTF-16)]"
  strings -el "$BIN" | grep -E 'CompanyName|ProductName|ProductVersion|OriginalFileName|PaperCut Hive Setup|PaperCut Hive' || true
} | tee "$OUT"

echo "Wrote: $OUT"
