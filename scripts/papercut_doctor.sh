#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EVENT_LOG="$BASE/scripts/papercut_event_log.sh"

PRINTER_NAME="PaperCut-Hive-TIF"
LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
AUTO_YES=0
DRY_RUN=0
ALLOW_QUEUE_RECREATE=0

WARNINGS=0
CRITICALS=0

RC_OK=0
RC_WARN=2
RC_DEP_REFUSED=20
RC_DEP_FAIL=21
RC_CRITICAL=22

usage() {
  cat <<USAGE
Usage: $0 [options]

Doctor preflight checks for PaperCut Hive Driver:
- dependencies
- CUPS service/backend/queue
- user systemd timers
- keyring/token state

Options:
  --org-id <ORG_ID>         optional (enables token state check)
  --cloud-host <host>       default: eu.hive.papercut.com
  --linux-user <user>       default: current user
  --printer-name <name>     default: PaperCut-Hive-TIF
  --allow-queue-recreate    backend/queue checks are warnings (for pre-install setup)
  -y, --yes                 auto-confirm apt install prompts
  --dry-run                 do not install missing dependencies
  -h, --help                show help
USAGE
}

log_event() {
  [[ -x "$EVENT_LOG" ]] || return 0
  "$EVENT_LOG" "$@" || true
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  echo "[warn] $*"
}

crit() {
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "dry-run: $*"
    return 0
  fi
  CRITICALS=$((CRITICALS + 1))
  echo "[critical] $*"
}

is_pkg_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

