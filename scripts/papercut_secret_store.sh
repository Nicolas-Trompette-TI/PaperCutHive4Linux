#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"

LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
JWT=""
FROM_EXTENSION=0
PROFILE_DIR=""
SYNC_NOW=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Stores PaperCut JWT in OS keyring (Secret Service/libsecret) using secure attrs:
  papercut=hive-lite kind=user-jwt user=<user> org=<org> cloud=<host>

Options:
  --org-id <ORG_ID>         required
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --jwt <token>             provide JWT directly (avoid if possible)
  --from-extension          extract JWT from browser extension sync storage
  --profile-dir <dir>       user-data dir for --from-extension
  --sync-now                run papercut_secret_sync.sh after storing
  --dry-run                 validate/extract only, do not store
  -h, --help                show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --jwt) JWT="${2:-}"; shift 2 ;;
    --from-extension) FROM_EXTENSION=1; shift ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --sync-now) SYNC_NOW=1; shift ;;
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

extract_from_extension() {
  local profile="$1"
  local scan_dir=""

  if [[ -z "$profile" ]]; then
    for candidate in \
      "$HOME/.config/google-chrome" \
      "$HOME/.config/chromium" \
      "$BASE/tools/chromium-user-data-auth"
    do
      if [[ -d "$candidate/Default/Sync Extension Settings/$EXT_ID" ]]; then
        profile="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$profile" ]]; then
    echo "Unable to auto-detect extension profile. Use --profile-dir." >&2
    return 1
  fi

  scan_dir="$profile/Default/Sync Extension Settings/$EXT_ID"
  if [[ ! -d "$scan_dir" ]]; then
    echo "Sync extension settings not found: $scan_dir" >&2
    return 1
  fi

  python3 - <<'PY' "$scan_dir"
import pathlib
import re
import sys

scan_dir = pathlib.Path(sys.argv[1])
jwt_re = re.compile(r"eyJ[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+")
candidates = []

for path in sorted(scan_dir.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True):
    if path.name == "LOCK" or not path.is_file():
        continue
    try:
        data = path.read_bytes().decode("latin1", "ignore")
    except Exception:
        continue
    candidates.extend(jwt_re.findall(data))

if not candidates:
    raise SystemExit(1)

print(max(candidates, key=len))
PY
}

if [[ -z "$JWT" && $FROM_EXTENSION -eq 1 ]]; then
  JWT="$(extract_from_extension "$PROFILE_DIR" || true)"
  if [[ -z "$JWT" ]]; then
    echo "Failed to extract JWT from extension storage." >&2
    exit 1
  fi
fi

if [[ -z "$JWT" ]]; then
  read -r -s -p "Enter PaperCut JWT: " JWT
  echo
fi

if [[ -z "$JWT" ]]; then
  echo "JWT is empty." >&2
  exit 1
fi

if ! [[ "$JWT" =~ ^eyJ[[:alnum:]_-]+\.[[:alnum:]_-]+\.[[:alnum:]_-]+$ ]]; then
  echo "Token does not look like a JWT." >&2
  exit 1
fi

echo "JWT ready for keyring storage (len=${#JWT}, user=$LINUX_USER, org=$ORG_ID)."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry-run: nothing stored."
  unset JWT
  exit 0
fi

if ! command -v secret-tool >/dev/null 2>&1; then
  echo "secret-tool not found. Install package: libsecret-tools" >&2
  exit 1
fi

store_jwt() {
  local out_file
  out_file="$(mktemp)"
  if printf '%s' "$JWT" | secret-tool store \
    --label "PaperCut Hive JWT ($LINUX_USER@$ORG_ID)" \
    papercut hive-lite kind user-jwt user "$LINUX_USER" org "$ORG_ID" cloud "$CLOUD_HOST" \
    >"$out_file" 2>&1
  then
    rm -f "$out_file"
    return 0
  fi

  local err_text
  err_text="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
  echo "$err_text" >&2
  return 1
}

if ! store_jwt; then
  if [[ -t 0 && -t 1 ]] && command -v python3 >/dev/null 2>&1; then
    echo "Keyring store failed. Attempting keyring collection initialization..." >&2
    if "$BASE/scripts/papercut_keyring_init.sh" --label login; then
      echo "Retrying keyring store..." >&2
      if ! store_jwt; then
        echo "Failed to store JWT in keyring after keyring init." >&2
        exit 1
      fi
    else
      echo "Keyring initialization failed." >&2
      exit 1
    fi
  else
    echo "Failed to store JWT in keyring." >&2
    echo "Open a graphical user session and ensure the keyring service is unlocked, then retry." >&2
    echo "If needed, run: ./scripts/papercut_keyring_init.sh --label login" >&2
    exit 1
  fi
fi
unset JWT

echo "JWT stored in OS keyring."

if [[ $SYNC_NOW -eq 1 ]]; then
  "$BASE/scripts/papercut_secret_sync.sh" --linux-user "$LINUX_USER" --org-id "$ORG_ID" --cloud-host "$CLOUD_HOST" --verbose
fi
