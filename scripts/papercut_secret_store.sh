#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"

LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
JWT=""
FROM_EXTENSION=0
JWT_FROM_STDIN=0
PROFILE_DIR=""
SYNC_NOW=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Stores PaperCut JWT in OS keyring (Secret Service/libsecret) using secure attrs:
  papercut=hive-lite kind=user-jwt user=<user> org=<org> cloud=<host>

Options:
  --org-id <ORG_ID>         optional if inferable from JWT claims
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --jwt-stdin               read JWT from stdin (recommended for automation)
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
    --jwt-stdin) JWT_FROM_STDIN=1; shift ;;
    --from-extension) FROM_EXTENSION=1; shift ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --sync-now) SYNC_NOW=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $FROM_EXTENSION -eq 1 && $JWT_FROM_STDIN -eq 1 ]]; then
  echo "Choose only one JWT source: --from-extension or --jwt-stdin." >&2
  exit 1
fi

extract_from_extension() {
  local profile="$1"
  local -a scan_dirs=()
  local -a roots=()

  add_scan_dirs_from_root() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    while IFS= read -r found; do
      [[ -n "$found" ]] && scan_dirs+=("$found")
    done < <(find "$root" -maxdepth 4 -type d -path "*/Sync Extension Settings/$EXT_ID" 2>/dev/null | sort)
  }

  if [[ -z "$profile" ]]; then
    roots=(
      "$HOME/.config/google-chrome"
      "$HOME/.config/chromium"
      "$BASE/tools/chromium-user-data-auth"
    )
    for candidate in "${roots[@]}"; do
      add_scan_dirs_from_root "$candidate"
    done
  else
    roots=("$profile")
    if [[ -d "$profile/Sync Extension Settings/$EXT_ID" ]]; then
      scan_dirs+=("$profile/Sync Extension Settings/$EXT_ID")
    fi
    if [[ -d "$profile/Default/Sync Extension Settings/$EXT_ID" ]]; then
      scan_dirs+=("$profile/Default/Sync Extension Settings/$EXT_ID")
    fi
    add_scan_dirs_from_root "$profile"
  fi

  if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    if [[ -z "$profile" ]]; then
      echo "Unable to auto-detect extension sync storage. Open linked Chrome/Chromium first or use --profile-dir." >&2
    else
      echo "Sync extension settings not found under profile root: $profile" >&2
    fi
    return 1
  fi

  python3 - <<'PY' "${scan_dirs[@]}"
import pathlib
import re
import sys

scan_dirs = [pathlib.Path(p) for p in sys.argv[1:] if p]
jwt_re = re.compile(r"eyJ[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+")
candidates = []

for scan_dir in scan_dirs:
    if not scan_dir.is_dir():
        continue
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

if [[ $FROM_EXTENSION -eq 1 ]]; then
  JWT="$(extract_from_extension "$PROFILE_DIR" || true)"
  if [[ -z "$JWT" ]]; then
    echo "Failed to extract JWT from extension storage." >&2
    exit 1
  fi
fi

if [[ -z "$JWT" && $JWT_FROM_STDIN -eq 1 ]]; then
  IFS= read -r JWT || true
fi

if [[ -z "$JWT" && $JWT_FROM_STDIN -eq 0 ]]; then
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

if [[ -z "$ORG_ID" ]]; then
  ORG_ID="$(printf '%s\n' "$JWT" | "$BASE/scripts/papercut_detect_org_id.sh" --jwt-stdin 2>/dev/null || true)"
  if [[ -n "$ORG_ID" ]]; then
    echo "Detected Org ID from token claims: $ORG_ID"
  fi
fi

if [[ -z "$ORG_ID" ]]; then
  echo "Unable to infer Org ID from token. Provide --org-id <ORG_ID>." >&2
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
