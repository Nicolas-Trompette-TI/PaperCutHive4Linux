#!/usr/bin/env bash
set -euo pipefail

PRINTER_NAME="${1:-PaperCut-Hive-Lite}"
TEST_FILE="${2:-$HOME/test.txt}"

echo "test" > "$TEST_FILE"
echo "Created: $TEST_FILE"

if ! command -v lp >/dev/null 2>&1; then
  echo "lp command not found. Install cups-client first." >&2
  exit 1
fi

JOB_OUT="$(lp -d "$PRINTER_NAME" "$TEST_FILE" 2>&1)" || {
  echo "$JOB_OUT" >&2
  exit 1
}

echo "$JOB_OUT"
echo "Submitted test print to '$PRINTER_NAME'"
