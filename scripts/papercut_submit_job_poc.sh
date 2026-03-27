#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PY="$BASE/scripts/papercut_submit_job_poc.py"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 --file <pdf> [--cloud-host eu.hive.papercut.com] [--org-id <id>] [--dry-run]" >&2
  exit 1
fi

if [[ -z "${PAPERCUT_USER_JWT:-}" && -z "${PAPERCUT_ID_TOKEN:-}" ]]; then
  read -r -s -p "PaperCut ID token (pc-idtoken), leave empty if PAPERCUT_USER_JWT is set: " PAPERCUT_ID_TOKEN
  echo
fi

ARGS=("$@")
if [[ -n "${PAPERCUT_USER_JWT:-}" ]]; then
  ARGS+=(--user-jwt "$PAPERCUT_USER_JWT")
elif [[ -n "${PAPERCUT_ID_TOKEN:-}" ]]; then
  ARGS+=(--id-token "$PAPERCUT_ID_TOKEN")
fi

python3 "$PY" "${ARGS[@]}"
