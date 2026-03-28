#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PKG_NAME="papercut-hive-driver"
VERSION=""
ARCH="$(dpkg --print-architecture)"
OUT_DIR="$BASE/dist"
MAINTAINER="PaperCut Hive Driver Team <support@example.com>"

usage() {
  cat <<USAGE
Usage: $0 [options]

Build a production .deb package for PaperCut Hive Driver.

Options:
  --version <x.y.z>       package version (default: 0.1.0+YYYYMMDDHHMM)
  --arch <arch>           default: host dpkg architecture
  --output-dir <dir>      default: ./dist
  --maintainer <string>   default: PaperCut Hive Driver Team <support@example.com>
  -h, --help              show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --output-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --maintainer) MAINTAINER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="0.1.0+$(date -u +%Y%m%d%H%M)"
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found. Install dpkg-dev/dpkg." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
PKG_ROOT="$WORK_DIR/${PKG_NAME}_${VERSION}_${ARCH}"
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/usr/lib/$PKG_NAME"
mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/usr/share/doc/$PKG_NAME"

cp -a "$BASE/setup.sh" "$PKG_ROOT/usr/lib/$PKG_NAME/setup.sh"
cp -a "$BASE/release" "$PKG_ROOT/usr/lib/$PKG_NAME/release"
cp -a "$BASE/scripts" "$PKG_ROOT/usr/lib/$PKG_NAME/scripts"
cp -a "$BASE/README.md" "$PKG_ROOT/usr/share/doc/$PKG_NAME/README.md"

cat >"$PKG_ROOT/usr/bin/papercut-hive-setup" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/papercut-hive-driver/setup.sh "$@"
WRAP

cat >"$PKG_ROOT/usr/bin/papercut-hive-doctor" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/papercut-hive-driver/setup.sh --doctor "$@"
WRAP

cat >"$PKG_ROOT/usr/bin/papercut-hive-repair" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/papercut-hive-driver/setup.sh --repair "$@"
WRAP

chmod 755 \
  "$PKG_ROOT/usr/bin/papercut-hive-setup" \
  "$PKG_ROOT/usr/bin/papercut-hive-doctor" \
  "$PKG_ROOT/usr/bin/papercut-hive-repair"

cat >"$PKG_ROOT/DEBIAN/control" <<CONTROL
Package: $PKG_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: bash, coreutils, sed, grep, findutils, sudo, systemd, python3, python3-requests, python3-venv, cups, cups-client, cups-filters, file, libsecret-tools, dbus-user-session, gnome-keyring, libnotify-bin
Description: PaperCut Hive Driver for Ubuntu
 Production-friendly installer and runtime scripts to print from Linux apps
 to PaperCut Hive with secure token sync, health checks and repair mode.
CONTROL

cat >"$PKG_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/usr/bin/env bash
set -euo pipefail
chmod 755 /usr/lib/papercut-hive-driver/setup.sh || true
chmod -R a+rX /usr/lib/papercut-hive-driver/release /usr/lib/papercut-hive-driver/scripts || true
exit 0
POSTINST

cat >"$PKG_ROOT/DEBIAN/prerm" <<'PRERM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "remove" || "${1:-}" == "upgrade" ]]; then
  if command -v lpadmin >/dev/null 2>&1; then
    lpadmin -x PaperCut-Hive-TIF 2>/dev/null || true
  fi
fi
exit 0
PRERM

cat >"$PKG_ROOT/DEBIAN/postrm" <<'POSTRM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "purge" ]]; then
  rm -rf /etc/papercut-hive-lite /var/lib/papercut-hive-lite || true
  rm -rf /usr/local/lib/papercut-hive-lite || true
  rm -f /usr/lib/cups/backend/papercut-hive-lite || true
fi
exit 0
POSTRM

chmod 755 "$PKG_ROOT/DEBIAN/postinst" "$PKG_ROOT/DEBIAN/prerm" "$PKG_ROOT/DEBIAN/postrm"

mkdir -p "$OUT_DIR"
DEB_PATH="$OUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build "$PKG_ROOT" "$DEB_PATH" >/dev/null

echo "Built package: $DEB_PATH"
