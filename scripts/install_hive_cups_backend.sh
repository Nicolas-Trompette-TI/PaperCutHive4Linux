#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER_NAME="PaperCut-Hive-TIF"
CLOUD_HOST="eu.hive.papercut.com"
ORG_ID=""
CLIENT_TYPE="ChromeApp-2.4.1"
TIMEOUT="60"
DRY_RUN=0
ENABLE_DRY_BACKEND=0
PYTHON_MODE="auto"
ENABLE_NOTIFY=1
QUEUE_MODEL="drv:///sample.drv/generic.ppd"

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Required:
  --org-id <ORG_ID>

Optional:
  --cloud-host <host>           default: eu.hive.papercut.com
  --printer-name <name>         default: PaperCut-Hive-TIF
  --client-type <value>         default: ChromeApp-2.4.1
  --timeout <sec>               default: 60
  --dry-run                     print actions without applying
  --enable-backend-dry-run      install backend with PAPERCUT_DRY_RUN=1
  --python-mode <auto|apt-only> default: auto
  --no-notify                   disable local print-error notifications

What it installs:
- /usr/local/lib/papercut-hive-lite/papercut_submit_job.py
- /usr/local/lib/papercut-hive-lite/papercut_cups_backend.sh
- /usr/lib/cups/backend/papercut-hive-lite
- /etc/papercut-hive-lite/config.env
- CUPS queue: <printer-name> (device URI papercut-hive-lite:/)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --client-type) CLIENT_TYPE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --enable-backend-dry-run) ENABLE_DRY_BACKEND=1; shift ;;
    --python-mode) PYTHON_MODE="${2:-}"; shift 2 ;;
    --no-notify) ENABLE_NOTIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required" >&2
  usage
  exit 1
fi

if [[ "$PYTHON_MODE" != "auto" && "$PYTHON_MODE" != "apt-only" ]]; then
  echo "Invalid --python-mode: $PYTHON_MODE" >&2
  exit 1
fi

CFG_CONTENT=$(cat <<EOF
# PaperCut Hive Lite CUPS backend config
PAPERCUT_CLOUD_HOST="${CLOUD_HOST}"
PAPERCUT_ORG_ID="${ORG_ID}"
PAPERCUT_CLIENT_TYPE="${CLIENT_TYPE}"
PAPERCUT_TIMEOUT="${TIMEOUT}"
PAPERCUT_DRY_RUN="${ENABLE_DRY_BACKEND}"
PAPERCUT_QUEUE_NAME="${PRINTER_NAME}"
PAPERCUT_ALERT_DIR="/var/lib/papercut-hive-lite/alerts"
PAPERCUT_NOTIFY_ERRORS="${ENABLE_NOTIFY}"
# Optional overrides:
# PAPERCUT_TARGET_URL="https://<target>"
# Token material should not be stored here.
# Use keyring flow via scripts/papercut_secret_store.sh + scripts/papercut_secret_sync.sh
# PAPERCUT_STATE_DIR="/var/lib/papercut-hive-lite"
EOF
)

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    echo
  else
    "$@"
  fi
}

echo "[1/6] install packages"
run_cmd sudo apt-get update -y
run_cmd sudo apt-get install -y cups cups-client cups-filters python3-requests python3-venv file

echo "[2/6] install backend runtime files"
run_cmd sudo mkdir -p /usr/local/lib/papercut-hive-lite
run_cmd sudo cp "$BASE/scripts/papercut_submit_job.py" /usr/local/lib/papercut-hive-lite/papercut_submit_job.py
run_cmd sudo cp "$BASE/scripts/papercut_cups_backend.sh" /usr/local/lib/papercut-hive-lite/papercut_cups_backend.sh
run_cmd sudo cp "$BASE/scripts/papercut_notify.sh" /usr/local/lib/papercut-hive-lite/papercut_notify.sh
run_cmd sudo cp "$BASE/scripts/papercut_event_log.sh" /usr/local/lib/papercut-hive-lite/papercut_event_log.sh
run_cmd sudo cp "$BASE/scripts/papercut_alert_notify.sh" /usr/local/lib/papercut-hive-lite/papercut_alert_notify.sh
run_cmd sudo cp "$BASE/scripts/papercut_python_bootstrap.sh" /usr/local/lib/papercut-hive-lite/papercut_python_bootstrap.sh
run_cmd sudo chmod 755 \
  /usr/local/lib/papercut-hive-lite/papercut_submit_job.py \
  /usr/local/lib/papercut-hive-lite/papercut_cups_backend.sh \
  /usr/local/lib/papercut-hive-lite/papercut_notify.sh \
  /usr/local/lib/papercut-hive-lite/papercut_event_log.sh \
  /usr/local/lib/papercut-hive-lite/papercut_alert_notify.sh \
  /usr/local/lib/papercut-hive-lite/papercut_python_bootstrap.sh
