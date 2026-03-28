#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EVENT_LOG="$BASE/scripts/papercut_event_log.sh"

PRINTER_NAME="PaperCut-Hive-TIF"
LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
PROFILE_DIR=""
AUTO_YES=0
DRY_RUN=0
ENABLE_NOTIFY=1

RC_WARN=2
RC_DEP_REFUSED=20
RC_DEP_FAIL=21
RC_CRITICAL=22

usage() {
  cat <<USAGE
Usage: $0 [options]

Repair mode for PaperCut Hive Driver:
1) run doctor preflight
2) reinstall/repair backend + queue + units
3) re-run doctor to verify final state

Options:
  --org-id <ORG_ID>         optional if readable from existing config
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --printer-name <name>     default: PaperCut-Hive-TIF
  --profile-dir <dir>       optional browser profile root
  --no-notify               disable desktop notifications
  -y, --yes                 auto-confirm doctor dependency prompts
  --dry-run                 print actions only
  -h, --help                show help
USAGE
}

log_event() {
  [[ -x "$EVENT_LOG" ]] || return 0
  "$EVENT_LOG" "$@" || true
}

resolve_config_value() {
  local key="$1"
  local cfg="/etc/papercut-hive-lite/config.env"
  [[ -r "$cfg" ]] || return 0
  sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$cfg" | head -n1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --no-notify) ENABLE_NOTIFY=0; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  ORG_ID="$(resolve_config_value PAPERCUT_ORG_ID)"
fi
if [[ "$CLOUD_HOST" == "eu.hive.papercut.com" ]]; then
  cfg_host="$(resolve_config_value PAPERCUT_CLOUD_HOST)"
  if [[ -n "$cfg_host" ]]; then
    CLOUD_HOST="$cfg_host"
  fi
fi

if [[ -z "$ORG_ID" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "PaperCut Org ID for repair: " ORG_ID
  fi
fi
if [[ -z "$ORG_ID" ]]; then
  echo "Repair needs --org-id (or readable /etc/papercut-hive-lite/config.env)." >&2
  exit $RC_CRITICAL
fi

log_event --component repair --event start --message "Repair started" --kv "printer=$PRINTER_NAME" --kv "dry_run=$DRY_RUN"

doctor_cmd=(
  "$BASE/scripts/papercut_doctor.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
)
[[ $AUTO_YES -eq 1 ]] && doctor_cmd+=(--yes)
[[ $DRY_RUN -eq 1 ]] && doctor_cmd+=(--dry-run)

set +e
"${doctor_cmd[@]}"
pre_rc=$?
set -e

if [[ $pre_rc -eq $RC_DEP_REFUSED || $pre_rc -eq $RC_DEP_FAIL ]]; then
  log_event --component repair --level error --event preflight-failed --message "Repair aborted by dependency preflight" --kv "code=$pre_rc"
  exit "$pre_rc"
fi

echo "[repair] applying runtime reinstall"
install_cmd=(
  "$BASE/release/install.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
  --no-bootstrap-from-extension
)
[[ $ENABLE_NOTIFY -eq 0 ]] && install_cmd+=(--no-notify)
[[ -n "$PROFILE_DIR" ]] && install_cmd+=(--profile-dir "$PROFILE_DIR")
[[ $DRY_RUN -eq 1 ]] && install_cmd+=(--dry-run)
"${install_cmd[@]}"

if [[ $DRY_RUN -eq 0 ]]; then
  echo "[repair] re-enable user timers when possible"
  if [[ "$LINUX_USER" == "$USER" && -n "${DBUS_SESSION_BUS_ADDRESS:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
    systemctl --user daemon-reload || true
    systemctl --user enable --now papercut-hive-token-sync.timer || true
    if [[ $ENABLE_NOTIFY -eq 1 ]]; then
      systemctl --user enable --now papercut-hive-alert-notify.timer || true
    fi

    if ! "$BASE/scripts/papercut_secret_sync.sh" --org-id "$ORG_ID" --cloud-host "$CLOUD_HOST" --linux-user "$LINUX_USER" --auto-refresh-from-extension --verbose; then
      echo "[repair] token sync not completed automatically; run finalize-session in desktop session." >&2
    fi
  else
    echo "[repair] user DBus session not available; run finalize-session manually after repair." >&2
  fi
fi

echo "[repair] final doctor verification"
set +e
"${doctor_cmd[@]}"
post_rc=$?
set -e

if [[ $post_rc -eq $RC_CRITICAL ]]; then
  log_event --component repair --level error --event complete --message "Repair completed with critical issues" --kv "code=$post_rc"
  exit $RC_CRITICAL
fi
if [[ $post_rc -eq $RC_WARN ]]; then
  log_event --component repair --level warning --event complete --message "Repair completed with warnings" --kv "code=$post_rc"
  exit $RC_WARN
fi
if [[ $post_rc -eq $RC_DEP_REFUSED || $post_rc -eq $RC_DEP_FAIL ]]; then
  log_event --component repair --level error --event complete --message "Repair verification dependency failure" --kv "code=$post_rc"
  exit "$post_rc"
fi

log_event --component repair --level info --event complete --message "Repair completed successfully" --kv "code=0"
exit 0
