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

usage() {
  cat <<EOF
Usage: $0 [--org-id <ORG_ID>] [options]

PaperCut Hive Driver for Ubuntu setup (single entrypoint):
1) Installs production runtime (CUPS backend + secure token sync stack)
2) Finalizes desktop session keyring binding when possible
3) Runs a local print verification

Options:
  --org-id <ORG_ID>             optional in interactive shell (prompted)
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
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
  if [[ -t 0 && -t 1 ]]; then
    read -r -p "PaperCut Org ID: " ORG_ID
  fi
fi
if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required (or provide it interactively)." >&2
  usage
  exit 1
fi

if [[ "$PYTHON_MODE" != "auto" && "$PYTHON_MODE" != "apt-only" ]]; then
  echo "Invalid --python-mode: $PYTHON_MODE" >&2
  exit 1
fi

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
  notify_user error "Setup failed. Check terminal logs for details."
}
trap on_error ERR

if [[ $AUTO_YES -ne 1 && -t 0 && -t 1 && $DRY_RUN -eq 0 ]]; then
  echo "About to install PaperCut Hive Driver for Ubuntu with:"
  echo "  org-id:      $ORG_ID"
  echo "  cloud-host:  $CLOUD_HOST"
  echo "  linux-user:  $LINUX_USER"
  echo "  printer:     $PRINTER_NAME"
  read -r -p "Continue? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; notify_user warning "Setup cancelled by user."; exit 1 ;;
  esac
fi

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

echo "[setup 1/3] Install runtime stack"
"${install_cmd[@]}"

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
  echo "[setup 2/3] Finalize desktop session keyring binding"
  echo "[dry-run] ${finalize_cmd[*]}"
else
  echo "[setup 2/3] Finalize desktop session keyring binding"
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
  echo "[setup 3/3] Run local CUPS verification"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $BASE/release/verify-print.sh --printer-name $PRINTER_NAME"
  else
    "$BASE/release/verify-print.sh" --printer-name "$PRINTER_NAME"
  fi
else
  echo "[setup 3/3] Verification skipped by user request"
fi

if [[ $needs_manual_finalize -eq 1 ]]; then
  echo
  echo "Setup installed successfully, but desktop-session finalization is still required."
  echo "Run this command from the normal graphical session of user '$LINUX_USER':"
  printf '  %q ' "${finalize_cmd[@]}"
  echo
  notify_user warning "Setup finished but desktop session finalization is still required."
  exit 2
fi

echo
echo "Setup complete: PaperCut Hive Driver for Ubuntu is installed and validated."
notify_user info "Setup complete. Printer ready: $PRINTER_NAME"
echo
echo "User flow:"
echo "1) Open any app (LibreOffice, browser, PDF viewer, etc.)"
echo "2) Choose printer: $PRINTER_NAME"
echo "3) Print"
