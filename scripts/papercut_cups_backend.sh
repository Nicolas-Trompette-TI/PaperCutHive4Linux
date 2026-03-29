#!/usr/bin/env bash
set -euo pipefail

# CUPS backend for PaperCut Hive Lite
# CUPS calls backend with:
#   argv[1]=job-id argv[2]=user argv[3]=title argv[4]=copies argv[5]=options argv[6]=file

BACKEND_NAME="papercut-hive-lite"
LIB_DIR="/usr/local/lib/papercut-hive-lite"
SUBMIT_PY="$LIB_DIR/papercut_submit_job.py"
CFG_FILE="/etc/papercut-hive-lite/config.env"
PY_ENV_FILE="/etc/papercut-hive-lite/python.env"
TOKENS_DIR="/etc/papercut-hive-lite/tokens"

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

require_secure_path() {
  local path="$1"
  local expected_type="$2"
  local expected_owner="$3"
  local expected_group="$4"
  local max_mode="$5"
  local label="$6"
  local stat_out owner group mode

  if [[ ! -e "$path" ]]; then
    echo "[$BACKEND_NAME] missing $label: $path" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    echo "[$BACKEND_NAME] refusing symlink for $label: $path" >&2
    return 1
  fi
  if [[ "$expected_type" == "file" ]]; then
    if [[ ! -f "$path" ]]; then
      echo "[$BACKEND_NAME] invalid $label (not regular file): $path" >&2
      return 1
    fi
  elif [[ "$expected_type" == "dir" ]]; then
    if [[ ! -d "$path" ]]; then
      echo "[$BACKEND_NAME] invalid $label (not directory): $path" >&2
      return 1
    fi
  else
    echo "[$BACKEND_NAME] internal error: invalid secure path type '$expected_type'" >&2
    return 1
  fi

  stat_out="$(stat -Lc '%U %G %a' "$path" 2>/dev/null || true)"
  if [[ -z "$stat_out" ]]; then
    echo "[$BACKEND_NAME] unable to stat $label: $path" >&2
    return 1
  fi
  IFS=' ' read -r owner group mode <<<"$stat_out"

  if [[ "$owner" != "$expected_owner" || "$group" != "$expected_group" ]]; then
    echo "[$BACKEND_NAME] insecure ownership for $label (expected $expected_owner:$expected_group, got $owner:$group): $path" >&2
    return 1
  fi
  if ! mode_is_subset "$mode" "$max_mode"; then
    echo "[$BACKEND_NAME] insecure permissions for $label (mode $mode exceeds $max_mode): $path" >&2
    return 1
  fi
  return 0
}

load_secure_env_file() {
  local path="$1"
  local label="$2"
  local code="$3"
  if ! require_secure_path "$path" file root lp 640 "$label"; then
    record_alert "$code"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$path"
}

