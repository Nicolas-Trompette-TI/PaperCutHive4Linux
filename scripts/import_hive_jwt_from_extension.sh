#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
PROFILE_DIR=""
LINUX_USER="${USER}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Imports PaperCut extension user JWT from Chromium profile sync storage, then
stores it for the CUPS backend using set_hive_user_token.sh.

Options:
  --profile-dir <dir>   Browser user-data dir (auto-detected if omitted)
  --linux-user <user>   Linux user for token mapping (default: $LINUX_USER)
  --dry-run             Detect token but do not write it
  -h, --help            Show this help

Expected storage path:
  <profile-dir>/Default/Sync Extension Settings/$EXT_ID
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$PROFILE_DIR" ]]; then
  for candidate in \
    "$HOME/.config/google-chrome" \
    "$HOME/.config/chromium" \
    "$BASE/tools/chromium-user-data-auth"
  do
    if [[ -d "$candidate/Default/Sync Extension Settings/$EXT_ID" ]]; then
      PROFILE_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$PROFILE_DIR" ]]; then
  echo "Unable to auto-detect profile dir with Hive extension sync data." >&2
  echo "Use --profile-dir <dir> explicitly." >&2
  exit 1
fi

SCAN_DIR="$PROFILE_DIR/Default/Sync Extension Settings/$EXT_ID"
if [[ ! -d "$SCAN_DIR" ]]; then
  echo "Sync extension settings not found: $SCAN_DIR" >&2
  echo "Hint: run Chromium with the Hive extension linked first." >&2
  exit 1
fi

JWT="$(
python3 - <<'PY' "$SCAN_DIR"
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
    for tok in jwt_re.findall(data):
        candidates.append(tok)

if not candidates:
    print("")
    raise SystemExit(0)

# Pick the longest token to avoid truncated captures.
best = max(candidates, key=len)
print(best)
PY
)"

if [[ -z "$JWT" ]]; then
  echo "No JWT found in extension sync storage under: $SCAN_DIR" >&2
  exit 1
fi

echo "Detected extension JWT (len=${#JWT}) for user '$LINUX_USER'."
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run: token not written."
  exit 0
fi

"$BASE/scripts/set_hive_user_token.sh" --linux-user "$LINUX_USER" --jwt "$JWT"
unset JWT
echo "Import complete."
