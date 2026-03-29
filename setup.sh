#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
UI_LIB="$BASE/scripts/papercut_cli_ui.sh"
if [[ -r "$UI_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$UI_LIB"
else
  papercut_ui_init() { :; }
  papercut_ui_step_start() { echo "[setup] $3"; }
  papercut_ui_step_ok() { echo "[ok] $1"; }
  papercut_ui_step_warn() { echo "[warn] $1"; }
  papercut_ui_step_fail() { echo "[fail] $1"; }
  papercut_ui_note() { echo "[info] $1"; }
  papercut_ui_actions_block() {
    local title="$1"
    shift || true
    echo "$title"
    local line
    for line in "$@"; do
      [[ -n "$line" ]] || continue
      echo "  - $line"
    done
  }
fi

ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
LINUX_USER="${USER}"
PRINTER_NAME="PaperCut-Hive-TIF"
PROFILE_DIR=""
NO_BOOTSTRAP=0
SKIP_VERIFY=0
DRY_RUN=0
AUTO_YES=0
ENABLE_NOTIFY=1
PYTHON_MODE="auto"
MODE="setup"
AUTH_MODE="password"
LOGIN_EMAIL=""
BOOTSTRAP_JWT=""
FINALIZE_SKIP_EXTENSION_BOOTSTRAP=0
NO_COLOR_FLAG=0
NO_PROGRESS=0

RC_WARN=2
RC_DEP_REFUSED=20
RC_DEP_FAIL=21
RC_CRITICAL=22
EXISTING_PRINTER_QUEUE=0
EXISTING_PRINTER_URI=""
EXISTING_PRINTER_IS_PAPERCUT=0

STEP_TOTAL=6
STEP_INDEX=0
PREFLIGHT_WARNINGS=0
NEEDS_MANUAL_FINALIZE=0
JWT_STORE_FAILED=0
VERIFY_DEGRADED=0
VERIFY_REPAIRED=0
MANUAL_ACTIONS=()

usage() {
  cat <<USAGE
Usage: $0 [mode] [options]

Modes:
  (default)    install/finalize/verify with mandatory doctor preflight
  --doctor     run doctor checks only
  --repair     run doctor + automatic repair

Options:
  --org-id <ORG_ID>             optional in doctor mode, auto-detected in setup when possible
  --cloud-host <host>           default: eu.hive.papercut.com
  --linux-user <user>           default: current user
  --printer-name <name>         default: PaperCut-Hive-TIF
  --auth-mode <auto|extension|password>
                                 default: password
                                 auto      -> try password login first, then fallback to extension/config/manual flow
                                 extension -> extension/config/org prompt flow only
                                 password  -> prompt PaperCut login (email/password), no extension required
  --login-email <email>         optional prefilled email for --auth-mode password
  --profile-dir <dir>           browser profile dir (extension bootstrap)
  --no-bootstrap-from-extension skip extension -> keyring bootstrap
  --skip-verify                 do not run release/verify-print.sh
  --python-mode <auto|apt-only> default: auto
  --no-notify                   disable desktop notifications
  --no-color                    disable ANSI colors (or set NO_COLOR)
  --no-progress                 disable progress bar rendering
  -y, --yes                     accept interactive prompts
  --dry-run                     print actions without applying
  -h, --help                    show help

Final status codes in setup mode:
  0   ready
  2   partial success (manual action required)
  20  dependency install refused
  21  dependency install failed
  22  critical non-recoverable blocker
USAGE
}

resolve_config_value() {
  local key="$1"
  local cfg="/etc/papercut-hive-lite/config.env"
  [[ -r "$cfg" ]] || return 0
  sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$cfg" | head -n1
}

detect_org_id() {
  local -a cmd=("$BASE/scripts/papercut_detect_org_id.sh")
  if [[ -n "$PROFILE_DIR" ]]; then
    cmd+=(--profile-dir "$PROFILE_DIR")
  fi
  "${cmd[@]}" 2>/dev/null || true
}

parse_org_input() {
  local raw="$1"
  "$BASE/scripts/papercut_detect_org_id.sh" --from-input "$raw" 2>/dev/null || true
}

detect_existing_printer_queue() {
  EXISTING_PRINTER_QUEUE=0
  EXISTING_PRINTER_URI=""
  EXISTING_PRINTER_IS_PAPERCUT=0

  if ! command -v lpstat >/dev/null 2>&1; then
    return 0
  fi

  if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    EXISTING_PRINTER_QUEUE=1
    EXISTING_PRINTER_URI="$(lpstat -v "$PRINTER_NAME" 2>/dev/null | head -n1 || true)"
    if [[ "$EXISTING_PRINTER_URI" == *"papercut-hive-lite:/"* ]]; then
      EXISTING_PRINTER_IS_PAPERCUT=1
    fi
  fi
}

password_login_bootstrap() {
  local -a cmd=(
    "$BASE/scripts/papercut_password_login.py"
    --cloud-host "$CLOUD_HOST"
    --json
  )
  if [[ -n "$ORG_ID" ]]; then
    cmd+=(--org-id "$ORG_ID")
  fi
  if [[ -n "$LOGIN_EMAIL" ]]; then
    cmd+=(--email "$LOGIN_EMAIL")
  fi

  local login_json
  if ! login_json="$("${cmd[@]}")"; then
    return 1
  fi

  local parsed parsed_org parsed_jwt
  parsed="$(python3 - 3<<<"$login_json" <<'PY'
import json
import os

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as stream:
    data = json.loads(stream.read() or "{}")
print("{}\t{}".format(data.get("org_id", ""), data.get("user_jwt", "")))
PY
)"
  unset login_json
  IFS=$'\t' read -r parsed_org parsed_jwt <<<"$parsed"

  if [[ -z "$parsed_org" || -z "$parsed_jwt" ]]; then
    echo "Password login did not return required org/token values." >&2
    return 1
  fi

  ORG_ID="$parsed_org"
  BOOTSTRAP_JWT="$parsed_jwt"
  NO_BOOTSTRAP=1
  FINALIZE_SKIP_EXTENSION_BOOTSTRAP=1
  return 0
}

log_event() {
  if [[ -x "$BASE/scripts/papercut_event_log.sh" ]]; then
    "$BASE/scripts/papercut_event_log.sh" "$@" || true
  fi
}

notify_user() {
  local level="$1"
  local message="$2"
  [[ $ENABLE_NOTIFY -eq 1 ]] || return 0
  local notify_cmd=(
    "$BASE/scripts/papercut_notify.sh"
    --level "$level"
    --title "PaperCut Hive Driver"
    --message "$message"
  )
  if [[ $DRY_RUN -eq 1 ]]; then
    notify_cmd+=(--dry-run)
  fi
  "${notify_cmd[@]}" || true
}

on_error() {
  log_event --component setup --level error --event failed --message "Setup execution failed"
  notify_user error "Setup failed. Check terminal logs for details."
}
trap on_error ERR

add_manual_action() {
  local action="$1"
  local existing
  for existing in "${MANUAL_ACTIONS[@]}"; do
    if [[ "$existing" == "$action" ]]; then
      return 0
    fi
  done
  MANUAL_ACTIONS+=("$action")
}

step_start() {
  STEP_INDEX=$((STEP_INDEX + 1))
  papercut_ui_step_start "$STEP_INDEX" "$STEP_TOTAL" "$1"
}

run_cmd_capture() {
  set +e
  "$@"
  local rc=$?
  set -e
  return "$rc"
}

queue_replace_confirmation() {
  if [[ $EXISTING_PRINTER_QUEUE -eq 0 ]]; then
    return 0
  fi

  if [[ $EXISTING_PRINTER_IS_PAPERCUT -eq 1 ]]; then
    papercut_ui_note "Existing PaperCut queue '$PRINTER_NAME' detected; it will be refreshed in place."
    [[ -n "$EXISTING_PRINTER_URI" ]] && papercut_ui_note "Current queue: $EXISTING_PRINTER_URI"
    return 0
  fi

  papercut_ui_step_warn "A non-PaperCut queue named '$PRINTER_NAME' exists and will be deleted/replaced."
  [[ -n "$EXISTING_PRINTER_URI" ]] && papercut_ui_note "Current queue: $EXISTING_PRINTER_URI"
  log_event --component setup --level warning --event queue-replace --message "Non-PaperCut queue replacement required" --kv "printer=$PRINTER_NAME"

  if [[ $DRY_RUN -eq 1 ]]; then
    papercut_ui_note "Dry-run: destructive queue replacement prompt skipped."
    return 0
  fi

  if [[ $AUTO_YES -eq 1 ]]; then
    papercut_ui_note "--yes enabled: queue replacement auto-approved."
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    read -r -p "Queue '$PRINTER_NAME' will be removed and replaced. Continue? [y/N] " replace_ans
    case "$replace_ans" in
      y|Y|yes|YES) return 0 ;;
      *)
        papercut_ui_step_fail "Setup cancelled by user (queue replacement refused)."
        log_event --component setup --level warning --event cancelled --message "Setup cancelled by user (queue replacement refused)"
        notify_user warning "Setup cancelled: existing queue replacement refused."
        exit 1
        ;;
    esac
  fi

  papercut_ui_step_fail "Non-interactive mode requires --yes to replace non-PaperCut queue '$PRINTER_NAME'."
  exit $RC_CRITICAL
}

