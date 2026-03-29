#!/usr/bin/env bash

# Shared terminal UI helpers for PaperCut Hive scripts.

PAPERCUT_UI_COLOR=0
PAPERCUT_UI_PROGRESS=0
PAPERCUT_UI_RESET=""
PAPERCUT_UI_BOLD=""
PAPERCUT_UI_DIM=""
PAPERCUT_UI_BLUE=""
PAPERCUT_UI_GREEN=""
PAPERCUT_UI_YELLOW=""
PAPERCUT_UI_RED=""

papercut_ui_init() {
  local no_color="${1:-0}"
  local no_progress="${2:-0}"

  PAPERCUT_UI_COLOR=1
  if [[ "$no_color" -eq 1 || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" || ! -t 1 ]]; then
    PAPERCUT_UI_COLOR=0
  fi

  PAPERCUT_UI_PROGRESS=1
  if [[ "$no_progress" -eq 1 || ! -t 1 ]]; then
    PAPERCUT_UI_PROGRESS=0
  fi

  if [[ "$PAPERCUT_UI_COLOR" -eq 1 ]]; then
    PAPERCUT_UI_RESET=$'\033[0m'
    PAPERCUT_UI_BOLD=$'\033[1m'
    PAPERCUT_UI_DIM=$'\033[2m'
    PAPERCUT_UI_BLUE=$'\033[34m'
    PAPERCUT_UI_GREEN=$'\033[32m'
    PAPERCUT_UI_YELLOW=$'\033[33m'
    PAPERCUT_UI_RED=$'\033[31m'
  else
    PAPERCUT_UI_RESET=""
    PAPERCUT_UI_BOLD=""
    PAPERCUT_UI_DIM=""
    PAPERCUT_UI_BLUE=""
    PAPERCUT_UI_GREEN=""
    PAPERCUT_UI_YELLOW=""
    PAPERCUT_UI_RED=""
  fi
}

papercut_ui_progress_bar() {
  local index="$1"
  local total="$2"
  local width=20

  if [[ "$total" -le 0 ]]; then
    total=1
  fi
  if [[ "$index" -lt 0 ]]; then
    index=0
  fi
  if [[ "$index" -gt "$total" ]]; then
    index="$total"
  fi

  local fill=$(( index * width / total ))
  local remain=$(( width - fill ))
  local fill_str remain_str
  fill_str="$(printf '%*s' "$fill" '' | tr ' ' '#')"
  remain_str="$(printf '%*s' "$remain" '' | tr ' ' '-')"
  printf '[%s%s] %d/%d' "$fill_str" "$remain_str" "$index" "$total"
}

papercut_ui_step_start() {
  local index="$1"
  local total="$2"
  local label="$3"
  local progress=""

  if [[ "$PAPERCUT_UI_PROGRESS" -eq 1 ]]; then
    progress="$(papercut_ui_progress_bar "$index" "$total") "
  fi

  printf '%b%s[STEP]%b %s\n' "$PAPERCUT_UI_BLUE" "$progress" "$PAPERCUT_UI_RESET" "$label"
}

papercut_ui_step_ok() {
  local message="$1"
  printf '%b[ OK ]%b %s\n' "$PAPERCUT_UI_GREEN" "$PAPERCUT_UI_RESET" "$message"
}

papercut_ui_step_warn() {
  local message="$1"
  printf '%b[WARN]%b %s\n' "$PAPERCUT_UI_YELLOW" "$PAPERCUT_UI_RESET" "$message"
}

papercut_ui_step_fail() {
  local message="$1"
  printf '%b[FAIL]%b %s\n' "$PAPERCUT_UI_RED" "$PAPERCUT_UI_RESET" "$message"
}

papercut_ui_note() {
  local message="$1"
  printf '%b[INFO]%b %s\n' "$PAPERCUT_UI_DIM" "$PAPERCUT_UI_RESET" "$message"
}

papercut_ui_actions_block() {
  local title="$1"
  shift || true

  printf '\n%b%s%b\n' "$PAPERCUT_UI_BOLD" "$title" "$PAPERCUT_UI_RESET"
  local line
  for line in "$@"; do
    [[ -n "$line" ]] || continue
    printf '  - %s\n' "$line"
  done
  printf '\n'
}
