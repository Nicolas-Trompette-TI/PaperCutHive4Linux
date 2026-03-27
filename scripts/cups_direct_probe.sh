#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---dry-run}"
if [[ "$MODE" != "--dry-run" && "$MODE" != "--apply" ]]; then
  echo "Usage: PRINTER_URI='ipps://host/ipp/print' $0 [--dry-run|--apply]" >&2
  exit 1
fi

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/cups-probe-$TS.txt"
QUEUE="papercut_probe_${TS,,}"

have() { command -v "$1" >/dev/null 2>&1; }

{
  echo "=== CUPS Direct Probe ==="
  echo "timestamp_utc=$TS"
  echo "mode=$MODE"
  echo

  for b in lp lpstat lpadmin; do
    if have "$b"; then
      echo "$b=present ($(command -v "$b"))"
    else
      echo "$b=missing"
    fi
  done

  if [[ -z "${PRINTER_URI:-}" ]]; then
    echo "PRINTER_URI=missing"
    echo "Set PRINTER_URI (for example: ipps://printer.example/ipp/print)"
    exit 0
  fi

  echo "PRINTER_URI=$PRINTER_URI"

  if ! have lpadmin || ! have lp || ! have lpstat; then
    echo "CUPS client/admin commands missing. Cannot execute probe."
    exit 0
  fi

  echo
  echo "[Current queues]"
  lpstat -v || true

  echo
  echo "[Planned commands]"
  echo "lpadmin -p $QUEUE -E -v '$PRINTER_URI' -m everywhere"
  echo "lp -d $QUEUE /etc/hosts"
  echo "lpstat -W not-completed"
  echo "lpadmin -x $QUEUE"

  if [[ "$MODE" == "--apply" ]]; then
    echo
    echo "[Executing]"
    lpadmin -p "$QUEUE" -E -v "$PRINTER_URI" -m everywhere
    lp -d "$QUEUE" /etc/hosts || true
    sleep 2
    lpstat -W not-completed || true
    lpadmin -x "$QUEUE" || true
  fi
} | tee "$OUT"

echo "Wrote: $OUT"