print_manual_actions() {
  local finalize_cmd_str="$1"

  if [[ $NEEDS_MANUAL_FINALIZE -eq 1 ]]; then
    add_manual_action "Open a new graphical login session for user '$LINUX_USER'."
    add_manual_action "Run finalize: $finalize_cmd_str"
  fi

  if [[ $JWT_STORE_FAILED -eq 1 ]]; then
    add_manual_action "If keyring sync failed in this shell, rerun setup in desktop session: ./setup.sh --auth-mode password --cloud-host $CLOUD_HOST --linux-user $LINUX_USER --org-id $ORG_ID"
  fi

  if [[ $VERIFY_DEGRADED -eq 1 ]]; then
    add_manual_action "Retry verification: ./release/verify-print.sh --printer-name '$PRINTER_NAME'"
    add_manual_action "Inspect queue state: lpstat -p '$PRINTER_NAME' -l"
    add_manual_action "Inspect incomplete jobs: lpstat -W not-completed -o '$PRINTER_NAME'"
  fi

  if [[ ${#MANUAL_ACTIONS[@]} -gt 0 ]]; then
    papercut_ui_actions_block "Actions Required" "${MANUAL_ACTIONS[@]}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doctor)
      if [[ "$MODE" != "setup" ]]; then
        echo "Choose only one mode: --doctor or --repair" >&2
        exit 1
      fi
      MODE="doctor"
      shift
      ;;
    --repair)
      if [[ "$MODE" != "setup" ]]; then
        echo "Choose only one mode: --doctor or --repair" >&2
        exit 1
      fi
      MODE="repair"
      shift
      ;;
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --auth-mode) AUTH_MODE="${2:-}"; shift 2 ;;
    --login-email) LOGIN_EMAIL="${2:-}"; shift 2 ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --no-bootstrap-from-extension) NO_BOOTSTRAP=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --python-mode) PYTHON_MODE="${2:-}"; shift 2 ;;
    --no-notify) ENABLE_NOTIFY=0; shift ;;
    --no-color) NO_COLOR_FLAG=1; shift ;;
    --no-progress) NO_PROGRESS=1; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