run_cmd sudo mkdir -p /var/lib/papercut-hive-lite/alerts
run_cmd sudo chown root:lp /var/lib/papercut-hive-lite /var/lib/papercut-hive-lite/alerts
run_cmd sudo chmod 775 /var/lib/papercut-hive-lite /var/lib/papercut-hive-lite/alerts

echo "[3/6] install cups backend"
run_cmd sudo cp "$BASE/scripts/papercut_cups_backend.sh" /usr/lib/cups/backend/papercut-hive-lite
run_cmd sudo chmod 755 /usr/lib/cups/backend/papercut-hive-lite

echo "[4/6] write config"
run_cmd sudo mkdir -p /etc/papercut-hive-lite/tokens
run_cmd sudo chown root:lp /etc/papercut-hive-lite/tokens
run_cmd sudo chmod 750 /etc/papercut-hive-lite/tokens
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- /etc/papercut-hive-lite/config.env ---"
  echo "$CFG_CONTENT"
else
  printf '%s\n' "$CFG_CONTENT" | sudo tee /etc/papercut-hive-lite/config.env >/dev/null
  sudo chown root:lp /etc/papercut-hive-lite/config.env
  sudo chmod 640 /etc/papercut-hive-lite/config.env
fi
bootstrap_cmd=(sudo /usr/local/lib/papercut-hive-lite/papercut_python_bootstrap.sh --mode "$PYTHON_MODE")
if [[ "$DRY_RUN" -eq 1 ]]; then
  bootstrap_cmd+=(--dry-run)
fi
run_cmd "${bootstrap_cmd[@]}"

echo "[5/6] ensure cups service"
run_cmd sudo systemctl enable --now cups
run_cmd sudo systemctl restart cups

echo "[6/6] create cups queue"
if command -v lpstat >/dev/null 2>&1 && lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
  uri_line="$(lpstat -v "$PRINTER_NAME" 2>/dev/null | head -n1 || true)"
  echo "[install] existing queue '$PRINTER_NAME' detected; it will be deleted and replaced."
  [[ -n "$uri_line" ]] && echo "[install] current queue: $uri_line"
fi
if command -v lpinfo >/dev/null 2>&1; then
  if ! lpinfo -m 2>/dev/null | grep -Fq "$QUEUE_MODEL"; then
    echo "[install] model '$QUEUE_MODEL' unavailable on this host; falling back to raw."
    QUEUE_MODEL="raw"
  fi
else
  echo "[install] lpinfo unavailable; falling back to raw queue model."
  QUEUE_MODEL="raw"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] sudo lpadmin -x '$PRINTER_NAME' 2>/dev/null || true"
else
  sudo lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
fi
run_cmd sudo lpadmin -p "$PRINTER_NAME" -E -v papercut-hive-lite:/ -m "$QUEUE_MODEL"
run_cmd sudo cupsenable "$PRINTER_NAME"
run_cmd sudo cupsaccept "$PRINTER_NAME"

echo
echo "Done."
echo "Queue created: $PRINTER_NAME"
echo "Token setup (required):"
echo "  ./scripts/set_hive_user_token.sh --linux-user <user>"
echo
echo "Quick verification print:"
echo "  echo test > ~/test.txt"
echo "  lp -d '$PRINTER_NAME' ~/test.txt"
