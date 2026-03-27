#!/usr/bin/env bash
set -euo pipefail

EXT_ID="pdlopiakikhioinbeibaachakgdgllff"
UPDATE_URL="https://clients2.google.com/service/update2/crx"
ORG_ID=""
REGION_CODE=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 --org-id <ORG_ID> --region-code <REGION_CODE> [--dry-run]

This installs managed browser policies for Chromium/Chrome to:
1) force-install PaperCut Hive extension
2) preconfigure Organization.Id + Organization.RegionCode

Policy files written:
- /etc/chromium/policies/managed/papercut-hive-lite.json
- /etc/opt/chrome/policies/managed/papercut-hive-lite.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-id)
      ORG_ID="${2:-}"
      shift 2
      ;;
    --region-code)
      REGION_CODE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
 done

if [[ -z "$ORG_ID" || -z "$REGION_CODE" ]]; then
  echo "--org-id and --region-code are required" >&2
  usage
  exit 1
fi

POLICY_JSON=$(cat <<EOF
{
  "ExtensionInstallForcelist": [
    "${EXT_ID};${UPDATE_URL}"
  ],
  "3rdparty": {
    "extensions": {
      "${EXT_ID}": {
        "Organization": {
          "Id": "${ORG_ID}",
          "RegionCode": "${REGION_CODE}"
        }
      }
    }
  }
}
EOF
)

write_policy() {
  local dir="$1"
  local file="$dir/papercut-hive-lite.json"
  echo "[policy] target=$file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  sudo mkdir -p "$dir"
  printf '%s\n' "$POLICY_JSON" | sudo tee "$file" >/dev/null
  sudo chmod 644 "$file"
}

write_policy "/etc/chromium/policies/managed"
write_policy "/etc/opt/chrome/policies/managed"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "--- DRY RUN policy content ---"
  echo "$POLICY_JSON"
fi

echo
echo "Done."
echo "Next:"
echo "1) Restart Chromium/Chrome sessions."
echo "2) Verify policy at chrome://policy or chromium://policy."
echo "3) Verify extension appears with version 2.4.1+ and links to your org."
