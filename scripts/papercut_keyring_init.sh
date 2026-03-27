#!/usr/bin/env bash
set -euo pipefail

LABEL="login"

usage() {
  cat <<EOF
Usage: $0 [--label <name>]

Initialize a persistent GNOME Secret Service collection if missing.
Prompts for a keyring password and creates a collection securely.

Options:
  --label <name>   collection label (default: login)
  -h, --help       show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
  echo "No user DBus session detected. Run from your normal desktop user session." >&2
  exit 1
fi

read -r -s -p "Keyring password: " PW1
echo
read -r -s -p "Confirm keyring password: " PW2
echo
if [[ -z "$PW1" ]]; then
  echo "Password cannot be empty." >&2
  exit 1
fi
if [[ "$PW1" != "$PW2" ]]; then
  echo "Passwords do not match." >&2
  exit 1
fi

COLLECTION_PATH="$(
  printf '%s' "$PW1" | python3 - <<'PY' "$LABEL"
import sys
import dbus

label = sys.argv[1]
password = sys.stdin.buffer.read()

bus = dbus.SessionBus()
svc_obj = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
props = dbus.Interface(svc_obj, "org.freedesktop.DBus.Properties")
service = dbus.Interface(svc_obj, "org.freedesktop.Secret.Service")
internal = dbus.Interface(svc_obj, "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface")

collections = [str(c) for c in props.Get("org.freedesktop.Secret.Service", "Collections")]
persist = [c for c in collections if c != "/org/freedesktop/secrets/collection/session"]
if persist:
    print(persist[0])
    raise SystemExit(0)

_, session_path = service.OpenSession("plain", dbus.String(""))
attrs = dbus.Dictionary(
    {"org.freedesktop.Secret.Collection.Label": dbus.String(label)},
    signature="sv",
)
secret = dbus.Struct(
    (
        dbus.ObjectPath(session_path),
        dbus.Array([], signature="y"),
        dbus.Array(list(password), signature="y"),
        dbus.String("text/plain"),
    )
)

collection = str(internal.CreateWithMasterPassword(attrs, secret))
try:
    service.SetAlias("default", dbus.ObjectPath(collection))
except Exception:
    pass
print(collection)
PY
)"

unset PW1 PW2
echo "Keyring collection ready: $COLLECTION_PATH"