mode_is_subset() {
  local mode="$1"
  local allowed="$2"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  [[ "$allowed" =~ ^[0-7]{3,4}$ ]] || return 1
  local mode_int allowed_int
  mode_int=$((8#$mode))
  allowed_int=$((8#$allowed))
  (( (mode_int | allowed_int) == allowed_int ))
}

check_secure_path() {
  local path="$1"
  local expected_type="$2"
  local expected_owner="$3"
  local expected_group="$4"
  local max_mode="$5"
  local label="$6"
  local actual_owner actual_group actual_mode stat_out

  if [[ ! -e "$path" ]]; then
    warn "$label missing: $path"
    return 1
  fi

  if [[ -L "$path" ]]; then
    crit "$label must not be a symlink: $path"
    return 1
  fi

  if [[ "$expected_type" == "file" ]]; then
    if [[ ! -f "$path" ]]; then
      crit "$label is not a regular file: $path"
      return 1
    fi
  elif [[ "$expected_type" == "dir" ]]; then
    if [[ ! -d "$path" ]]; then
      crit "$label is not a directory: $path"
      return 1
    fi
  else
    warn "internal doctor error: unknown type '$expected_type' for $label"
    return 1
  fi

  stat_out="$(stat -Lc '%U %G %a' "$path" 2>/dev/null || true)"
  if [[ -z "$stat_out" ]]; then
    warn "unable to stat $label: $path"
    return 1
  fi
  IFS=' ' read -r actual_owner actual_group actual_mode <<<"$stat_out"

  if [[ "$actual_owner" != "$expected_owner" || "$actual_group" != "$expected_group" ]]; then
    crit "$label ownership should be $expected_owner:$expected_group (found $actual_owner:$actual_group): $path"
    return 1
  fi

  if ! mode_is_subset "$actual_mode" "$max_mode"; then
    crit "$label permissions too broad (mode $actual_mode, expected <= $max_mode): $path"
    return 1
  fi
}

resolve_config_value() {
  local key="$1"
  local cfg="/etc/papercut-hive-lite/config.env"
  [[ -r "$cfg" ]] || return 0
  sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$cfg" | head -n1
}

prompt_yes_no() {
  local prompt="$1"
  if [[ $AUTO_YES -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi
  read -r -p "$prompt [Y/n] " ans
  case "${ans:-Y}" in
    y|Y|yes|YES|'') return 0 ;;
    *) return 1 ;;
  esac
}

token_state() {
  local tok="${1:-}"
  python3 - 3<<<"$tok" <<'PY'
import base64
import json
import os
import sys
import time

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as stream:
    tok = (stream.read() or "").strip()
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
    print("VALID:no-exp")
    raise SystemExit(0)
exp_i = int(exp)
if exp_i <= int(time.time()) + 60:
    print(f"EXPIRED:{exp_i}")
else:
    print(f"VALID:{exp_i}")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --allow-queue-recreate) ALLOW_QUEUE_RECREATE=1; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  ORG_ID="$(resolve_config_value PAPERCUT_ORG_ID)"
fi
if [[ "$CLOUD_HOST" == "eu.hive.papercut.com" ]]; then
  cfg_host="$(resolve_config_value PAPERCUT_CLOUD_HOST)"
  if [[ -n "$cfg_host" ]]; then
    CLOUD_HOST="$cfg_host"
  fi
fi

log_event --component doctor --event start --message "Doctor started" --kv "user=$LINUX_USER" --kv "printer=$PRINTER_NAME" --kv "dry_run=$DRY_RUN"

echo "[doctor] checking dependencies"
REQUIRED_PACKAGES=(
  cups cups-client cups-filters file
  python3 python3-requests python3-venv
  libsecret-tools dbus-user-session gnome-keyring libnotify-bin
)
MISSING_PKGS=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! is_pkg_installed "$pkg"; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  echo "[doctor] missing packages: ${MISSING_PKGS[*]}"
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "dry-run mode: missing packages not installed"
  else
    if ! prompt_yes_no "Install missing packages now using apt-get?"; then
      log_event --component doctor --level error --event deps-refused --message "User refused dependency install" --kv "count=${#MISSING_PKGS[@]}"
      echo "Dependency install refused by user." >&2
      exit $RC_DEP_REFUSED
    fi
    if ! sudo apt-get update -y; then
      log_event --component doctor --level error --event deps-install-failed --message "apt-get update failed"
      echo "Failed: apt-get update" >&2
      exit $RC_DEP_FAIL
    fi
    if ! sudo apt-get install -y "${MISSING_PKGS[@]}"; then
      log_event --component doctor --level error --event deps-install-failed --message "apt-get install failed" --kv "count=${#MISSING_PKGS[@]}"
      echo "Failed: apt-get install ${MISSING_PKGS[*]}" >&2
      exit $RC_DEP_FAIL
    fi
    still_missing=()
    for pkg in "${MISSING_PKGS[@]}"; do
      is_pkg_installed "$pkg" || still_missing+=("$pkg")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
      log_event --component doctor --level error --event deps-install-incomplete --message "Packages still missing after install" --kv "count=${#still_missing[@]}"
      echo "Packages still missing after install: ${still_missing[*]}" >&2
      exit $RC_DEP_FAIL
    fi
    echo "[doctor] dependencies installed"
  fi
else
  echo "[doctor] dependencies OK"
fi

echo "[doctor] checking CUPS"
if ! command -v lpstat >/dev/null 2>&1; then
  crit "lpstat not found"
fi
if ! command -v systemctl >/dev/null 2>&1; then
  crit "systemctl not found"
else
  if ! systemctl is-active --quiet cups; then
    crit "cups service is not active"
  fi
fi
if [[ ! -x /usr/lib/cups/backend/papercut-hive-lite ]]; then
  if [[ $ALLOW_QUEUE_RECREATE -eq 1 ]]; then
    warn "CUPS backend missing: /usr/lib/cups/backend/papercut-hive-lite (will be installed)"
  else
    crit "CUPS backend missing: /usr/lib/cups/backend/papercut-hive-lite"
  fi
fi
if command -v lpstat >/dev/null 2>&1; then
  if ! lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    if [[ $ALLOW_QUEUE_RECREATE -eq 1 ]]; then
      warn "queue not found: $PRINTER_NAME (will be created during install)"
    else
      crit "queue not found: $PRINTER_NAME"
    fi
  else
    uri_line="$(lpstat -v "$PRINTER_NAME" 2>/dev/null | head -n1 || true)"
    if [[ "$uri_line" != *"papercut-hive-lite:/"* ]]; then
      if [[ $ALLOW_QUEUE_RECREATE -eq 1 ]]; then
        warn "queue URI mismatch for $PRINTER_NAME; existing queue will be replaced during install"
      else
        crit "queue URI mismatch for $PRINTER_NAME (expected papercut-hive-lite:/)"
      fi
    fi
  fi
fi

echo "[doctor] checking user timers"
TOKEN_TIMER_PATH="$HOME/.config/systemd/user/papercut-hive-token-sync.timer"
ALERT_TIMER_PATH="$HOME/.config/systemd/user/papercut-hive-alert-notify.timer"
[[ -f "$TOKEN_TIMER_PATH" ]] || warn "missing timer unit file: papercut-hive-token-sync.timer"
[[ -f "$ALERT_TIMER_PATH" ]] || warn "missing timer unit file: papercut-hive-alert-notify.timer"

HAS_USER_DBUS=1
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
  HAS_USER_DBUS=0
  warn "no user DBus session detected; timer/keyring runtime checks are limited"
fi

if [[ $HAS_USER_DBUS -eq 1 ]]; then
  if ! systemctl --user is-enabled papercut-hive-token-sync.timer >/dev/null 2>&1; then
    warn "token sync timer is not enabled"
  fi
  if ! systemctl --user is-active papercut-hive-token-sync.timer >/dev/null 2>&1; then
    warn "token sync timer is not active"
  fi
  if ! systemctl --user is-enabled papercut-hive-alert-notify.timer >/dev/null 2>&1; then
    warn "alert notify timer is not enabled"
  fi
fi

echo "[doctor] checking keyring + token"
if ! command -v secret-tool >/dev/null 2>&1; then
  crit "secret-tool missing"
else
  if [[ -n "$ORG_ID" ]]; then
    token="$(secret-tool lookup papercut hive-lite kind user-jwt user "$LINUX_USER" org "$ORG_ID" cloud "$CLOUD_HOST" || true)"
    state="$(token_state "$token")"
    if [[ "$state" == MISSING* ]]; then
      warn "token state: MISSING"
    elif [[ "$state" == INVALID* ]]; then
      warn "token state: INVALID"
    elif [[ "$state" == EXPIRED* ]]; then
      warn "token state: EXPIRED"
    else
      echo "[doctor] token state: $state"
    fi
    unset token
  else
    warn "ORG_ID unknown: token state check skipped"
  fi
fi

echo "[doctor] checking sensitive file permissions"
check_secure_path /etc/papercut-hive-lite/config.env file root lp 640 "config.env" || true
check_secure_path /etc/papercut-hive-lite/tokens dir root lp 750 "tokens directory" || true
if [[ -f "/usr/local/sbin/papercut-hive-token-sync" ]]; then
  check_secure_path /usr/local/sbin/papercut-hive-token-sync file root root 755 "root token sync helper" || true
else
  warn "root token sync helper missing: /usr/local/sbin/papercut-hive-token-sync"
fi

if [[ "$LINUX_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  user_token_file="/etc/papercut-hive-lite/tokens/${LINUX_USER}.jwt"
  if [[ -f "$user_token_file" ]]; then
    check_secure_path "$user_token_file" file root lp 640 "user token file" || true
  fi
else
  warn "linux user contains unsafe characters, skipping token path check for '$LINUX_USER'"
fi

if [[ -f "/etc/papercut-hive-lite/tokens/default.jwt" ]]; then
  check_secure_path /etc/papercut-hive-lite/tokens/default.jwt file root lp 640 "default token file" || true
fi

summary="warnings=$WARNINGS criticals=$CRITICALS"
echo "[doctor] summary: $summary"

if [[ $CRITICALS -gt 0 ]]; then
  log_event --component doctor --level error --event complete --message "Doctor completed with critical issues" --kv "warnings=$WARNINGS" --kv "criticals=$CRITICALS" --kv "code=$RC_CRITICAL"
  exit $RC_CRITICAL
fi

if [[ $WARNINGS -gt 0 ]]; then
  log_event --component doctor --level warning --event complete --message "Doctor completed with warnings" --kv "warnings=$WARNINGS" --kv "criticals=$CRITICALS" --kv "code=$RC_WARN"
  exit $RC_WARN
fi

log_event --component doctor --level info --event complete --message "Doctor completed successfully" --kv "warnings=0" --kv "criticals=0" --kv "code=$RC_OK"
exit $RC_OK
