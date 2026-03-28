#!/usr/bin/env bash
set -euo pipefail

MODE="auto"
LIB_DIR="/usr/local/lib/papercut-hive-lite"
CFG_FILE="/etc/papercut-hive-lite/python.env"
SYSTEM_PYTHON="/usr/bin/python3"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 [options]

Prepare Python runtime for PaperCut Hive backend:
- Prefer system python + apt requests
- Fallback to local venv in auto mode when system runtime is broken

Options:
  --mode <auto|apt-only>     default: auto
  --lib-dir <dir>            default: /usr/local/lib/papercut-hive-lite
  --config-file <path>       default: /etc/papercut-hive-lite/python.env
  --dry-run                  print actions only
  -h, --help                 show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --lib-dir) LIB_DIR="${2:-}"; shift 2 ;;
    --config-file) CFG_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$MODE" != "auto" && "$MODE" != "apt-only" ]]; then
  echo "Invalid --mode: $MODE" >&2
  exit 1
fi

run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    echo
    return 0
  fi
  "$@"
}

system_runtime_ok() {
  "$SYSTEM_PYTHON" - <<'PY' >/dev/null 2>&1
import requests
print(requests.__version__)
PY
}

venv_runtime_ok() {
  local pybin="$1"
  "$pybin" - <<'PY' >/dev/null 2>&1
import requests
print(requests.__version__)
PY
}

write_cfg() {
  local pybin="$1"
  local source_mode="$2"
  local content
  content=$(cat <<EOF
PAPERCUT_PYTHON_BIN="$pybin"
PAPERCUT_PYTHON_SOURCE="$source_mode"
EOF
)

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "--- $CFG_FILE ---"
    echo "$content"
    return 0
  fi

  run_cmd sudo mkdir -p "$(dirname "$CFG_FILE")"
  printf '%s\n' "$content" | sudo tee "$CFG_FILE" >/dev/null
  run_cmd sudo chown root:lp "$CFG_FILE"
  run_cmd sudo chmod 640 "$CFG_FILE"
}

if system_runtime_ok; then
  write_cfg "$SYSTEM_PYTHON" "apt"
  echo "Python runtime ready via system packages."
  exit 0
fi

if [[ "$MODE" == "apt-only" ]]; then
  echo "System Python runtime is not healthy (requests import failed), and mode is apt-only." >&2
  exit 1
fi

VENV_DIR="$LIB_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python3"
VENV_PIP="$VENV_DIR/bin/pip"

run_cmd sudo mkdir -p "$LIB_DIR"
run_cmd sudo "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
run_cmd sudo "$VENV_PIP" install --upgrade pip
run_cmd sudo "$VENV_PIP" install "requests>=2.31,<3"
run_cmd sudo chmod -R a+rX "$VENV_DIR"

if [[ $DRY_RUN -eq 0 ]]; then
  if ! venv_runtime_ok "$VENV_PY"; then
    echo "Venv runtime failed validation after creation." >&2
    exit 1
  fi
fi

write_cfg "$VENV_PY" "venv"
echo "Python runtime ready via local fallback venv."
