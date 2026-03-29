#!/usr/bin/env bash
set -euo pipefail

PRINTER_NAME="PaperCut-Hive-TIF"
TEST_FILE="${HOME}/papercut-hive-verify.txt"

usage() {
  cat <<EOF
Usage: $0 [--printer-name <name>]

Runs a lightweight post-install verification:
1) validates queue presence
2) prints a verification file
3) checks completed jobs contains latest request
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if ! lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
  echo "Queue not found: $PRINTER_NAME" >&2
  exit 1
fi

printf 'papercut hive verify %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TEST_FILE"
REQ_LINE="$(lp -d "$PRINTER_NAME" "$TEST_FILE")"
JOB_ID="$(echo "$REQ_LINE" | sed -n 's/^request id is \([^ ]*\).*/\1/p')"

if [[ -z "$JOB_ID" ]]; then
  echo "Unable to parse job id from lp output: $REQ_LINE" >&2
  exit 1
fi

attempt=0
max_attempts=30
while (( attempt < max_attempts )); do
  if lpstat -W completed -o "$PRINTER_NAME" | grep -q "^${JOB_ID}[[:space:]]"; then
    echo "Verification OK: $JOB_ID"
    exit 0
  fi
  sleep 1
  attempt=$((attempt + 1))
done

echo "Job not yet completed in CUPS history: $JOB_ID" >&2
echo "Queue status: $(lpstat -p "$PRINTER_NAME" -l 2>/dev/null | tr '\n' ' ')" >&2
if lpstat -W not-completed -o "$PRINTER_NAME" 2>/dev/null | grep -q "^${JOB_ID}[[:space:]]"; then
  echo "Job is still in not-completed set: $JOB_ID" >&2
fi
exit 1