papercut_ui_init "$NO_COLOR_FLAG" "$NO_PROGRESS"

if [[ -z "$ORG_ID" ]]; then
  ORG_ID="$(resolve_config_value PAPERCUT_ORG_ID)"
fi
if [[ "$CLOUD_HOST" == "eu.hive.papercut.com" ]]; then
  cfg_host="$(resolve_config_value PAPERCUT_CLOUD_HOST)"
  if [[ -n "$cfg_host" ]]; then
    CLOUD_HOST="$cfg_host"
  fi
fi
if [[ -z "$ORG_ID" && ! ("$MODE" == "setup" && "$AUTH_MODE" == "password") ]]; then
  ORG_ID="$(detect_org_id)"
  if [[ -n "$ORG_ID" ]]; then
    papercut_ui_note "Detected Org ID automatically: $ORG_ID"
  fi
fi

if [[ "$PYTHON_MODE" != "auto" && "$PYTHON_MODE" != "apt-only" ]]; then
  echo "Invalid --python-mode: $PYTHON_MODE" >&2
  exit 1
fi

if [[ "$AUTH_MODE" != "auto" && "$AUTH_MODE" != "extension" && "$AUTH_MODE" != "password" ]]; then
  echo "Invalid --auth-mode: $AUTH_MODE" >&2
  exit 1
fi

if [[ "$MODE" == "doctor" ]]; then
  log_event --component setup --event mode-doctor --message "Doctor mode invoked"
  doctor_cmd=(
    "$BASE/scripts/papercut_doctor.sh"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --printer-name "$PRINTER_NAME"
  )
  [[ -n "$ORG_ID" ]] && doctor_cmd+=(--org-id "$ORG_ID")
  [[ $AUTO_YES -eq 1 ]] && doctor_cmd+=(--yes)
  [[ $DRY_RUN -eq 1 ]] && doctor_cmd+=(--dry-run)
  exec "${doctor_cmd[@]}"
