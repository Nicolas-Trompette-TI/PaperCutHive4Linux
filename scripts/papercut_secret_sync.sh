#!/usr/bin/env bash
set -euo pipefail
umask 077

LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Loads PaperCut JWT from OS keyring (Secret Service/libsecret) and syncs it to
/etc/papercut-hive-lite/tokens/<user>.jwt via restricted sudo helper.

Options:
  --org-id <ORG_ID>         required
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --verbose                 print extra logs (no secret content)
  -h, --help                show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required." >&2
  usage
  exit 1
fi

if ! command -v secret-tool >/dev/null 2>&1; then
  echo "secret-tool not found. Install package: libsecret-tools" >&2
  exit 1
fi

if [[ ! -x "/usr/local/sbin/papercut-hive-token-sync" ]]; then
  echo "Missing helper: /usr/local/sbin/papercut-hive-token-sync" >&2
  exit 1
fi

TOKEN="$(secret-tool lookup papercut hive-lite kind user-jwt user "$LINUX_USER" org "$ORG_ID" cloud "$CLOUD_HOST" || true)"
if [[ -z "$TOKEN" ]]; then
  echo "No JWT found in keyring for user=$LINUX_USER org=$ORG_ID cloud=$CLOUD_HOST." >&2
  exit 1
fi

if [[ $VERBOSE -eq 1 ]]; then
  echo "Found JWT in keyring (len=${#TOKEN}) for $LINUX_USER."
fi

printf '%s\n' "$TOKEN" | sudo /usr/local/sbin/papercut-hive-token-sync --linux-user "$LINUX_USER" --stdin >/dev/null
unset TOKEN

if [[ $VERBOSE -eq 1 ]]; then
  echo "Token sync complete."
fi
