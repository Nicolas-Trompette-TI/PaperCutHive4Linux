#!/usr/bin/env bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
EXT_ID="pdlopiakikhioinbeibaachakgdgllff"

PROFILE_DIR=""
FROM_INPUT=""
JWT_INPUT=""
JWT_FROM_STDIN=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: $0 [options]

Detects PaperCut Org ID from one of these sources:
1) --from-input <value> (direct Org ID or admin URL)
2) --jwt-stdin (extract from JWT payload claims read from stdin)
3) /etc/papercut-hive-lite/config.env (PAPERCUT_ORG_ID)
4) Browser extension sync storage (PaperCut Hive extension)

Options:
  --from-input <value>      Org ID value or admin URL to parse
  --jwt-stdin               read JWT from stdin and inspect claims
  --profile-dir <dir>       browser profile root for extension lookup
  --verbose                 print detection source to stderr
  -h, --help                show help
EOF
}

log() {
  [[ $VERBOSE -eq 1 ]] || return 0
  echo "[org-detect] $*" >&2
}

normalize_input_to_org() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import re
import sys
import urllib.parse

raw = (sys.argv[1] or "").strip()
if not raw:
    raise SystemExit(1)

valid = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$")
if valid.fullmatch(raw):
    print(raw)
    raise SystemExit(0)

if not re.match(r"^https?://", raw, re.I):
    raise SystemExit(1)

parsed = urllib.parse.urlparse(raw)
host = (parsed.netloc or "").lower()
parts = [urllib.parse.unquote(p).strip() for p in parsed.path.split("/") if p.strip()]

blocked = {
    "admin",
    "portal",
    "login",
    "app",
    "settings",
    "billing",
    "subscription",
    "dashboard",
}

if ("hive.papercut." in host or "pocket.papercut." in host) and parts:
    candidate = parts[0]
    if valid.fullmatch(candidate) and candidate.lower() not in blocked:
        print(candidate)
        raise SystemExit(0)

for part in parts:
    if valid.fullmatch(part) and part.lower() not in blocked:
        print(part)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

extract_org_from_jwt() {
  local jwt="$1"
  python3 - 3<<<"$jwt" <<'PY'
import base64
import json
import os
import re
import sys

with os.fdopen(3, "r", encoding="utf-8", errors="replace") as stream:
    jwt = (stream.read() or "").strip()
if not jwt:
    raise SystemExit(1)

parts = jwt.split(".")
if len(parts) != 3:
    raise SystemExit(1)

try:
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload))
except Exception:
    raise SystemExit(1)

valid = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$")
blocked = {
    "admin",
    "portal",
    "login",
    "app",
    "settings",
    "billing",
    "subscription",
    "dashboard",
}
org_keys = {"orgid", "organizationid", "tenantid"}
url_hint = re.compile(r"/(?:org|organization|tenant)s?/([A-Za-z0-9._-]{4,128})", re.I)
candidates = []

def maybe_add(value):
    s = str(value).strip()
    if not s:
        return
    if valid.fullmatch(s) and s.lower() not in blocked:
        candidates.append(s)

def walk(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            nk = re.sub(r"[^a-z0-9]", "", str(k).lower())
            if nk in org_keys and isinstance(v, (str, int, float)):
                maybe_add(v)
            if isinstance(v, str):
                for m in url_hint.findall(v):
                    maybe_add(m)
            walk(v)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

walk(data)

if not candidates:
    raise SystemExit(1)

unique = []
for c in candidates:
    if c not in unique:
        unique.append(c)

print(max(unique, key=len))
PY
}

resolve_config_value() {
  local key="$1"
  local cfg="/etc/papercut-hive-lite/config.env"
  [[ -r "$cfg" ]] || return 0
  sed -n "s/^${key}=\"\(.*\)\"/\1/p" "$cfg" | head -n1
}

