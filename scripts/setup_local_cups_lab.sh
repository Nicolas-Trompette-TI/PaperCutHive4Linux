#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DL="$BASE/tools/downloads"
CROOT="$BASE/tools/cups-local/root"
LAB="$BASE/tools/cups-local/lab"
mkdir -p "$DL" "$CROOT" "$LAB"/{etc,var/run,var/log,var/spool,var/cache,var/lib,tmp}

cd "$DL"
for p in cups-client cups-daemon cups-common cups-ipp-utils libpaper1; do
  apt-get download "$p" >/dev/null
  echo "downloaded $p"
done

extract_deb() {
  local deb="$1" target="$2"
  local tmp
  tmp="$(mktemp -d)"
  (cd "$tmp" && ar x "$deb" && { [ -f data.tar.xz ] && tar -xf data.tar.xz || true; } && { [ -f data.tar.zst ] && tar --zstd -xf data.tar.zst || true; } && { [ -f data.tar.gz ] && tar -xzf data.tar.gz || true; })
  cp -a "$tmp"/* "$target/" 2>/dev/null || true
  rm -rf "$tmp"
}

for deb in "$DL"/cups-client_*_amd64.deb "$DL"/cups-daemon_*_amd64.deb "$DL"/cups-common_*_all.deb "$DL"/cups-ipp-utils_*_amd64.deb "$DL"/libpaper1_*_amd64.deb; do
  [ -f "$deb" ] || continue
  extract_deb "$deb" "$CROOT"
done

cat > "$LAB/etc/cupsd.conf" <<CFG
ServerRoot $LAB/etc
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
CFG

cat > "$LAB/etc/cups-files.conf" <<CFG
SystemGroup nicolas
FileDevice Yes
AccessLog $LAB/var/log/access_log
ErrorLog $LAB/var/log/error_log
PageLog $LAB/var/log/page_log
RequestRoot $LAB/var/spool
ServerBin $CROOT/usr/lib/cups
ServerRoot $LAB/etc
StateDir $LAB/var/run
CacheDir $LAB/var/cache
DataDir $CROOT/usr/share/cups
TempDir $LAB/tmp
User nicolas
Group nicolas
CFG

LD_PATH="$CROOT/usr/lib/x86_64-linux-gnu:$CROOT/lib/x86_64-linux-gnu:$CROOT/usr/lib:$CROOT/lib"

if [ -f "$LAB/cupsd.pid" ]; then kill "$(cat "$LAB/cupsd.pid")" 2>/dev/null || true; fi
pkill -f '^.*/tools/cups-local/root/usr/sbin/cupsd.*cupsd.conf' || true
sleep 1
LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/sbin/cupsd" -c "$LAB/etc/cupsd.conf"
sleep 1
NEWPID="$(pgrep -f '^.*/tools/cups-local/root/usr/sbin/cupsd.*cupsd.conf' | head -n1)"
echo "$NEWPID" > "$LAB/cupsd.pid"

LD_LIBRARY_PATH="$LD_PATH" "$CROOT/usr/bin/lpstat" -h 127.0.0.1:8631 -r
echo "CUPS lab ready (pid=$NEWPID)"
