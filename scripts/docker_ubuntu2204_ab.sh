#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$BASE/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/docker-ubuntu2204-ab-$TS.txt"
CONTAINER="hive-ubuntu2204-ab-$TS"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
EXT_DIR="$BASE/tools/extensions/$EXT_ID/unpacked"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker_cmd=()
if docker ps >/dev/null 2>&1; then
  docker_cmd=(docker)
elif sudo -n docker ps >/dev/null 2>&1; then
  docker_cmd=(sudo docker)
else
  echo "Docker is not reachable from this shell." >&2
  echo "Use either: sg docker -c './scripts/docker_ubuntu2204_ab.sh' or configure docker group for this login session." >&2
  exit 1
fi

cleanup() {
  "${docker_cmd[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

{
  echo "=== Docker Ubuntu 22.04 A/B Runner ==="
  echo "timestamp_utc=$TS"
  echo "host_user=$(id -un)"
  echo "container_name=$CONTAINER"
  echo "base=$BASE"
  echo
} | tee "$OUT"

"${docker_cmd[@]}" pull ubuntu:22.04 >>"$OUT" 2>&1

"${docker_cmd[@]}" run -d --name "$CONTAINER" \
  --network bridge \
  --shm-size=1g \
  -v "$BASE:/workspace" \
  ubuntu:22.04 sleep infinity >>"$OUT" 2>&1

exec_in() {
  "${docker_cmd[@]}" exec "$CONTAINER" bash -lc "$1"
}

{
  echo "[Container OS]"
  exec_in "cat /etc/os-release | sed -n '1,8p'"
  echo
  echo "[Install prerequisites]"
  exec_in "export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null && apt-get install -y --no-install-recommends ca-certificates curl openssl dnsutils cups-daemon cups-client cups-ipp-utils wget xz-utils libatomic1 >/dev/null"
  echo "ok"
  echo
} >>"$OUT" 2>&1

{
  echo "[Path A in container - Chrome extension smoke]"
  exec_in "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends chromium-browser >/dev/null"
  exec_in "test -d /workspace/tools/extensions/$EXT_ID/unpacked"
  exec_in "mkdir -p /tmp/chromium-ud"
  exec_in "timeout 45s chromium-browser --headless=new --disable-gpu --no-sandbox --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-ud --disable-extensions-except=/workspace/tools/extensions/$EXT_ID/unpacked --load-extension=/workspace/tools/extensions/$EXT_ID/unpacked --dump-dom chrome-extension://$EXT_ID/manifest.json >/workspace/outputs/pathA-docker-dom-$TS.txt 2>/workspace/outputs/pathA-docker-stderr-$TS.txt || true"
  exec_in "echo '[Service worker hints]' && grep -E 'starting printprovider|\\[linking\\]|auth-token|userJwt|PMITC Printer\\(Chrome\\)|ERR_BLOCKED_BY_CLIENT|blocked by Chromium' /workspace/outputs/pathA-docker-stderr-$TS.txt /workspace/outputs/pathA-docker-dom-$TS.txt || true"
  exec_in "chown $HOST_UID:$HOST_GID /workspace/outputs/pathA-docker-dom-$TS.txt /workspace/outputs/pathA-docker-stderr-$TS.txt 2>/dev/null || true"
  echo
} >>"$OUT" 2>&1

{
  echo "[Path B in container - Local CUPS lab]"
  exec_in "mkdir -p /tmp/cups-lab/{etc,logs,run,cache,spool,tmp}" || true
  exec_in "cat >/tmp/cups-lab/etc/cupsd.conf <<'CFG'
ServerRoot /tmp/cups-lab/etc
Listen 127.0.0.1:8631
Browsing Off
WebInterface No
DefaultAuthType None
LogLevel debug
IdleExitTimeout 0

<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  Order allow,deny
  Allow all
</Location>
CFG"
  exec_in "cat >/tmp/cups-lab/etc/cups-files.conf <<'CFG'
SystemGroup root
FileDevice Yes
AccessLog /tmp/cups-lab/logs/access_log
ErrorLog /tmp/cups-lab/logs/error_log
PageLog /tmp/cups-lab/logs/page_log
RequestRoot /tmp/cups-lab/spool
ServerRoot /tmp/cups-lab/etc
StateDir /tmp/cups-lab/run
CacheDir /tmp/cups-lab/cache
TempDir /tmp/cups-lab/tmp
User lp
Group lp
CFG"
  exec_in "cupsd -f -c /tmp/cups-lab/etc/cupsd.conf >/tmp/cups-lab/logs/cupsd-stdout.log 2>&1 & echo \$! >/tmp/cups-lab/cupsd.pid; sleep 1; pgrep -x cupsd || true" || true
  exec_in "sleep 1; lpstat -h 127.0.0.1:8631 -r" || true
  exec_in "lpadmin -h 127.0.0.1:8631 -x hive_file_test 2>/dev/null || true" || true
  exec_in "lpadmin -h 127.0.0.1:8631 -p hive_file_test -E -v file:/tmp/cups-lab/printed.out -m raw" || true
  exec_in "echo 'PaperCut Hive docker CUPS test page' >/tmp/cups-lab/test-page.txt" || true
  exec_in "lp -h 127.0.0.1:8631 -d hive_file_test /tmp/cups-lab/test-page.txt >/tmp/cups-lab/lp-submit.txt 2>&1 || true" || true
  exec_in "sleep 1" || true
  exec_in "echo '[Queue]'; lpstat -h 127.0.0.1:8631 -v || true" || true
  exec_in "echo '[Jobs]'; lpstat -h 127.0.0.1:8631 -W all || true" || true
  exec_in "echo '[Submit]'; cat /tmp/cups-lab/lp-submit.txt || true" || true
  exec_in "echo '[Page log]'; tail -n 5 /tmp/cups-lab/logs/page_log || true" || true
  exec_in "echo '[CUPS startup log]'; tail -n 30 /tmp/cups-lab/logs/cupsd-stdout.log || true" || true
  exec_in "echo '[Completion evidence]'; grep -E 'Job completed|Queued on|Send-Document' /tmp/cups-lab/logs/error_log | tail -n 20 || true" || true
  exec_in "cp /tmp/cups-lab/logs/error_log /workspace/outputs/pathB-docker-errorlog-$TS.txt 2>/dev/null || true" || true
  exec_in "cp /tmp/cups-lab/logs/page_log /workspace/outputs/pathB-docker-pagelog-$TS.txt 2>/dev/null || true" || true
  exec_in "cp /tmp/cups-lab/logs/cupsd-stdout.log /workspace/outputs/pathB-docker-cupsd-$TS.txt 2>/dev/null || true" || true
  exec_in "chown $HOST_UID:$HOST_GID /workspace/outputs/pathB-docker-errorlog-$TS.txt /workspace/outputs/pathB-docker-pagelog-$TS.txt /workspace/outputs/pathB-docker-cupsd-$TS.txt 2>/dev/null || true" || true
  echo
} >>"$OUT" 2>&1

{
  echo "[Network probe in container]"
  exec_in "/workspace/scripts/probe_hive_network.sh eu >/workspace/outputs/network-probe-eu-docker-$TS.txt 2>&1 || true"
  exec_in "tail -n 30 /workspace/outputs/network-probe-eu-docker-$TS.txt || true"
  exec_in "chown $HOST_UID:$HOST_GID /workspace/outputs/network-probe-eu-docker-$TS.txt 2>/dev/null || true"
  echo
  echo "Artifacts:"
  echo "- $OUT"
  echo "- $OUT_DIR/pathA-docker-stderr-$TS.txt"
  echo "- $OUT_DIR/pathA-docker-dom-$TS.txt"
  echo "- $OUT_DIR/pathB-docker-errorlog-$TS.txt"
  echo "- $OUT_DIR/pathB-docker-pagelog-$TS.txt"
  echo "- $OUT_DIR/pathB-docker-cupsd-$TS.txt"
  echo "- $OUT_DIR/network-probe-eu-docker-$TS.txt"
} | tee -a "$OUT"