if [[ $# -le 1 ]]; then
  echo "network ${BACKEND_NAME} \"Unknown\" \"PaperCut Hive Lite (CUPS backend)\" \"PaperCut Hive Lite\""
  exit 0
fi

JOB_ID="${1:-}"
CUPS_USER="${2:-unknown}"
TITLE="${3:-Untitled}"
COPIES="${4:-1}"
OPTIONS="${5:-}"
INPUT_FILE="${6:-}"

record_alert() {
  local code="$1"
  [[ "${PAPERCUT_NOTIFY_ERRORS:-1}" == "1" ]] || return 0

  local ts safe_user safe_job safe_code queue alert_dir alert_file
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  safe_user="$(printf '%s' "$CUPS_USER" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  safe_job="$(printf '%s' "${JOB_ID:-unknown}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  safe_code="$(printf '%s' "$code" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  queue="${PAPERCUT_QUEUE_NAME:-PaperCut-Hive-TIF}"
  alert_dir="${PAPERCUT_ALERT_DIR:-/var/lib/papercut-hive-lite/alerts}"

  [[ -n "$safe_user" ]] || safe_user="unknown"
  [[ -n "$safe_job" ]] || safe_job="unknown"
  [[ -n "$safe_code" ]] || safe_code="submit-failed"

  mkdir -p "$alert_dir" >/dev/null 2>&1 || return 0
  alert_file="$alert_dir/${safe_user}-${ts}-${safe_job}-${safe_code}.alert"
  {
    echo "timestamp=$ts"
    echo "user=$safe_user"
    echo "queue=$queue"
    echo "job_id=$safe_job"
    echo "code=$safe_code"
  } >"$alert_file" 2>/dev/null || true
  chmod 644 "$alert_file" 2>/dev/null || true
}

if [[ ! -r "$CFG_FILE" ]]; then
  echo "[$BACKEND_NAME] config is not readable by backend user: $CFG_FILE" >&2
  record_alert "unreadable-config"
  exit 1
fi
load_secure_env_file "$CFG_FILE" "config file" "insecure-config"
if [[ -e "$PY_ENV_FILE" ]]; then
  if [[ ! -r "$PY_ENV_FILE" ]]; then
    echo "[$BACKEND_NAME] python env exists but is not readable: $PY_ENV_FILE" >&2
    record_alert "unreadable-python-env"
    exit 1
  fi
  load_secure_env_file "$PY_ENV_FILE" "python env file" "insecure-python-env"
fi

: "${PAPERCUT_CLOUD_HOST:=eu.hive.papercut.com}"
: "${PAPERCUT_ORG_ID:=}"
: "${PAPERCUT_CLIENT_TYPE:=ChromeApp-2.4.1}"
: "${PAPERCUT_TIMEOUT:=60}"
: "${PAPERCUT_DRY_RUN:=0}"
: "${PAPERCUT_TARGET_URL:=}"
: "${PAPERCUT_ID_TOKEN:=}"
: "${PAPERCUT_USER_JWT:=}"
: "${PAPERCUT_STATE_DIR:=/var/lib/papercut-hive-lite}"
: "${PAPERCUT_ALERT_DIR:=/var/lib/papercut-hive-lite/alerts}"
: "${PAPERCUT_NOTIFY_ERRORS:=1}"
: "${PAPERCUT_QUEUE_NAME:=PaperCut-Hive-TIF}"
: "${PAPERCUT_PYTHON_BIN:=}"

if ! require_secure_path "$TOKENS_DIR" dir root lp 750 "tokens directory"; then
  record_alert "insecure-token-dir"
  exit 1
fi

if [[ "$CUPS_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  user_token_file="$TOKENS_DIR/$CUPS_USER.jwt"
  if [[ -f "$user_token_file" ]]; then
    if ! require_secure_path "$user_token_file" file root lp 640 "user token file"; then
      record_alert "insecure-token-file"
      exit 1
    fi
    PAPERCUT_USER_JWT="$(tr -d '\n' < "$user_token_file")"
  fi
else
  echo "[$BACKEND_NAME] rejecting unsafe CUPS user for token lookup: '$CUPS_USER'" >&2
  record_alert "invalid-user"
fi

default_token_file="$TOKENS_DIR/default.jwt"
if [[ -z "$PAPERCUT_USER_JWT" && -f "$default_token_file" ]]; then
  if ! require_secure_path "$default_token_file" file root lp 640 "default token file"; then
    record_alert "insecure-token-file"
    exit 1
  fi
  PAPERCUT_USER_JWT="$(tr -d '\n' < "$default_token_file")"
fi

WORK_INPUT=""
TMP_INPUT=""
TMP_PDF=""
AUTH_MODE=""
AUTH_TOKEN=""
cleanup() {
  [[ -n "$TMP_INPUT" && -f "$TMP_INPUT" ]] && rm -f "$TMP_INPUT" || true
  [[ -n "$TMP_PDF" && -f "$TMP_PDF" ]] && rm -f "$TMP_PDF" || true
  unset PAPERCUT_USER_JWT PAPERCUT_ID_TOKEN AUTH_MODE AUTH_TOKEN user_token_file default_token_file
}
trap cleanup EXIT

if [[ -n "$INPUT_FILE" && -f "$INPUT_FILE" ]]; then
  WORK_INPUT="$INPUT_FILE"
else
  TMP_INPUT="$(mktemp /tmp/papercut-cups-input-XXXXXX)"
  cat > "$TMP_INPUT"
  WORK_INPUT="$TMP_INPUT"
fi

mime="$(file --mime-type -b "$WORK_INPUT" 2>/dev/null || echo application/octet-stream)"
SEND_FILE="$WORK_INPUT"
FILE_FORMAT="$mime"

# Extension flow is PDF-centric; convert non-PDF jobs if possible.
if [[ "$mime" != "application/pdf" ]]; then
  if command -v cupsfilter >/dev/null 2>&1; then
    TMP_PDF="$(mktemp /tmp/papercut-cups-pdf-XXXXXX.pdf)"
    cupsfilter -m application/pdf "$WORK_INPUT" > "$TMP_PDF"
    SEND_FILE="$TMP_PDF"
    FILE_FORMAT="application/pdf"
  else
    echo "[$BACKEND_NAME] non-PDF input ($mime) and cupsfilter is unavailable" >&2
    record_alert "cupsfilter-missing"
    exit 1
  fi
fi

# Parse CUPS options string (key=value key=value ...)
get_opt() {
  local key="$1" default="$2"
  local token
  for token in $OPTIONS; do
    if [[ "$token" == "$key="* ]]; then
      echo "${token#*=}"
      return 0
    fi
  done
  echo "$default"
}

sides="$(get_opt sides one-sided)"
color_model="$(get_opt ColorModel AUTO)"
media="$(get_opt media A4)"

duplex="NO_DUPLEX"
case "$sides" in
  two-sided-long-edge) duplex="LONG_EDGE" ;;
  two-sided-short-edge) duplex="SHORT_EDGE" ;;
  *) duplex="NO_DUPLEX" ;;
esac

color="AUTO"
case "${color_model^^}" in
  *GRAY*|*MONO*) color="STANDARD_MONOCHROME" ;;
  *COLOR*) color="STANDARD_COLOR" ;;
  *) color="AUTO" ;;
