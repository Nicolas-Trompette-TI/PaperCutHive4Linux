#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"

ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
LINUX_USER="${USER}"
PRINTER_NAME="PaperCut-Hive-TIF"
PROFILE_DIR=""
BOOTSTRAP_FROM_EXTENSION=1
ENABLE_BACKEND_DRY_RUN=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Production installer wrapper for PaperCut Hive Linux stack.

Options:
  --org-id <ORG_ID>             required
  --cloud-host <host>           default: eu.hive.papercut.com
  --linux-user <user>           default: current user
  --printer-name <name>         default: PaperCut-Hive-TIF
  --profile-dir <dir>           browser profile dir (for extension bootstrap)
  --no-bootstrap-from-extension do not attempt extension -> keyring bootstrap
  --enable-backend-dry-run      set backend in offline dry-run mode
  --dry-run                     print actions only
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
    --no-bootstrap-from-extension) BOOTSTRAP_FROM_EXTENSION=0; shift ;;
    --enable-backend-dry-run) ENABLE_BACKEND_DRY_RUN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required." >&2
  usage
  exit 1
fi

cmd=(
  "$BASE/scripts/install_hive_secure_autodeploy.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
)

if [[ $BOOTSTRAP_FROM_EXTENSION -eq 1 ]]; then
  cmd+=(--bootstrap-from-extension)
fi
if [[ $ENABLE_BACKEND_DRY_RUN -eq 1 ]]; then
  cmd+=(--enable-backend-dry-run)
fi
if [[ -n "$PROFILE_DIR" ]]; then
  cmd+=(--profile-dir "$PROFILE_DIR")
fi
if [[ $DRY_RUN -eq 1 ]]; then
  cmd+=(--dry-run)
fi

"${cmd[@]}"

cat <<EOF

Release install wrapper complete.

If keyring bootstrap was skipped or failed in a non-graphical shell, open your
normal desktop session and run:
  $BASE/release/finalize-session.sh --org-id "$ORG_ID" --cloud-host "$CLOUD_HOST" --linux-user "$LINUX_USER"
EOF
