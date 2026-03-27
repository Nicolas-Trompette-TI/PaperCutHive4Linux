#!/usr/bin/env bash
set -euo pipefail

PRINTER_NAME="PaperCut-Hive-Lite"
TEST_FILE="${HOME}/papercut-hive-selftest.txt"

usage() {
  cat <<EOF
Usage: $0 [--printer-name <name>]

Runs a lightweight post-install self-test:
1) validates queue presence
2) prints a test file
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

printf 'papercut hive self-test %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TEST_FILE"
REQ_LINE="$(lp -d "$PRINTER_NAME" "$TEST_FILE")"
JOB_ID="$(echo "$REQ_LINE" | sed -n 's/^request id is \([^ ]*\).*/\1/p')"

if [[ -z "$JOB_ID" ]]; then
  echo "Unable to parse job id from lp output: $REQ_LINE" >&2
  exit 1
fi

sleep 2
if ! lpstat -W completed -o "$PRINTER_NAME" | grep -q "^${JOB_ID}[[:space:]]"; then
  echo "Job not yet completed in CUPS history: $JOB_ID" >&2
  exit 1
fi

echo "Self-test OK: $JOB_ID"