esac

media_w=210000
media_h=297000
case "${media^^}" in
  *LETTER*) media_w=215900; media_h=279400 ;;
  *LEGAL*) media_w=215900; media_h=355600 ;;
  *A3*) media_w=297000; media_h=420000 ;;
  *A5*) media_w=148000; media_h=210000 ;;
  *) media_w=210000; media_h=297000 ;;
esac

cmd=(
  ""
  "$SUBMIT_PY"
  --cloud-host "$PAPERCUT_CLOUD_HOST"
  --org-id "$PAPERCUT_ORG_ID"
  --file "$SEND_FILE"
  --title "$TITLE"
  --copies "$COPIES"
  --duplex "$duplex"
  --color "$color"
  --media-width "$media_w"
  --media-height "$media_h"
  --file-format "$FILE_FORMAT"
  --client-type "$PAPERCUT_CLIENT_TYPE"
  --timeout "$PAPERCUT_TIMEOUT"
)

pick_python() {
  local py
  local candidates=()
  if [[ -n "${PAPERCUT_PYTHON_BIN:-}" ]]; then
    candidates+=("$PAPERCUT_PYTHON_BIN")
  fi
  candidates+=("/usr/bin/python3" "$LIB_DIR/.venv/bin/python3")

  for py in "${candidates[@]}"; do
    [[ -x "$py" ]] || continue
    if "$py" - <<'PY' >/dev/null 2>&1
import requests
print(requests.__version__)
PY
    then
      printf '%s\n' "$py"
      return 0
    fi
  done
  return 1
}

if ! runtime_python="$(pick_python)"; then
  echo "[$BACKEND_NAME] no valid Python runtime found (requests unavailable)." >&2
  record_alert "python-runtime"
  exit 1
fi
cmd[0]="$runtime_python"

if [[ -n "$PAPERCUT_TARGET_URL" ]]; then
  cmd+=(--target-url "$PAPERCUT_TARGET_URL")
fi

if [[ "$PAPERCUT_DRY_RUN" == "1" ]]; then
  cmd+=(--offline-dry-run)
fi

if [[ -n "$PAPERCUT_USER_JWT" ]]; then
  AUTH_MODE="--user-jwt-stdin"
  AUTH_TOKEN="$PAPERCUT_USER_JWT"
elif [[ -n "$PAPERCUT_ID_TOKEN" ]]; then
  AUTH_MODE="--id-token-stdin"
  AUTH_TOKEN="$PAPERCUT_ID_TOKEN"
else
  echo "[$BACKEND_NAME] missing token for user '$CUPS_USER' (no jwt/id-token configured)" >&2
  record_alert "missing-token"
  exit 1
fi
cmd+=("$AUTH_MODE")

# Send backend output to CUPS error_log via stderr for troubleshooting.
export PAPERCUT_STATE_DIR
if printf '%s\n' "$AUTH_TOKEN" | "${cmd[@]}" 1>&2; then
  :
else
  rc=$?
  echo "[$BACKEND_NAME] submit failed for job=$JOB_ID user=$CUPS_USER title=$TITLE" >&2
  if [[ $rc -eq 11 ]]; then
    record_alert "token-invalid"
  else
    record_alert "submit-failed"
  fi
  exit 1
fi

exit 0
