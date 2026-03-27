#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DL="$BASE/tools/downloads"
CH_ROOT="$BASE/tools/chromium-local"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
EXT_DIR="$BASE/tools/extensions/$EXT_ID"
mkdir -p "$DL" "$CH_ROOT" "$EXT_DIR"

# Download chromium packages (no root install)
cd "$DL"
for p in chromium chromium-common; do
  apt-get download "$p" >/dev/null
  echo "downloaded $p"
done

# Extract into local rootfs
rm -rf "$CH_ROOT/extracted" "$CH_ROOT/sysroot"
mkdir -p "$CH_ROOT/extracted" "$CH_ROOT/sysroot"

extract_deb() {
  local deb="$1" target="$2"
  local tmp
  tmp="$(mktemp -d)"
  (cd "$tmp" && ar x "$deb" && { [ -f data.tar.xz ] && tar -xf data.tar.xz || true; } && { [ -f data.tar.zst ] && tar --zstd -xf data.tar.zst || true; } && { [ -f data.tar.gz ] && tar -xzf data.tar.gz || true; })
  cp -a "$tmp"/* "$target/" 2>/dev/null || true
  rm -rf "$tmp"
}

CHROMIUM_DEB="$(ls -1t "$DL"/chromium_*_amd64.deb | head -n1)"
CHROMIUM_COMMON_DEB="$(ls -1t "$DL"/chromium-common_*_amd64.deb | head -n1)"
extract_deb "$CHROMIUM_DEB" "$CH_ROOT/extracted"
extract_deb "$CHROMIUM_COMMON_DEB" "$CH_ROOT/extracted"

# Download local runtime libs used by chromium binary
for p in libjsoncpp24 libdouble-conversion3 libevent-2.1-7 libwebpdemux2 libxnvctrl0 libminizip1 libxslt1.1 libwoff1; do
  apt-get download "$p" >/dev/null
  echo "downloaded $p"
done
for deb in "$DL"/libjsoncpp24_*_amd64.deb "$DL"/libdouble-conversion3_*_amd64.deb "$DL"/libevent-2.1-7_*_amd64.deb "$DL"/libwebpdemux2_*_amd64.deb "$DL"/libxnvctrl0_*_amd64.deb "$DL"/libminizip1_*_amd64.deb "$DL"/libxslt1.1_*_amd64.deb "$DL"/libwoff1_*_amd64.deb; do
  [ -f "$deb" ] || continue
  extract_deb "$deb" "$CH_ROOT/sysroot"
done

# Download and unpack Hive Chrome extension
CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=146.0.7680.164&acceptformat=crx2,crx3&x=id%3D${EXT_ID}%26uc"
mkdir -p "$EXT_DIR"
curl -fL --retry 3 -o "$EXT_DIR/extension.crx" "$CRX_URL"

EXT_DIR="$EXT_DIR" python3 - << 'PY'
import os, pathlib, struct, zipfile
base = pathlib.Path(os.environ["EXT_DIR"])
crx = (base / "extension.crx").read_bytes()
if crx[:4] != b"Cr24":
    raise SystemExit("Not a CRX file")
ver = struct.unpack("<I", crx[4:8])[0]
if ver == 2:
    pub_len = struct.unpack("<I", crx[8:12])[0]
    sig_len = struct.unpack("<I", crx[12:16])[0]
    off = 16 + pub_len + sig_len
elif ver == 3:
    header_len = struct.unpack("<I", crx[8:12])[0]
    off = 12 + header_len
else:
    raise SystemExit(f"Unsupported CRX version: {ver}")
zip_path = base / "extension.zip"
zip_path.write_bytes(crx[off:])
out = base / "unpacked"
if out.exists():
    import shutil
    shutil.rmtree(out)
out.mkdir()
zipfile.ZipFile(zip_path).extractall(out)
print("crx_version", ver)
PY

BIN_DIR="$CH_ROOT/extracted/usr/lib/chromium"
BIN="$BIN_DIR/chromium"
LD_PATH="$BIN_DIR:$CH_ROOT/sysroot/lib/x86_64-linux-gnu:$CH_ROOT/sysroot/usr/lib/x86_64-linux-gnu:$CH_ROOT/sysroot/usr/lib:$CH_ROOT/sysroot/lib"

LD_LIBRARY_PATH="$LD_PATH" "$BIN" --version
echo "Setup complete"
