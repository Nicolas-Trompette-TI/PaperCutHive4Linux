#!/usr/bin/env python3
import argparse
import json
import os
import re
from datetime import datetime, timezone


def now_ts():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def load(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def extract(sw_text):
    endpoints = sorted(
        set(
            re.findall(
                r"/print-client/secure/printclient-gateway/(?:org/\$\{s\}/)?[a-zA-Z0-9\-\/]+v\d+",
                sw_text,
            )
        )
    )

    header_names = [
        "Authorization",
        "client-type",
        "PMITC-PrintRequest-Id",
        "Encrypted",
        "X-Correlation-ID",
        "Content-Type",
        "Accept",
        "Client-Id",
        "X-PMITC-OrgId",
    ]
    header_keys = []
    for name in header_names:
        if f'"{name}"' in sw_text or f"{name}:" in sw_text:
            header_keys.append(name)

    form_fields = sorted(set(re.findall(r'o\.append\("([^"]+)"', sw_text)))

    hints = {
        "print_submit_call": "Im(e+\"/print\", t, formData)",
        "print_submit_encrypted_call": "Im(e.url+\"/print-encrypted\", encryptedJwt, formData)",
        "claim_identity_log": "[linking] start claim print client identity",
        "printer_name": "PaperCut Printer",
        "provider_id": "PMITC-Chrome",
    }

    return {
        "endpoints": endpoints,
        "header_keys": header_keys,
        "form_fields": form_fields,
        "hints": hints,
    }


def main():
    ap = argparse.ArgumentParser(description="Extract PaperCut Hive extension protocol hints from service_worker.js")
    ap.add_argument(
        "--extension-dir",
        default="/home/nicolas/PaperCutHiveDriver_Ubuntu-24.04/hive-ubuntu-research-kit/tools/extensions/pdlopiakikhioinbeibaachakgdgllff/unpacked",
    )
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    manifest_path = os.path.join(args.extension_dir, "manifest.json")
    sw_path = os.path.join(args.extension_dir, "service_worker.js")

    manifest = json.loads(load(manifest_path))
    sw_text = load(sw_path)

    data = extract(sw_text)
    result = {
        "timestamp_utc": now_ts(),
        "extension_name": manifest.get("name"),
        "extension_version": manifest.get("version"),
        "extension_id_hint": "pdlopiakikhioinbeibaachakgdgllff",
        "permissions": manifest.get("permissions", []),
        "externally_connectable": manifest.get("externally_connectable", {}),
        "content_script_matches": (manifest.get("content_scripts") or [{}])[0].get("matches", []),
        "protocol": data,
    }

    text = json.dumps(result, indent=2)
    print(text)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"Wrote: {args.output}")


if __name__ == "__main__":
    raise SystemExit(main())
