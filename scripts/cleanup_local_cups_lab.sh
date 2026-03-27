#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$BASE/tools/cups-local/lab"
if [ -f "$LAB/cupsd.pid" ]; then
  kill "$(cat "$LAB/cupsd.pid")" 2>/dev/null || true
  rm -f "$LAB/cupsd.pid"
fi
pkill -f '^.*/tools/cups-local/root/usr/sbin/cupsd.*cupsd.conf' || true
echo "CUPS lab stopped"
