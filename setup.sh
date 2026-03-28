#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"

ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
LINUX_USER="${USER}"
PRINTER_NAME="PaperCut-Hive-TIF"
PROFILE_DIR=""
NO_BOOTSTRAP=0
SKIP_VERIFY=0
DRY_RUN=0
AUTO_YES=0
ENABLE_NOTIFY=1
PYTHON_MODE="auto"
MODE="setup"

RC_WARN=2
RC_DEP_REFUSED=20
RC_DEP_FAIL=21
RC_CRITICAL=22

usage() {
  cat <<USAGE
Usage: $0 [mode] [options]

Modes:
  (default)    install/finalize/verify with mandatory doctor preflight
  --doctor     run doctor checks only
  --repair     run doctor + automatic repair

Options:
  --org-id <ORG_ID>             optional in doctor mode, required otherwise
  --cloud-host <host>           default: eu.hive.papercut.com
  --linux-user <user>           default: current user
  --printer-name <name>         default: PaperCut-Hive-TIF
  --profile-dir <dir>           browser profile dir (extension bootstrap)
  --no-bootstrap-from-extension skip extension -> keyring bootstrap
  --skip-verify                 do not run release/verify-print.sh
  --python-mode <auto|apt-only> default: auto
  --no-notify                   disable desktop notifications
  -y, --yes                     accept interactive prompts
  --dry-run                     print actions without applying
  -h, --help                    show help
USAGE
}

resolve_config_value() {
  local key="$1"
  local cfg="/etc/papercut-hive-lite/config.env"
  [[ -r "$cfg" ]] || return 0
  sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$cfg" | head -n1
}

log_event() {
  if [[ -x "$BASE/scripts/papercut_event_log.sh" ]]; then
    "$BASE/scripts/papercut_event_log.sh" "$@" || true
  fi
}

notify_user() {
  local level="$1"
  local message="$2"
  [[ $ENABLE_NOTIFY -eq 1 ]] || return 0
  local notify_cmd=(
    "$BASE/scripts/papercut_notify.sh"
    --level "$level"
    --title "PaperCut Hive Driver"
    --message "$message"
  )
  if [[ $DRY_RUN -eq 1 ]]; then
    notify_cmd+=(--dry-run)
  fi
  "${notify_cmd[@]}" || true
}

on_error() {
  log_event --component setup --level error --event failed --message "Setup execution failed"
  notify_user error "Setup failed. Check terminal logs for details."
}
trap on_error ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doctor)
      if [[ "$MODE" != "setup" ]]; then
        echo "Choose only one mode: --doctor or --repair" >&2
        exit 1
      fi
      MODE="doctor"
      shift
      ;;
    --repair)
      if [[ "$MODE" != "setup" ]]; then
        echo "Choose only one mode: --doctor or --repair" >&2
        exit 1
      fi
      MODE="repair"
      shift
      ;;
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --no-bootstrap-from-extension) NO_BOOTSTRAP=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --python-mode) PYTHON_MODE="${2:-}"; shift 2 ;;
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

if [[ "$PYTHON_MODE" != "auto" && "$PYTHON_MODE" != "apt-only" ]]; then
  echo "Invalid --python-mode: $PYTHON_MODE" >&2
  exit 1
fi

if [[ "$MODE" == "doctor" ]]; then
  log_event --component setup --event mode-doctor --message "Doctor mode invoked"
  doctor_cmd=(
    "$BASE/scripts/papercut_doctor.sh"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --printer-name "$PRINTER_NAME"
  )
  [[ -n "$ORG_ID" ]] && doctor_cmd+=(--org-id "$ORG_ID")
  [[ $AUTO_YES -eq 1 ]] && doctor_cmd+=(--yes)
  [[ $DRY_RUN -eq 1 ]] && doctor_cmd+=(--dry-run)
  exec "${doctor_cmd[@]}"
fi

if [[ "$MODE" == "repair" ]]; then
  log_event --component setup --event mode-repair --message "Repair mode invoked"
  repair_cmd=(
    "$BASE/scripts/papercut_repair.sh"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --printer-name "$PRINTER_NAME"
  )
  [[ -n "$ORG_ID" ]] && repair_cmd+=(--org-id "$ORG_ID")
  [[ -n "$PROFILE_DIR" ]] && repair_cmd+=(--profile-dir "$PROFILE_DIR")
  [[ $ENABLE_NOTIFY -eq 0 ]] && repair_cmd+=(--no-notify)
  [[ $AUTO_YES -eq 1 ]] && repair_cmd+=(--yes)
  [[ $DRY_RUN -eq 1 ]] && repair_cmd+=(--dry-run)
  exec "${repair_cmd[@]}"
fi

