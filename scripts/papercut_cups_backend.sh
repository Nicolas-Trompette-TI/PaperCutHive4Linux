#!/usr/bin/env bash
set -euo pipefail

# CUPS backend for PaperCut Hive Lite
# CUPS calls backend with:
#   argv[1]=job-id argv[2]=user argv[3]=title argv[4]=copies argv[5]=options argv[6]=file

BACKEND_NAME="papercut-hive-lite"
LIB_DIR="/usr/local/lib/papercut-hive-lite"
SUBMIT_PY="$LIB_DIR/papercut_submit_job_poc.py"
CFG_FILE="/etc/papercut-hive-lite/config.env"
TOKENS_DIR="/etc/papercut-hive-lite/tokens"

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

if [[ ! -f "$CFG_FILE" ]]; then
  echo "[$BACKEND_NAME] missing config: $CFG_FILE" >&2
  exit 1
fi
if [[ ! -r "$CFG_FILE" ]]; then
  echo "[$BACKEND_NAME] config is not readable by backend user: $CFG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CFG_FILE"

: "${PAPERCUT_CLOUD_HOST:=eu.hive.papercut.com}"
: "${PAPERCUT_ORG_ID:=}"
: "${PAPERCUT_CLIENT_TYPE:=ChromeApp-2.4.1}"
: "${PAPERCUT_TIMEOUT:=60}"
: "${PAPERCUT_DRY_RUN:=0}"
: "${PAPERCUT_TARGET_URL:=}"
: "${PAPERCUT_ID_TOKEN:=}"
: "${PAPERCUT_USER_JWT:=}"
: "${PAPERCUT_STATE_DIR:=/var/lib/papercut-hive-lite}"

if [[ -f "$TOKENS_DIR/$CUPS_USER.jwt" ]]; then
  if [[ ! -r "$TOKENS_DIR/$CUPS_USER.jwt" ]]; then
    echo "[$BACKEND_NAME] token file exists but is not readable: $TOKENS_DIR/$CUPS_USER.jwt" >&2
    exit 1
  fi
  PAPERCUT_USER_JWT="$(tr -d '\n' < "$TOKENS_DIR/$CUPS_USER.jwt")"
elif [[ -f "$TOKENS_DIR/default.jwt" ]]; then
  if [[ ! -r "$TOKENS_DIR/default.jwt" ]]; then
    echo "[$BACKEND_NAME] token file exists but is not readable: $TOKENS_DIR/default.jwt" >&2
    exit 1
  fi
  PAPERCUT_USER_JWT="$(tr -d '\n' < "$TOKENS_DIR/default.jwt")"
fi

WORK_INPUT=""
TMP_INPUT=""
TMP_PDF=""
cleanup() {
  [[ -n "$TMP_INPUT" && -f "$TMP_INPUT" ]] && rm -f "$TMP_INPUT" || true
  [[ -n "$TMP_PDF" && -f "$TMP_PDF" ]] && rm -f "$TMP_PDF" || true
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
  python3 "$SUBMIT_PY"
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

if [[ -n "$PAPERCUT_TARGET_URL" ]]; then
  cmd+=(--target-url "$PAPERCUT_TARGET_URL")
fi

if [[ "$PAPERCUT_DRY_RUN" == "1" ]]; then
  cmd+=(--offline-dry-run)
fi

if [[ -n "$PAPERCUT_USER_JWT" ]]; then
  cmd+=(--user-jwt "$PAPERCUT_USER_JWT")
elif [[ -n "$PAPERCUT_ID_TOKEN" ]]; then
  cmd+=(--id-token "$PAPERCUT_ID_TOKEN")
else
  echo "[$BACKEND_NAME] missing token for user '$CUPS_USER' (no jwt/id-token configured)" >&2
  exit 1
fi

# Send backend output to CUPS error_log via stderr for troubleshooting.
export PAPERCUT_STATE_DIR
if ! "${cmd[@]}" 1>&2; then
  echo "[$BACKEND_NAME] submit failed for job=$JOB_ID user=$CUPS_USER title=$TITLE" >&2
  exit 1
fi

exit 0
