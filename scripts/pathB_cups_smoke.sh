#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CROOT="$BASE/tools/cups-local/root"
LAB="$BASE/tools/cups-local/lab"
OUT="$BASE/outputs/pathB-smoke-$(date -u +%Y%m%dT%H%M%SZ).txt"
LD_PATH="$CROOT/usr/lib/x86_64-linux-gnu:$CROOT/lib/x86_64-linux-gnu:$CROOT/usr/lib:$CROOT/lib"

LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/sbin/lpadmin" -h 127.0.0.1:8631 -x hive_file_test 2>/dev/null || true
LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/sbin/lpadmin" -h 127.0.0.1:8631 -p hive_file_test -E -v "file:$LAB/printed.out" -m raw

echo 'PaperCut Hive local CUPS test page' > "$LAB/test-page.txt"
LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/bin/lp" -h 127.0.0.1:8631 -d hive_file_test "$LAB/test-page.txt" >/tmp/pathb_lp_submit.txt 2>&1 || true
sleep 1

{
  echo "=== Path B Smoke ==="
  echo "timestamp_utc=$(date -u +%Y%m%dT%H%M%SZ)"
  echo
  echo "[Queue]"
  LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/bin/lpstat" -h 127.0.0.1:8631 -v || true
  echo
  echo "[Jobs]"
  LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/bin/lpstat" -h 127.0.0.1:8631 -W all || true
  echo
  echo "[Submit output]"
  cat /tmp/pathb_lp_submit.txt || true
  echo
  echo "[Page log tail]"
  tail -n 5 "$LAB/var/log/page_log" 2>/dev/null || true
  echo
  echo "[CUPS completion evidence]"
  grep -E "Job completed|Queued on|Send-Document" "$LAB/var/log/error_log" | tail -n 20 || true
} | tee "$OUT"

echo "Wrote: $OUT"
