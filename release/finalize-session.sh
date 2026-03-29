#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EVENT_LOG="$BASE/scripts/papercut_event_log.sh"

ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
LINUX_USER="${USER}"
PROFILE_DIR=""
ENABLE_NOTIFY=1
BOOTSTRAP_FROM_EXTENSION=1

usage() {
  cat <<EOF
Usage: $0 [options]

Finalize secure deployment from a normal user desktop session:
1) Enable systemd --user token sync timer
2) Bootstrap/sync JWT to CUPS token file (from extension or existing keyring)

Options:
  --org-id <ORG_ID>         optional in extension mode, required with --no-bootstrap-from-extension
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --profile-dir <dir>       browser profile dir for extension token extraction
  --no-bootstrap-from-extension
                             skip extension token extraction and sync existing keyring token only
  --no-notify               disable desktop notifications
  -h, --help                show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --no-bootstrap-from-extension) BOOTSTRAP_FROM_EXTENSION=0; shift ;;
    --no-notify) ENABLE_NOTIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$LINUX_USER" != "$USER" ]]; then
  echo "Run this script as the target user session ($LINUX_USER)." >&2
  exit 1
fi
if ! id -Gn | tr ' ' '\n' | grep -Fxq "papercut-hive-users"; then
  echo "Current session is missing active group 'papercut-hive-users'." >&2
  echo "Log out/in (or open a new login session), then rerun finalize-session." >&2
  exit 1
fi

notify_user() {
  local level="$1"
  local message="$2"
  [[ $ENABLE_NOTIFY -eq 1 ]] || return 0
  "$BASE/scripts/papercut_notify.sh" --level "$level" --title "PaperCut Hive Driver" --message "$message" || true
}

log_event() {
  [[ -x "$EVENT_LOG" ]] || return 0
  "$EVENT_LOG" "$@" || true
}

on_error() {
  log_event --component finalize --level error --event failed --message "Finalize failed"
  notify_user error "Finalize failed. Check terminal logs."
}
trap on_error ERR

log_event --component finalize --event start --message "Finalize started" --kv "user=$LINUX_USER"

systemctl --user daemon-reload
systemctl --user enable --now papercut-hive-token-sync.timer
if [[ $ENABLE_NOTIFY -eq 1 ]]; then
  if [[ -f "$HOME/.config/systemd/user/papercut-hive-alert-notify.timer" ]] || systemctl --user list-unit-files papercut-hive-alert-notify.timer >/dev/null 2>&1; then
    systemctl --user enable --now papercut-hive-alert-notify.timer || true
  else
    echo "Info: papercut-hive-alert-notify.timer not installed in this session yet." >&2
  fi
fi
systemctl --user reset-failed papercut-hive-token-sync.service || true

if [[ $BOOTSTRAP_FROM_EXTENSION -eq 1 ]]; then
  store_cmd=(
    "$BASE/scripts/papercut_secret_store.sh"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --from-extension
    --sync-now
  )
  if [[ -n "$ORG_ID" ]]; then
    store_cmd+=(--org-id "$ORG_ID")
  fi
  if [[ -n "$PROFILE_DIR" ]]; then
    store_cmd+=(--profile-dir "$PROFILE_DIR")
  fi
  "${store_cmd[@]}"
else
  if [[ -z "$ORG_ID" ]]; then
    echo "--org-id is required when --no-bootstrap-from-extension is used." >&2
    exit 1
  fi
  "$BASE/scripts/papercut_secret_sync.sh" \
    --org-id "$ORG_ID" \
    --cloud-host "$CLOUD_HOST" \
    --linux-user "$LINUX_USER" \
    --verbose
fi
systemctl --user start papercut-hive-token-sync.service

echo "Finalize session complete."
log_event --component finalize --event complete --message "Finalize completed successfully"
notify_user info "Finalize complete. Secure token sync is active."
