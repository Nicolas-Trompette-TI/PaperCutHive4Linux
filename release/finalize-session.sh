#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"

ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
LINUX_USER="${USER}"
PROFILE_DIR=""
ENABLE_NOTIFY=1

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Finalize secure deployment from a normal user desktop session:
1) Enable systemd --user token sync timer
2) Store JWT in OS keyring (from extension) and sync to CUPS token file

Options:
  --org-id <ORG_ID>         required
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --profile-dir <dir>       browser profile dir for extension token extraction
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
    --no-notify) ENABLE_NOTIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required." >&2
  usage
  exit 1
fi

if [[ "$LINUX_USER" != "$USER" ]]; then
  echo "Run this script as the target user session ($LINUX_USER)." >&2
  exit 1
fi

notify_user() {
  local level="$1"
  local message="$2"
  [[ $ENABLE_NOTIFY -eq 1 ]] || return 0
  "$BASE/scripts/papercut_notify.sh" --level "$level" --title "PaperCut Hive Driver" --message "$message" || true
}

on_error() {
  notify_user error "Finalize failed. Check terminal logs."
}
trap on_error ERR

systemctl --user daemon-reload
systemctl --user enable --now papercut-hive-token-sync.timer
if [[ $ENABLE_NOTIFY -eq 1 ]]; then
  systemctl --user enable --now papercut-hive-alert-notify.timer || true
fi
systemctl --user reset-failed papercut-hive-token-sync.service || true

store_cmd=(
  "$BASE/scripts/papercut_secret_store.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --from-extension
  --sync-now
)
if [[ -n "$PROFILE_DIR" ]]; then
  store_cmd+=(--profile-dir "$PROFILE_DIR")
fi
"${store_cmd[@]}"
systemctl --user start papercut-hive-token-sync.service

echo "Finalize session complete."
notify_user info "Finalize complete. Secure token sync is active."
