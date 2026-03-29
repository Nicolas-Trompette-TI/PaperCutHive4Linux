#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"

fail=0

ban_match() {
  local label="$1"
  local pattern="$2"
  shift 2
  local files=("$@")
  if rg -n -- "$pattern" "${files[@]}"; then
    echo "[security] FAIL: $label" >&2
    fail=1
  else
    echo "[security] OK: $label"
  fi
}

must_match() {
  local label="$1"
  local pattern="$2"
  shift 2
  local files=("$@")
  if rg -n -- "$pattern" "${files[@]}"; then
    echo "[security] OK: $label"
  else
    echo "[security] FAIL: $label" >&2
    fail=1
  fi
}

echo "[security] secure coding guard"

ban_match "No CLI --jwt secret option" '--jwt\)' scripts/*.sh setup.sh release/*.sh
ban_match "No Python --password option for auth flow" 'add_argument\("--password"' scripts/papercut_password_login.py
ban_match "No auth output-file secret dump" 'add_argument\("--output-file"' scripts/papercut_password_login.py
ban_match "No insecure TLS flag in auth flow" 'add_argument\("--insecure"' scripts/papercut_password_login.py
ban_match "No setup temp JSON token file" 'tmp_json|--output-file' setup.sh
ban_match "No setup token via CLI argument" '--jwt[[:space:]]' setup.sh
ban_match "No secret passed to python argv in shell wrappers" 'python3 - "\\$[A-Za-z_]*(JWT|TOKEN|PASSWORD|ID_TOKEN)' scripts/*.sh setup.sh
ban_match "No broken pipe->python-heredoc stdin pattern" '\|\s*python3\s+-\s+<<'\''PY'\''' scripts/*.sh setup.sh
ban_match "No token-like variables passed to heredoc python argv" '(?i)python3 - <<'\''PY'\'' "\\$[A-Za-z_][A-Za-z0-9_]*(tok|token|jwt|password|secret|id[_-]?token)' scripts/*.sh setup.sh
ban_match "No submit-job secret CLI args" 'add_argument\("--(user-jwt|id-token)"' scripts/papercut_submit_job.py
ban_match "No submit-job insecure TLS bypass flag" 'add_argument\("--insecure"' scripts/papercut_submit_job.py
ban_match "No backend secret forwarding by CLI args" '--(user-jwt|id-token)[[:space:]]' scripts/papercut_cups_backend.sh
ban_match "No sudoers --default token-sync permission for user group" 'papercut-hive-token-sync --default --stdin' scripts/install_hive_secure_autodeploy.sh
must_match "Root helper blocks cross-user token sync" 'Refusing cross-user token sync' scripts/papercut_hive_token_sync_root.sh
must_match "Root helper checks sudo caller identity" 'SUDO_USER' scripts/papercut_hive_token_sync_root.sh

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "[security] secure coding guard OK"
