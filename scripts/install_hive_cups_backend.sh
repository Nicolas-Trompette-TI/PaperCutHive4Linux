#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER_NAME="PaperCut-Hive-Lite"
CLOUD_HOST="eu.hive.papercut.com"
ORG_ID=""
CLIENT_TYPE="ChromeApp-2.4.1"
TIMEOUT="60"
DRY_RUN=0
ENABLE_DRY_BACKEND=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Required:
  --org-id <ORG_ID>

Optional:
  --cloud-host <host>           default: eu.hive.papercut.com
  --printer-name <name>         default: PaperCut-Hive-Lite
  --client-type <value>         default: ChromeApp-2.4.1
  --timeout <sec>               default: 60
  --dry-run                     print actions without applying
  --enable-backend-dry-run      install backend with PAPERCUT_DRY_RUN=1

What it installs:
- /usr/local/lib/papercut-hive-lite/papercut_submit_job_poc.py
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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required" >&2
  usage
  exit 1
fi

CFG_CONTENT=$(cat <<EOF
# PaperCut Hive Lite CUPS backend config
PAPERCUT_CLOUD_HOST="${CLOUD_HOST}"
PAPERCUT_ORG_ID="${ORG_ID}"
PAPERCUT_CLIENT_TYPE="${CLIENT_TYPE}"
PAPERCUT_TIMEOUT="${TIMEOUT}"
PAPERCUT_DRY_RUN="${ENABLE_DRY_BACKEND}"
# Optional overrides:
# PAPERCUT_TARGET_URL="https://<target>"
# PAPERCUT_ID_TOKEN=""
# PAPERCUT_USER_JWT=""
# PAPERCUT_STATE_DIR="/var/lib/papercut-hive-lite"
EOF
)

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

echo "[1/6] install packages"
run "sudo apt-get update -y"
run "sudo apt-get install -y cups cups-client cups-filters python3-requests file"

echo "[2/6] install backend runtime files"
run "sudo mkdir -p /usr/local/lib/papercut-hive-lite"
run "sudo cp '$BASE/scripts/papercut_submit_job_poc.py' /usr/local/lib/papercut-hive-lite/papercut_submit_job_poc.py"
run "sudo cp '$BASE/scripts/papercut_cups_backend.sh' /usr/local/lib/papercut-hive-lite/papercut_cups_backend.sh"
run "sudo chmod 755 /usr/local/lib/papercut-hive-lite/papercut_submit_job_poc.py /usr/local/lib/papercut-hive-lite/papercut_cups_backend.sh"
run "sudo mkdir -p /var/lib/papercut-hive-lite"
run "sudo chown root:lp /var/lib/papercut-hive-lite"
run "sudo chmod 775 /var/lib/papercut-hive-lite"

echo "[3/6] install cups backend"
run "sudo cp '$BASE/scripts/papercut_cups_backend.sh' /usr/lib/cups/backend/papercut-hive-lite"
run "sudo chmod 755 /usr/lib/cups/backend/papercut-hive-lite"

echo "[4/6] write config"
run "sudo mkdir -p /etc/papercut-hive-lite/tokens"
run "sudo chown root:lp /etc/papercut-hive-lite/tokens"
run "sudo chmod 750 /etc/papercut-hive-lite/tokens"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- /etc/papercut-hive-lite/config.env ---"
  echo "$CFG_CONTENT"
else
  printf '%s\n' "$CFG_CONTENT" | sudo tee /etc/papercut-hive-lite/config.env >/dev/null
  sudo chown root:lp /etc/papercut-hive-lite/config.env
  sudo chmod 640 /etc/papercut-hive-lite/config.env
fi

echo "[5/6] ensure cups service"
run "sudo systemctl enable --now cups"
run "sudo systemctl restart cups"

echo "[6/6] create cups queue"
run "sudo lpadmin -x '$PRINTER_NAME' 2>/dev/null || true"
run "sudo lpadmin -p '$PRINTER_NAME' -E -v papercut-hive-lite:/ -m raw"
run "sudo cupsenable '$PRINTER_NAME'"
run "sudo cupsaccept '$PRINTER_NAME'"

echo
echo "Done."
echo "Queue created: $PRINTER_NAME"
echo "Token setup (required):"
echo "  ./scripts/set_hive_user_token.sh --linux-user <user>"
echo
echo "Test print:"
echo "  echo test > ~/test.txt"
echo "  lp -d '$PRINTER_NAME' ~/test.txt"
