#!/usr/bin/env bash
set -euo pipefail

LEVEL="info"
TITLE="PaperCut Hive Driver"
MESSAGE=""
TIMEOUT_MS=5000
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Best-effort desktop notification helper.
Falls back to stderr if desktop notifications are unavailable.

Options:
  --level <info|warning|error>   default: info
  --title <text>                 default: PaperCut Hive Driver
  --message <text>               required
  --timeout-ms <ms>              default: 5000
  --dry-run                      print action only
  -h, --help                     show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) LEVEL="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MESSAGE" ]]; then
  echo "--message is required." >&2
  usage
  exit 1
fi

urgency="normal"
case "$LEVEL" in
  info) urgency="normal" ;;
  warning) urgency="normal" ;;
  error) urgency="critical" ;;
  *) echo "Invalid --level: $LEVEL" >&2; exit 1 ;;
esac

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] notify level=$LEVEL title=$TITLE message=$MESSAGE"
  exit 0
fi

if command -v notify-send >/dev/null 2>&1; then
  if notify-send -u "$urgency" -t "$TIMEOUT_MS" "$TITLE" "$MESSAGE" >/dev/null 2>&1; then
    exit 0
  fi
fi

printf '[%s] %s: %s\n' "$LEVEL" "$TITLE" "$MESSAGE" >&2