fi

if [[ "$MODE" == "repair" ]]; then
  log_event --component setup --event mode-repair --message "Repair mode invoked"
  repair_cmd=(
    "$BASE/scripts/papercut_repair.sh"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --printer-name "$PRINTER_NAME"
  )
  [[ -n "$ORG_ID" ]] && repair_cmd+=(--org-id "$ORG_ID")
  [[ -n "$PROFILE_DIR" ]] && repair_cmd+=(--profile-dir "$PROFILE_DIR")
  [[ $ENABLE_NOTIFY -eq 0 ]] && repair_cmd+=(--no-notify)
  [[ $AUTO_YES -eq 1 ]] && repair_cmd+=(--yes)
  [[ $DRY_RUN -eq 1 ]] && repair_cmd+=(--dry-run)
  exec "${repair_cmd[@]}"
fi

log_event --component setup --event start --message "Setup started" --kv "auth_mode=$AUTH_MODE" --kv "dry_run=$DRY_RUN"

step_start "Auth (password mode by default)"
run_password=0
if [[ "$AUTH_MODE" == "password" ]]; then
  NO_BOOTSTRAP=1
  FINALIZE_SKIP_EXTENSION_BOOTSTRAP=1
  if [[ $DRY_RUN -eq 1 ]]; then
    papercut_ui_note "Dry-run: skipping interactive password login."
  elif [[ -t 0 && -t 1 ]]; then
    run_password=1
  else
    papercut_ui_step_fail "--auth-mode=password requires an interactive terminal (or use --auth-mode extension)."
    exit $RC_CRITICAL
  fi
elif [[ "$AUTH_MODE" == "auto" && -t 0 && -t 1 && $DRY_RUN -eq 0 ]]; then
  run_password=1
fi

if [[ $run_password -eq 1 ]]; then
  papercut_ui_note "Authenticating with PaperCut account (password is never stored)."
  if password_login_bootstrap; then
    papercut_ui_step_ok "Password login succeeded (org-id=$ORG_ID)."
  elif [[ "$AUTH_MODE" == "password" ]]; then
    papercut_ui_step_fail "Password login failed and --auth-mode=password was requested."
    exit $RC_CRITICAL
  else
    papercut_ui_step_warn "Password login failed; continuing with extension/config/manual Org ID flow."
  fi
else
  papercut_ui_step_ok "Authentication stage complete (mode=$AUTH_MODE)."
fi

if [[ -z "$ORG_ID" ]]; then
  ORG_ID="$(detect_org_id)"
  if [[ -n "$ORG_ID" ]]; then
    papercut_ui_note "Detected Org ID automatically: $ORG_ID"
  fi
fi

if [[ -z "$ORG_ID" && -t 0 && -t 1 ]]; then
  echo "PaperCut Org ID not found automatically."
  echo "Paste either your Org ID or admin URL (example: https://hive.papercut.com/<ORG_ID>/...)."
  read -r -p "PaperCut Org ID or admin URL: " org_input
  if [[ -n "${org_input:-}" ]]; then
    parsed_org="$(parse_org_input "$org_input")"
    if [[ -n "$parsed_org" ]]; then
      ORG_ID="$parsed_org"
    else
      ORG_ID="$org_input"
    fi
  fi
  unset org_input parsed_org
fi

if [[ -z "$ORG_ID" ]]; then
  papercut_ui_step_fail "--org-id is required (not auto-detected and not provided interactively)."
  usage
  exit $RC_CRITICAL
fi

step_start "Preflight advisory"
detect_existing_printer_queue
queue_replace_confirmation

doctor_cmd=(
  "$BASE/scripts/papercut_doctor.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
  --allow-queue-recreate
)
[[ $AUTO_YES -eq 1 ]] && doctor_cmd+=(--yes)
[[ $DRY_RUN -eq 1 ]] && doctor_cmd+=(--dry-run)

if run_cmd_capture "${doctor_cmd[@]}"; then
  papercut_ui_step_ok "Doctor preflight completed without blockers."
  log_event --component setup --event doctor-preflight-ok --message "Doctor preflight succeeded" --kv "code=0"
