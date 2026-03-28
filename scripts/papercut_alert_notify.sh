#!/usr/bin/env bash
set -euo pipefail

ALERT_DIR="/var/lib/papercut-hive-lite/alerts"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/papercut-hive-lite"
SEEN_FILE=""
NOTIFY_SCRIPT="/usr/local/lib/papercut-hive-lite/papercut_notify.sh"
EVENT_LOG_SCRIPT="/usr/local/lib/papercut-hive-lite/papercut_event_log.sh"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Scans backend alert files and sends one desktop notification per unseen alert.

Options:
  --alert-dir <dir>      default: /var/lib/papercut-hive-lite/alerts
  --state-dir <dir>      default: \$XDG_STATE_HOME/papercut-hive-lite
  --seen-file <path>     override dedup state file path
  --notify-script <path> default: /usr/local/lib/papercut-hive-lite/papercut_notify.sh
  --event-log-script <path> default: /usr/local/lib/papercut-hive-lite/papercut_event_log.sh
  --dry-run              print actions only
  -h, --help             show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert-dir) ALERT_DIR="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --seen-file) SEEN_FILE="${2:-}"; shift 2 ;;
    --notify-script) NOTIFY_SCRIPT="${2:-}"; shift 2 ;;
    --event-log-script) EVENT_LOG_SCRIPT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -x "$EVENT_LOG_SCRIPT" ]]; then
  local_guess="$(cd "$(dirname "$0")" && pwd)/papercut_event_log.sh"
  if [[ -x "$local_guess" ]]; then
    EVENT_LOG_SCRIPT="$local_guess"
  fi
fi

if [[ -z "$SEEN_FILE" ]]; then
  SEEN_FILE="$STATE_DIR/alerts-seen.txt"
fi

mkdir -p "$STATE_DIR"
touch "$SEEN_FILE"
chmod 600 "$SEEN_FILE"

if [[ ! -d "$ALERT_DIR" ]]; then
  exit 0
fi

notify_one() {
  local title="$1"
  local message="$2"
  if [[ -x "$NOTIFY_SCRIPT" ]]; then
    local cmd=("$NOTIFY_SCRIPT" --level error --title "$title" --message "$message")
    if [[ $DRY_RUN -eq 1 ]]; then
      cmd+=(--dry-run)
    fi
    "${cmd[@]}" || true
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] notify title=$title message=$message"
    return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -t 7000 "$title" "$message" >/dev/null 2>&1 || true
  else
    printf '[error] %s: %s\n' "$title" "$message" >&2
  fi
}

log_alert_event() {
  local code="$1"
  local queue="$2"
  local job_id="$3"
  local recovered="${4:-0}"
  [[ -x "$EVENT_LOG_SCRIPT" ]] || return 0
  local cmd=(
    "$EVENT_LOG_SCRIPT"
    --component notify
    --event print-fail
    --level warning
    --message "Print alert detected"
    --kv "code=$code"
    --kv "queue=$queue"
    --kv "job_id=$job_id"
    --kv "auto_recovered=$recovered"
  )
  if [[ $DRY_RUN -eq 1 ]]; then
    cmd+=(--dry-run)
  fi
  "${cmd[@]}" || true
}

attempt_auto_recovery() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] token recovery via papercut-hive-token-sync.service"
    return 0
  fi
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    return 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  if ! systemctl --user list-unit-files papercut-hive-token-sync.service >/dev/null 2>&1; then
    return 1
  fi
  if ! systemctl --user start papercut-hive-token-sync.service >/dev/null 2>&1; then
    return 1
  fi
  if systemctl --user is-failed papercut-hive-token-sync.service >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

while IFS= read -r alert_file; do
  [[ -f "$alert_file" ]] || continue
  alert_id="$(basename "$alert_file")"

  if grep -Fxq "$alert_id" "$SEEN_FILE"; then
    continue
  fi

  alert_user="$(sed -n 's/^user=//p' "$alert_file" | head -n1)"
  [[ -n "$alert_user" ]] || continue
  [[ "$alert_user" == "$USER" ]] || continue

  queue="$(sed -n 's/^queue=//p' "$alert_file" | head -n1)"
  job_id="$(sed -n 's/^job_id=//p' "$alert_file" | head -n1)"
  code="$(sed -n 's/^code=//p' "$alert_file" | head -n1)"
  ts="$(sed -n 's/^timestamp=//p' "$alert_file" | head -n1)"

  [[ -n "$queue" ]] || queue="PaperCut-Hive"
  [[ -n "$job_id" ]] || job_id="unknown"
  [[ -n "$code" ]] || code="submit-failed"
  [[ -n "$ts" ]] || ts="unknown-time"

  recovered=0
  if [[ "$code" == "token-invalid" || "$code" == "missing-token" ]]; then
    if attempt_auto_recovery; then
      recovered=1
      notify_one "PaperCut Hive Session Refreshed" "Token refreshed automatically for $queue. Retry your print now."
    else
      notify_one "PaperCut Hive Session Needed" "Session expired for $queue. Open Chrome/Chromium, reconnect PaperCut Hive extension (login/password if asked), then retry print."
    fi
  else
    notify_one "PaperCut Hive Print Issue" "Queue: $queue | Job: $job_id | Error: $code | Time: $ts"
  fi
  log_alert_event "$code" "$queue" "$job_id" "$recovered"
  echo "$alert_id" >>"$SEEN_FILE"
done < <(find "$ALERT_DIR" -maxdepth 1 -type f -name '*.alert' 2>/dev/null | sort)

# Keep only recent dedup entries to avoid unbounded growth.
if [[ $(wc -l <"$SEEN_FILE") -gt 500 ]]; then
  tail -n 500 "$SEEN_FILE" >"${SEEN_FILE}.tmp"
  mv "${SEEN_FILE}.tmp" "$SEEN_FILE"
  chmod 600 "$SEEN_FILE"
fi
