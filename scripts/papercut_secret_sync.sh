#!/usr/bin/env bash
set -euo pipefail
umask 077

LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
VERBOSE=0
AUTO_REFRESH_FROM_EXTENSION=0
PROFILE_DIR=""
BASE="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Loads PaperCut JWT from OS keyring (Secret Service/libsecret) and syncs it to
/etc/papercut-hive-lite/tokens/<user>.jwt via restricted sudo helper.

Options:
  --org-id <ORG_ID>         required
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --auto-refresh-from-extension
                             attempt extension->keyring refresh if token is missing/invalid
  --profile-dir <dir>       browser profile root for auto-refresh extraction
  --verbose                 print extra logs (no secret content)
  -h, --help                show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --auto-refresh-from-extension) AUTO_REFRESH_FROM_EXTENSION=1; shift ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
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

token_state() {
  local tok="${1:-}"
  python3 - <<'PY' "$tok"
import sys, base64, json, time
tok = (sys.argv[1] or "").strip()
if not tok:
    print("MISSING")
    raise SystemExit(0)
parts = tok.split(".")
if len(parts) != 3:
    print("INVALID")
    raise SystemExit(0)
try:
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload))
except Exception:
    print("INVALID")
    raise SystemExit(0)
exp = data.get("exp")
if exp is None:
    print("VALID")
    raise SystemExit(0)
if int(exp) <= int(time.time()) + 60:
    print("EXPIRED")
else:
    print("VALID")
PY
}

try_refresh_from_extension() {
  [[ $AUTO_REFRESH_FROM_EXTENSION -eq 1 ]] || return 1
  local refresh_cmd=(
    "$BASE/scripts/papercut_secret_store.sh"
    --org-id "$ORG_ID"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --from-extension
  )
  if [[ -n "$PROFILE_DIR" ]]; then
    refresh_cmd+=(--profile-dir "$PROFILE_DIR")
  fi

  if [[ $VERBOSE -eq 1 ]]; then
    echo "Attempting token refresh from extension storage..."
  fi
  if [[ $VERBOSE -eq 1 ]]; then
    "${refresh_cmd[@]}"
  else
    "${refresh_cmd[@]}" >/dev/null 2>&1
  fi
}

TOKEN="$(secret-tool lookup papercut hive-lite kind user-jwt user "$LINUX_USER" org "$ORG_ID" cloud "$CLOUD_HOST" || true)"
STATE="$(token_state "$TOKEN")"
if [[ "$STATE" != "VALID" ]]; then
  if [[ $VERBOSE -eq 1 ]]; then
    echo "Current keyring token state: $STATE"
  fi
  if ! try_refresh_from_extension; then
    echo "No valid JWT found in keyring for user=$LINUX_USER org=$ORG_ID cloud=$CLOUD_HOST." >&2
    exit 1
  fi
  TOKEN="$(secret-tool lookup papercut hive-lite kind user-jwt user "$LINUX_USER" org "$ORG_ID" cloud "$CLOUD_HOST" || true)"
  STATE="$(token_state "$TOKEN")"
  if [[ "$STATE" != "VALID" ]]; then
    echo "Token refresh attempted but token remains $STATE." >&2
    exit 1
  fi
fi

if [[ $VERBOSE -eq 1 ]]; then
  echo "Found JWT in keyring (len=${#TOKEN}) for $LINUX_USER."
fi

printf '%s\n' "$TOKEN" | sudo /usr/local/sbin/papercut-hive-token-sync --linux-user "$LINUX_USER" --stdin >/dev/null
unset TOKEN

if [[ $VERBOSE -eq 1 ]]; then
  echo "Token sync complete."
fi