if [[ -z "$ORG_ID" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    read -r -p "PaperCut Org ID: " ORG_ID
  fi
fi
if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required for setup mode (or provide it interactively)." >&2
  usage
  exit 1
fi

if [[ $AUTO_YES -ne 1 && -t 0 && -t 1 && $DRY_RUN -eq 0 ]]; then
  echo "About to run PaperCut Hive setup with:"
  echo "  org-id:      $ORG_ID"
  echo "  cloud-host:  $CLOUD_HOST"
  echo "  linux-user:  $LINUX_USER"
  echo "  printer:     $PRINTER_NAME"
  read -r -p "Continue? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      log_event --component setup --level warning --event cancelled --message "Setup cancelled by user"
      notify_user warning "Setup cancelled by user."
      exit 1
      ;;
  esac
fi

echo "[setup 0/4] Doctor preflight"
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
doctor_rc=$?
set -e

case "$doctor_rc" in
  0)
    log_event --component setup --event doctor-preflight-ok --message "Doctor preflight succeeded" --kv "code=0"
    ;;
  $RC_WARN)
    echo "[setup] doctor returned warnings; continuing setup."
    log_event --component setup --level warning --event doctor-preflight-warning --message "Doctor preflight warnings" --kv "code=$doctor_rc"
    ;;
  $RC_DEP_REFUSED|$RC_DEP_FAIL|$RC_CRITICAL)
    echo "[setup] doctor failed with code=$doctor_rc."
    log_event --component setup --level error --event doctor-preflight-failed --message "Doctor preflight blocked setup" --kv "code=$doctor_rc"
    exit "$doctor_rc"
    ;;
  *)
    echo "[setup] doctor failed with unexpected code=$doctor_rc."
    log_event --component setup --level error --event doctor-preflight-failed --message "Doctor preflight unexpected failure" --kv "code=$doctor_rc"
    exit "$RC_CRITICAL"
    ;;
esac

install_cmd=(
  "$BASE/release/install.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
)
if [[ $NO_BOOTSTRAP -eq 1 ]]; then
  install_cmd+=(--no-bootstrap-from-extension)
fi
install_cmd+=(--python-mode "$PYTHON_MODE")
if [[ $ENABLE_NOTIFY -eq 0 ]]; then
  install_cmd+=(--no-notify)
fi
if [[ -n "$PROFILE_DIR" ]]; then
  install_cmd+=(--profile-dir "$PROFILE_DIR")
fi
if [[ $DRY_RUN -eq 1 ]]; then
  install_cmd+=(--dry-run)
fi

echo "[setup 1/4] Install runtime stack"
log_event --component setup --event install-start --message "Install runtime stack"
"${install_cmd[@]}"
log_event --component setup --event install-complete --message "Install runtime stack completed"

finalize_cmd=(
  "$BASE/release/finalize-session.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
)
if [[ $ENABLE_NOTIFY -eq 0 ]]; then
  finalize_cmd+=(--no-notify)
fi
if [[ -n "$PROFILE_DIR" ]]; then
  finalize_cmd+=(--profile-dir "$PROFILE_DIR")
fi

needs_manual_finalize=0
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[setup 2/4] Finalize desktop session keyring binding"
  echo "[dry-run] ${finalize_cmd[*]}"
else
  echo "[setup 2/4] Finalize desktop session keyring binding"
  if [[ "$LINUX_USER" != "$USER" ]]; then
    echo "Skipping finalize: run as target desktop user '$LINUX_USER' to bind keyring."
    needs_manual_finalize=1
  elif [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo "Skipping finalize: no desktop DBus session detected in this shell."
    needs_manual_finalize=1
  elif ! "${finalize_cmd[@]}"; then
    echo "Finalize step did not complete in this shell."
    needs_manual_finalize=1
  fi
fi

if [[ $SKIP_VERIFY -eq 0 ]]; then
  echo "[setup 3/4] Run local CUPS verification"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $BASE/release/verify-print.sh --printer-name $PRINTER_NAME"
  else
    "$BASE/release/verify-print.sh" --printer-name "$PRINTER_NAME"
  fi
else
  echo "[setup 3/4] Verification skipped by user request"
fi

echo "[setup 4/4] Final status"
if [[ $needs_manual_finalize -eq 1 ]]; then
  echo
  echo "Setup installed successfully, but desktop-session finalization is still required."
  echo "Run this command from the normal graphical session of user '$LINUX_USER':"
  printf '  %q ' "${finalize_cmd[@]}"
  echo
  log_event --component setup --level warning --event complete-manual-finalize --message "Setup completed with manual finalize required"
  notify_user warning "Setup finished but desktop session finalization is still required."
  exit $RC_WARN
fi

echo
log_event --component setup --event complete --message "Setup completed successfully"
notify_user info "Setup complete. Printer ready: $PRINTER_NAME"
echo "Setup complete: PaperCut Hive Driver for Ubuntu is installed and validated."
echo

echo "User flow:"
echo "1) Open any app (LibreOffice, browser, PDF viewer, etc.)"
echo "2) Choose printer: $PRINTER_NAME"
echo "3) Print"
