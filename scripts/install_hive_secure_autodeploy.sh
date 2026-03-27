#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"

LINUX_USER="${USER}"
ORG_ID=""
CLOUD_HOST="eu.hive.papercut.com"
PRINTER_NAME="PaperCut-Hive-Lite"
ENABLE_BACKEND_DRY_RUN=0
BOOTSTRAP_FROM_EXTENSION=0
PROFILE_DIR=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> [options]

Automated production-style deployment:
1) Installs CUPS PaperCut backend queue
2) Installs OS keyring tooling (libsecret)
3) Installs restricted root helper for token sync
4) Installs sudoers rule limited to helper command
5) Installs systemd --user service+timer for auto-sync after reboot/login

Options:
  --org-id <ORG_ID>             required
  --cloud-host <host>           default: eu.hive.papercut.com
  --linux-user <user>           default: current user
  --printer-name <name>         default: PaperCut-Hive-Lite
  --enable-backend-dry-run      set backend to offline dry-run mode
  --bootstrap-from-extension    extract JWT from extension and store in keyring
  --profile-dir <dir>           browser profile dir for bootstrap extraction
  --dry-run                     print actions without applying
  -h, --help                    show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id) ORG_ID="${2:-}"; shift 2 ;;
    --cloud-host) CLOUD_HOST="${2:-}"; shift 2 ;;
    --linux-user) LINUX_USER="${2:-}"; shift 2 ;;
    --printer-name) PRINTER_NAME="${2:-}"; shift 2 ;;
    --enable-backend-dry-run) ENABLE_BACKEND_DRY_RUN=1; shift ;;
    --bootstrap-from-extension) BOOTSTRAP_FROM_EXTENSION=1; shift ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$ORG_ID" ]]; then
  echo "--org-id is required." >&2
  usage
  exit 1
fi

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

echo "[1/6] Install CUPS backend queue"
backend_args=(
  --org-id "$ORG_ID"
  --cloud-host "$CLOUD_HOST"
  --printer-name "$PRINTER_NAME"
)
if [[ $ENABLE_BACKEND_DRY_RUN -eq 1 ]]; then
  backend_args+=(--enable-backend-dry-run)
fi
if [[ $DRY_RUN -eq 1 ]]; then
  backend_args+=(--dry-run)
fi
"$BASE/scripts/install_hive_cups_backend.sh" "${backend_args[@]}"

echo "[2/6] Install keyring tooling"
run "sudo apt-get update -y"
run "sudo apt-get install -y libsecret-tools dbus-user-session gnome-keyring"

echo "[3/6] Install restricted root helper"
run "sudo install -D -m 755 '$BASE/scripts/papercut_hive_token_sync_root.sh' /usr/local/sbin/papercut-hive-token-sync"

echo "[4/6] Install scoped sudoers rule"
run "sudo groupadd -f papercut-hive-users"
run "sudo usermod -aG papercut-hive-users '$LINUX_USER'"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] write /etc/sudoers.d/91-papercut-hive-token-sync"
else
  cat <<'EOF' | sudo tee /etc/sudoers.d/91-papercut-hive-token-sync >/dev/null
Cmnd_Alias PAPERCUT_TOKEN_SYNC = /usr/local/sbin/papercut-hive-token-sync --linux-user * --stdin
%papercut-hive-users ALL=(root) NOPASSWD: PAPERCUT_TOKEN_SYNC
EOF
  sudo chmod 440 /etc/sudoers.d/91-papercut-hive-token-sync
  sudo /usr/sbin/visudo -cf /etc/sudoers.d/91-papercut-hive-token-sync
fi

echo "[5/6] Install user auto-sync service/timer"
USER_HOME="$(getent passwd "$LINUX_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" ]]; then
  echo "Could not resolve home for user: $LINUX_USER" >&2
  exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] install systemd --user unit files under $USER_HOME/.config/systemd/user"
else
  sudo -u "$LINUX_USER" mkdir -p "$USER_HOME/.config/papercut-hive-lite" "$USER_HOME/.config/systemd/user"
  cat <<EOF | sudo -u "$LINUX_USER" tee "$USER_HOME/.config/papercut-hive-lite/secret-sync.env" >/dev/null
PAPERCUT_ORG_ID="$ORG_ID"
PAPERCUT_CLOUD_HOST="$CLOUD_HOST"
EOF
  chmod 600 "$USER_HOME/.config/papercut-hive-lite/secret-sync.env"

  cat <<EOF | sudo -u "$LINUX_USER" tee "$USER_HOME/.config/systemd/user/papercut-hive-token-sync.service" >/dev/null
[Unit]
Description=Sync PaperCut Hive JWT from OS keyring to CUPS backend
After=default.target

[Service]
Type=oneshot
EnvironmentFile=%h/.config/papercut-hive-lite/secret-sync.env
ExecStart=/bin/bash -lc '$BASE/scripts/papercut_secret_sync.sh --linux-user %u --org-id "\${PAPERCUT_ORG_ID}" --cloud-host "\${PAPERCUT_CLOUD_HOST}" --verbose'
EOF

  cat <<'EOF' | sudo -u "$LINUX_USER" tee "$USER_HOME/.config/systemd/user/papercut-hive-token-sync.timer" >/dev/null
[Unit]
Description=Periodic PaperCut Hive JWT sync

[Timer]
OnBootSec=45s
OnUnitActiveSec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  if ! sudo -u "$LINUX_USER" systemctl --user daemon-reload; then
    echo "Warning: unable to reload systemd --user in this shell (likely no user DBus session)." >&2
  fi
  if ! sudo -u "$LINUX_USER" systemctl --user enable --now papercut-hive-token-sync.timer; then
    echo "Warning: unable to enable timer now; run manually in user session:" >&2
    echo "  systemctl --user daemon-reload" >&2
    echo "  systemctl --user enable --now papercut-hive-token-sync.timer" >&2
  fi
fi

echo "[6/6] Optional bootstrap (extension -> keyring -> CUPS token)"
if [[ $BOOTSTRAP_FROM_EXTENSION -eq 1 ]]; then
  bootstrap_cmd=( "$BASE/scripts/papercut_secret_store.sh" --linux-user "$LINUX_USER" --org-id "$ORG_ID" --cloud-host "$CLOUD_HOST" --from-extension --sync-now )
  if [[ -n "$PROFILE_DIR" ]]; then
    bootstrap_cmd+=(--profile-dir "$PROFILE_DIR")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    bootstrap_cmd+=(--dry-run)
  fi

  if [[ "$USER" == "$LINUX_USER" ]]; then
    if ! "${bootstrap_cmd[@]}"; then
      echo "Warning: bootstrap to OS keyring failed in current shell." >&2
      echo "Run later in a logged-in desktop session:" >&2
      printf '  %q ' "${bootstrap_cmd[@]}"
      echo >&2
    fi
  else
    echo "Bootstrap skipped automatically because current shell user != target linux user."
    echo "Run manually as $LINUX_USER:"
    printf '  %q ' "${bootstrap_cmd[@]}"
    echo
  fi
fi

echo
echo "Deployment complete."
echo "Important:"
echo "1) Open a new login session so new group membership is active."
echo "2) If needed, run manually:"
echo "   systemctl --user daemon-reload"
echo "   systemctl --user enable --now papercut-hive-token-sync.timer"
