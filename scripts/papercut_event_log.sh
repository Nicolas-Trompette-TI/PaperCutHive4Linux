#!/usr/bin/env bash
set -euo pipefail

LEVEL="info"
COMPONENT="papercut"
EVENT=""
MESSAGE=""
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/papercut-hive-lite"
LOG_FILE=""
MAX_LINES=5000
DRY_RUN=0
KV_PAIRS=()

usage() {
  cat <<USAGE
Usage: $0 --event <name> [options]

Append a lightweight structured JSON event without secrets.

Options:
  --event <name>             required event name
  --level <info|warning|error> default: info
  --component <name>         default: papercut
  --message <text>           optional human-friendly message
  --state-dir <dir>          default: \$XDG_STATE_HOME/papercut-hive-lite
  --log-file <path>          override JSONL output path
  --max-lines <n>            default: 5000
  --kv <key=value>           additional non-secret fields (repeatable)
  --dry-run                  print JSON event instead of writing
  -h, --help                 show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) EVENT="${2:-}"; shift 2 ;;
    --level) LEVEL="${2:-}"; shift 2 ;;
    --component) COMPONENT="${2:-}"; shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --max-lines) MAX_LINES="${2:-}"; shift 2 ;;
    --kv) KV_PAIRS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$EVENT" ]]; then
  echo "--event is required" >&2
  usage
  exit 1
fi

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$STATE_DIR/events.jsonl"
fi

case "$LEVEL" in
  info|warning|error) ;;
  *) echo "Invalid level: $LEVEL" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

json_line="$(
python3 - "$LEVEL" "$COMPONENT" "$EVENT" "$MESSAGE" "${KV_PAIRS[@]}" <<'PY'
import datetime as dt
import json
import re
import sys

level = sys.argv[1]
component = sys.argv[2]
event = sys.argv[3]
message = sys.argv[4]
kv_pairs = sys.argv[5:]

sensitive = re.compile(r"(token|jwt|password|secret)", re.IGNORECASE)
entry = {
    "timestamp_utc": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "level": level,
    "component": component,
    "event": event,
}
if message:
    entry["message"] = message

for item in kv_pairs:
    if "=" not in item:
        continue
    k, v = item.split("=", 1)
    k = k.strip()
    if not k:
        continue
    if sensitive.search(k):
        continue
    entry[k] = v

print(json.dumps(entry, separators=(",", ":"), ensure_ascii=True))
PY
)"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "$json_line"
  exit 0
fi

printf '%s\n' "$json_line" >>"$LOG_FILE"

if [[ "$MAX_LINES" =~ ^[0-9]+$ ]] && [[ "$MAX_LINES" -gt 0 ]]; then
  line_count="$(wc -l <"$LOG_FILE" || echo 0)"
  if [[ "$line_count" -gt "$MAX_LINES" ]]; then
    tail -n "$MAX_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
  fi
fi