extract_org_from_extension() {
  local profile="$1"
  local -a scan_dirs=()
  local -a roots=()

  add_scan_dirs_from_root() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    while IFS= read -r found; do
      [[ -n "$found" ]] && scan_dirs+=("$found")
    done < <(find "$root" -maxdepth 4 -type d -path "*/Sync Extension Settings/$EXT_ID" 2>/dev/null | sort)
  }

  if [[ -z "$profile" ]]; then
    roots=(
      "$HOME/.config/google-chrome"
      "$HOME/.config/chromium"
      "$BASE/tools/chromium-user-data-auth"
    )
    for candidate in "${roots[@]}"; do
      add_scan_dirs_from_root "$candidate"
    done
  else
    roots=("$profile")
    if [[ -d "$profile/Sync Extension Settings/$EXT_ID" ]]; then
      scan_dirs+=("$profile/Sync Extension Settings/$EXT_ID")
    fi
    if [[ -d "$profile/Default/Sync Extension Settings/$EXT_ID" ]]; then
      scan_dirs+=("$profile/Default/Sync Extension Settings/$EXT_ID")
    fi
    add_scan_dirs_from_root "$profile"
  fi

  [[ ${#scan_dirs[@]} -gt 0 ]] || return 1

  python3 - "${scan_dirs[@]}" <<'PY'
import base64
import json
import pathlib
import re
import sys

scan_dirs = [pathlib.Path(p) for p in sys.argv[1:] if p]
jwt_re = re.compile(r"eyJ[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+\.[0-9A-Za-z_-]+")
valid = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$")
blocked = {
    "admin",
    "portal",
    "login",
    "app",
    "settings",
    "billing",
    "subscription",
    "dashboard",
}
org_keys = {"orgid", "organizationid", "tenantid"}
url_hint = re.compile(r"/(?:org|organization|tenant)s?/([A-Za-z0-9._-]{4,128})", re.I)

def maybe_add(out, value):
    s = str(value).strip()
    if not s:
        return
    if valid.fullmatch(s) and s.lower() not in blocked:
        out.append(s)

def decode_payload(token):
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None

def collect_orgs(data):
    out = []
    def walk(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                nk = re.sub(r"[^a-z0-9]", "", str(k).lower())
                if nk in org_keys and isinstance(v, (str, int, float)):
                    maybe_add(out, v)
                if isinstance(v, str):
                    for m in url_hint.findall(v):
                        maybe_add(out, m)
                walk(v)
        elif isinstance(obj, list):
            for item in obj:
                walk(item)
    walk(data)
    return out

seen = []
for scan_dir in scan_dirs:
    if not scan_dir.is_dir():
        continue
    for path in sorted(scan_dir.glob("*"), key=lambda p: p.stat().st_mtime, reverse=True):
        if path.name == "LOCK" or not path.is_file():
            continue
        try:
            text = path.read_bytes().decode("latin1", "ignore")
        except Exception:
            continue
        for token in jwt_re.findall(text):
            payload = decode_payload(token)
            if not payload:
                continue
            for org in collect_orgs(payload):
                if org not in seen:
                    seen.append(org)

if not seen:
    raise SystemExit(1)

print(max(seen, key=len))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-input) FROM_INPUT="${2:-}"; shift 2 ;;
    --jwt-stdin) JWT_FROM_STDIN=1; shift ;;
    --profile-dir) PROFILE_DIR="${2:-}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $JWT_FROM_STDIN -eq 1 ]]; then
  IFS= read -r JWT_INPUT || true
fi

if [[ -n "$FROM_INPUT" ]]; then
  if org="$(normalize_input_to_org "$FROM_INPUT" || true)" && [[ -n "$org" ]]; then
    log "source=input"
    printf '%s\n' "$org"
    exit 0
  fi
fi

if [[ -n "$JWT_INPUT" ]]; then
  if org="$(extract_org_from_jwt "$JWT_INPUT" || true)" && [[ -n "$org" ]]; then
    log "source=jwt"
    printf '%s\n' "$org"
    exit 0
  fi
fi
unset JWT_INPUT

cfg_org="$(resolve_config_value PAPERCUT_ORG_ID)"
if [[ -n "$cfg_org" ]]; then
  log "source=config"
  printf '%s\n' "$cfg_org"
  exit 0
fi

if org="$(extract_org_from_extension "$PROFILE_DIR" || true)" && [[ -n "$org" ]]; then
  log "source=extension"
  printf '%s\n' "$org"
  exit 0
fi

exit 1