else
  doctor_rc=$?
  case "$doctor_rc" in
    $RC_WARN)
      PREFLIGHT_WARNINGS=1
      papercut_ui_step_warn "Doctor returned warnings; setup continues in auto-repair mode."
      log_event --component setup --level warning --event doctor-preflight-warning --message "Doctor preflight warnings" --kv "code=$doctor_rc"
      ;;
    $RC_DEP_REFUSED|$RC_DEP_FAIL|$RC_CRITICAL)
      papercut_ui_step_fail "Doctor preflight blocked setup (code=$doctor_rc)."
      log_event --component setup --level error --event doctor-preflight-failed --message "Doctor preflight blocked setup" --kv "code=$doctor_rc"
      exit "$doctor_rc"
      ;;
    *)
      papercut_ui_step_fail "Doctor preflight failed with unexpected code=$doctor_rc."
      log_event --component setup --level error --event doctor-preflight-failed --message "Doctor preflight unexpected failure" --kv "code=$doctor_rc"
      exit "$RC_CRITICAL"
      ;;
  esac
fi

step_start "Install runtime"
install_cmd=(
  "$BASE/release/install.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
  --printer-name "$PRINTER_NAME"
)
if [[ $NO_BOOTSTRAP -eq 1 ]]; then
  install_cmd+=(--no-bootstrap-from-extension)
fi
install_cmd+=(--python-mode "$PYTHON_MODE")
[[ $ENABLE_NOTIFY -eq 0 ]] && install_cmd+=(--no-notify)
[[ -n "$PROFILE_DIR" ]] && install_cmd+=(--profile-dir "$PROFILE_DIR")
[[ $DRY_RUN -eq 1 ]] && install_cmd+=(--dry-run)

if run_cmd_capture "${install_cmd[@]}"; then
  papercut_ui_step_ok "Runtime install/repair completed."
  log_event --component setup --event install-complete --message "Install runtime stack completed"
else
  install_rc=$?
  papercut_ui_step_fail "Runtime install failed (code=$install_rc)."
  log_event --component setup --level error --event install-failed --message "Install runtime stack failed" --kv "code=$install_rc"
  exit $RC_CRITICAL
fi

step_start "Token bootstrap/sync"
if [[ -n "$BOOTSTRAP_JWT" ]]; then
  store_cmd=(
    "$BASE/scripts/papercut_secret_store.sh"
    --org-id "$ORG_ID"
    --cloud-host "$CLOUD_HOST"
    --linux-user "$LINUX_USER"
    --jwt-stdin
    --sync-now
  )
  if [[ $DRY_RUN -eq 1 ]]; then
    papercut_ui_note "Dry-run: skipping JWT keyring storage and sync."
    papercut_ui_step_ok "Token bootstrap stage completed (dry-run)."
  else
    if printf '%s\n' "$BOOTSTRAP_JWT" | "${store_cmd[@]}"; then
      papercut_ui_step_ok "JWT stored in keyring and synced to restricted token path."
    else
      JWT_STORE_FAILED=1
      NEEDS_MANUAL_FINALIZE=1
      papercut_ui_step_warn "Unable to store/sync JWT in this shell (likely keyring/DBus session constraints)."
    fi
  fi
  unset BOOTSTRAP_JWT
else
  if [[ $DRY_RUN -eq 1 ]]; then
    papercut_ui_note "Dry-run: token sync check skipped."
    papercut_ui_step_ok "Token sync stage completed (dry-run)."
  else
    sync_cmd=(
      "$BASE/scripts/papercut_secret_sync.sh"
      --org-id "$ORG_ID"
      --cloud-host "$CLOUD_HOST"
      --linux-user "$LINUX_USER"
      --auto-refresh-from-extension
      --verbose
    )
    if run_cmd_capture "${sync_cmd[@]}"; then
      papercut_ui_step_ok "Token sync completed."
    else
      NEEDS_MANUAL_FINALIZE=1
      papercut_ui_step_warn "Token sync is not complete yet in this shell; finalize step will provide manual recovery path."
    fi
  fi
fi

step_start "Finalize desktop session"
finalize_cmd=(
  "$BASE/release/finalize-session.sh"
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --linux-user "$LINUX_USER"
)
[[ $ENABLE_NOTIFY -eq 0 ]] && finalize_cmd+=(--no-notify)
[[ -n "$PROFILE_DIR" ]] && finalize_cmd+=(--profile-dir "$PROFILE_DIR")
[[ $FINALIZE_SKIP_EXTENSION_BOOTSTRAP -eq 1 ]] && finalize_cmd+=(--no-bootstrap-from-extension)

finalize_cmd_str="$(printf '%q ' "${finalize_cmd[@]}")"
finalize_cmd_str="${finalize_cmd_str% }"

