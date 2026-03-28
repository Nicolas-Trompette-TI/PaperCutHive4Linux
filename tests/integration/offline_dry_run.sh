#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT
printf 'papercut-ci-test\n' >"$TMP_FILE"

cd "$BASE"

echo "[ci] shell syntax"
bash -n setup.sh release/*.sh scripts/*.sh packaging/build_deb.sh

echo "[ci] python syntax"
python3 -m py_compile scripts/papercut_submit_job.py

echo "[ci] submit offline dry-run"
python3 scripts/papercut_submit_job.py \
  --offline-dry-run \
  --cloud-host eu.hive.papercut.com \
  --org-id 10196b04 \
  --file "$TMP_FILE" \
  --title "ci-offline" \
  >/dev/null

echo "[ci] doctor dry-run"
set +e
./scripts/papercut_doctor.sh --org-id 10196b04 --dry-run --yes >/dev/null
rc_doctor=$?
set -e
if [[ "$rc_doctor" -ne 0 && "$rc_doctor" -ne 2 ]]; then
  echo "doctor dry-run returned unexpected code: $rc_doctor" >&2
  exit 1
fi

echo "[ci] setup dry-run"
./setup.sh --org-id 10196b04 --dry-run --yes --skip-verify --no-bootstrap-from-extension --no-notify >/dev/null

echo "[ci] setup doctor mode dry-run"
set +e
./setup.sh --doctor --org-id 10196b04 --dry-run --yes --no-notify >/dev/null
rc_setup_doctor=$?
set -e
if [[ "$rc_setup_doctor" -ne 0 && "$rc_setup_doctor" -ne 2 ]]; then
  echo "setup --doctor dry-run returned unexpected code: $rc_setup_doctor" >&2
  exit 1
fi

echo "[ci] setup repair mode dry-run"
set +e
./setup.sh --repair --org-id 10196b04 --dry-run --yes --no-notify >/dev/null
rc_setup_repair=$?
set -e
if [[ "$rc_setup_repair" -ne 0 && "$rc_setup_repair" -ne 2 ]]; then
  echo "setup --repair dry-run returned unexpected code: $rc_setup_repair" >&2
  exit 1
fi

echo "[ci] build deb"
./packaging/build_deb.sh --version 0.0.0-ci --output-dir ./dist >/dev/null

if ! ls ./dist/papercut-hive-driver_0.0.0-ci_*.deb >/dev/null 2>&1; then
  echo "deb package artifact missing" >&2
  exit 1
fi

echo "[ci] offline dry-run suite OK"