if [[ $DRY_RUN -eq 1 ]]; then
  papercut_ui_note "Dry-run: finalize command not executed."
  papercut_ui_note "$finalize_cmd_str"
  papercut_ui_step_ok "Finalize stage complete (dry-run)."
else
  if [[ "$LINUX_USER" != "$USER" ]]; then
    NEEDS_MANUAL_FINALIZE=1
    papercut_ui_step_warn "Finalize skipped: run setup/finalize as target desktop user '$LINUX_USER'."
  elif [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    NEEDS_MANUAL_FINALIZE=1
    papercut_ui_step_warn "Finalize skipped: no desktop DBus session detected in this shell."
  elif ! id -Gn | tr ' ' '\n' | grep -Fxq "papercut-hive-users"; then
    NEEDS_MANUAL_FINALIZE=1
    papercut_ui_step_warn "Finalize skipped: current shell lacks active group 'papercut-hive-users'."
  elif run_cmd_capture "${finalize_cmd[@]}"; then
    papercut_ui_step_ok "Finalize completed in current desktop session."
  else
    NEEDS_MANUAL_FINALIZE=1
    papercut_ui_step_warn "Finalize did not complete in this shell; manual finalize is required."
  fi
fi

step_start "Verify + auto-repair"
if [[ $SKIP_VERIFY -eq 1 ]]; then
  papercut_ui_step_warn "Verification skipped by user request (--skip-verify)."
else
  verify_cmd=("$BASE/release/verify-print.sh" --printer-name "$PRINTER_NAME")
  if run_cmd_capture "${verify_cmd[@]}"; then
    papercut_ui_step_ok "Verification print path is healthy."
  else
    verify_first_rc=$?
    papercut_ui_step_warn "Initial verification failed (code=$verify_first_rc); running one auto-repair pass."

    repair_cmd=(
      "$BASE/scripts/papercut_repair.sh"
      --org-id "$ORG_ID"
      --cloud-host "$CLOUD_HOST"
      --linux-user "$LINUX_USER"
      --printer-name "$PRINTER_NAME"
    )
    [[ -n "$PROFILE_DIR" ]] && repair_cmd+=(--profile-dir "$PROFILE_DIR")
    [[ $ENABLE_NOTIFY -eq 0 ]] && repair_cmd+=(--no-notify)
    [[ $AUTO_YES -eq 1 ]] && repair_cmd+=(--yes)
    [[ $DRY_RUN -eq 1 ]] && repair_cmd+=(--dry-run)

    if run_cmd_capture "${repair_cmd[@]}"; then
      repair_rc=0
    else
      repair_rc=$?
      case "$repair_rc" in
        $RC_DEP_REFUSED|$RC_DEP_FAIL)
          papercut_ui_step_fail "Auto-repair blocked by dependency issue (code=$repair_rc)."
          exit "$repair_rc"
          ;;
        $RC_CRITICAL)
          papercut_ui_step_fail "Auto-repair reported critical blockers (code=$repair_rc)."
          exit "$RC_CRITICAL"
          ;;
        *)
          papercut_ui_step_warn "Auto-repair returned code=$repair_rc; continuing with one re-verify attempt."
          ;;
      esac
    fi

    if run_cmd_capture "${verify_cmd[@]}"; then
      VERIFY_REPAIRED=1
      papercut_ui_step_ok "Verification succeeded after auto-repair."
    else
      VERIFY_DEGRADED=1
      verify_second_rc=$?
      papercut_ui_step_warn "Verification still degraded after repair (code=$verify_second_rc)."
    fi
  fi
fi

print_manual_actions "$finalize_cmd_str"

if [[ $NEEDS_MANUAL_FINALIZE -eq 1 || $VERIFY_DEGRADED -eq 1 ]]; then
  log_event --component setup --level warning --event complete-manual-action --message "Setup completed with manual actions required"
  notify_user warning "Setup finished with warnings. Manual action is still required."
  papercut_ui_step_warn "Final status: WARN-action-required (exit=$RC_WARN)."
  exit $RC_WARN
fi

log_event --component setup --event complete --message "Setup completed successfully"
notify_user info "Setup complete. Printer ready: $PRINTER_NAME"
if [[ $VERIFY_REPAIRED -eq 1 || $PREFLIGHT_WARNINGS -eq 1 ]]; then
  papercut_ui_step_ok "Final status: OK (auto-repair and/or advisory warnings handled)."
else
  papercut_ui_step_ok "Final status: OK. Printer ready: $PRINTER_NAME"
fi

exit 0
