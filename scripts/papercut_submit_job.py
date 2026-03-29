#!/usr/bin/env python3
import argparse
import json
import os
import random
import string
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import requests


def read_secret_line_from_stdin(label: str) -> str:
    value = sys.stdin.buffer.readline()
    if not value:
        raise SystemExit(f"Missing {label} on stdin")
    return value.decode("utf-8", "replace").strip()


def now_compact_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


def rand_alnum(n: int) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(random.choice(alphabet) for _ in range(n))


def make_print_request_id() -> str:
    return f"{rand_alnum(16)}-{now_compact_utc()}"


def make_correlation_id() -> str:
    return f"CHROME-PRINT-CLIENT|{rand_alnum(20)}"


def get_client_id() -> str:
    candidates = []
    env_state = os.environ.get("PAPERCUT_STATE_DIR", "").strip()
    if env_state:
        candidates.append(Path(env_state))

    home = os.environ.get("HOME", "").strip()
    if home:
        candidates.append(Path(home) / ".config" / "papercut-hive-lite")

    candidates.extend(
        [
            Path("/var/lib/papercut-hive-lite"),
            Path("/tmp/papercut-hive-lite"),
        ]
    )

    for state_dir in candidates:
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            cid_file = state_dir / "client_id"
            if cid_file.exists():
                return cid_file.read_text(encoding="utf-8").strip()

            cid = str(uuid.uuid4())
            cid_file.write_text(cid + "\n", encoding="utf-8")
            try:
                os.chmod(cid_file, 0o600)
            except Exception:
                pass
            return cid
        except Exception:
            continue

    raise RuntimeError("Unable to create/read client_id state directory")


def normalize_cloud_host(cloud_host: str) -> str:
    host = cloud_host.strip()
    if host.startswith("http://") or host.startswith("https://"):
        return urlparse(host).netloc
    return host


def derive_pmitc_base(cloud_host: str) -> str:
    host = normalize_cloud_host(cloud_host)
    if host.startswith("localhost") or host.startswith("127.0.0.1"):
        return f"http://{host}"
    if not host:
        return "https://pmitc.papercut.com"
    parts = host.split(".")
    if len(parts) < 2:
        return "https://pmitc.papercut.com"
    sub = parts[0]
    tld = parts[-1]
    if sub in {"hive", "pocket"}:
        return "https://pmitc.papercut.com"
    return f"https://{sub}.pmitc.papercut.{tld}"


def request_json(method: str, url: str, headers: dict, timeout: int, body=None, verify=True):
    resp = requests.request(
        method=method,
        url=url,
        headers=headers,
        json=body,
        timeout=timeout,
        verify=verify,
    )
    out = {
        "ok": resp.ok,
        "status": resp.status_code,
        "url": url,
        "text": resp.text[:2000],
    }
    try:
        out["json"] = resp.json()
    except Exception:
        out["json"] = None
    return out


def claim_user_jwt(pmitc_base: str, id_token: str, org_id: str, client_id: str, timeout: int, verify: bool):
    url = f"{pmitc_base}/print-client/secure/printclient-gateway/claim-printclient-token/v2"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {id_token}",
        "X-Correlation-ID": make_correlation_id(),
        "Client-Id": client_id,
    }
    if org_id:
        headers["X-PMITC-OrgId"] = org_id

    body = {"appInfo": "Ubuntu Hive Lite, version:0.1"}
    res = request_json("POST", url, headers, timeout, body=body, verify=verify)
    if not res["ok"] or not isinstance(res["json"], dict):
        raise RuntimeError(f"claim-printclient-token failed: status={res['status']} body={res['text']}")

    token = res["json"].get("token")
    claimed_org = res["json"].get("orgId")
    if not token:
        raise RuntimeError(f"claim-printclient-token missing token field: {res['json']}")
    if not claimed_org and not org_id:
        raise RuntimeError(f"claim-printclient-token missing orgId field: {res['json']}")
    return token, (org_id or claimed_org), res


def get_targets(pmitc_base: str, user_jwt: str, org_id: str, client_id: str, client_type: str, timeout: int, verify: bool):
    url = f"{pmitc_base}/print-client/secure/printclient-gateway/org/{org_id}/get-edgenodes-for-printing/v3"
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "client-type": client_type,
        "Authorization": f"Bearer {user_jwt}",
        "X-Correlation-ID": make_correlation_id(),
        "Client-Id": client_id,
        "X-PMITC-OrgId": org_id,
    }
    res = request_json("POST", url, headers, timeout, body={}, verify=verify)
    if not res["ok"] or not isinstance(res["json"], dict):
        raise RuntimeError(f"get-edgenodes-for-printing failed: status={res['status']} body={res['text']}")

    targets = res["json"].get("targets") or []
    if not isinstance(targets, list) or not targets:
        raise RuntimeError(f"No targets found in response: {res['json']}")
    return targets, res


def select_target(targets):
    cloud = [t for t in targets if t.get("nodeType") == "CLOUDNODE" and t.get("addresses")]
    if cloud:
        return cloud[0]["addresses"][0], cloud[0]
    any_target = [t for t in targets if t.get("addresses")]
    if any_target:
        return any_target[0]["addresses"][0], any_target[0]
    raise RuntimeError("Targets response has no usable addresses")


def submit_print(
    target_url: str,
    user_jwt: str,
    org_id: str,
    client_id: str,
    client_type: str,
    file_path: str,
    title: str,
    copies: int,
    duplex: str,
    color: str,
    media_width: int,
    media_height: int,
    file_format: str,
    timeout: int,
    verify: bool,
):
    url = target_url.rstrip("/") + "/print"
    headers = {
        "client-type": client_type,
        "Authorization": f"Bearer {user_jwt}",
        "PMITC-PrintRequest-Id": make_print_request_id(),
        "Encrypted": "true",
        "X-Correlation-ID": make_correlation_id(),
        "Client-Id": client_id,
        "X-PMITC-OrgId": org_id,
    }
    data = {
        "copies": str(copies),
        "duplex": duplex,
        "color": color,
        "mediaWidthMicrons": str(media_width),
        "mediaHeightMicrons": str(media_height),
        "fileFormat": file_format,
        "documentName": title,
    }

    with open(file_path, "rb") as f:
        files = {"printDocument": (os.path.basename(file_path), f, file_format)}
        resp = requests.post(url, headers=headers, data=data, files=files, timeout=timeout, verify=verify)

    return {
        "ok": resp.ok,
        "status": resp.status_code,
        "url": url,
        "text": resp.text[:2000],
        "headers": dict(resp.headers),
    }


def main():
    def is_auth_error_text(text: str) -> bool:
        t = (text or "").lower()
        return "status=401" in t or "status=403" in t or " 401 " in t or " 403 " in t

    ap = argparse.ArgumentParser(description="Submit a print job to PaperCut endpoints using extension-compatible protocol")
    ap.add_argument("--cloud-host", default="eu.hive.papercut.com", help="Example: eu.hive.papercut.com")
    ap.add_argument("--org-id", default="", help="PaperCut org ID. Optional if claim endpoint returns one")
    ap.add_argument("--user-jwt-stdin", action="store_true", help="Read user JWT from stdin")
    ap.add_argument("--id-token-stdin", action="store_true", help="Read id token from stdin and claim user JWT")
    ap.add_argument("--file", required=True, help="Path to file to send (typically PDF)")
    ap.add_argument("--title", default="", help="Document title")
    ap.add_argument("--copies", type=int, default=1)
    ap.add_argument("--duplex", default="NO_DUPLEX", choices=["NO_DUPLEX", "LONG_EDGE", "SHORT_EDGE"])
    ap.add_argument("--color", default="AUTO", choices=["AUTO", "STANDARD_COLOR", "STANDARD_MONOCHROME"])
    ap.add_argument("--media-width", type=int, default=210000)
    ap.add_argument("--media-height", type=int, default=297000)
    ap.add_argument("--file-format", default="application/pdf")
    ap.add_argument("--client-type", default="ChromeApp-2.4.1")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--offline-dry-run", action="store_true", help="No network calls; print computed request plan only")
    ap.add_argument("--target-url", default="", help="Skip target discovery and submit directly to this target base URL")
    ap.add_argument("--output-json", default="")
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        raise SystemExit(f"File not found: {args.file}")

    if args.user_jwt_stdin and args.id_token_stdin:
        raise SystemExit("Choose only one auth source: --user-jwt-stdin or --id-token-stdin")

    verify = True
    title = args.title or os.path.basename(args.file)
    client_id = get_client_id()
    pmitc_base = derive_pmitc_base(args.cloud_host)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cloud_host": args.cloud_host,
        "pmitc_base": pmitc_base,
        "org_id_input": args.org_id,
        "used_claim": False,
        "selected_target": None,
    }

    user_jwt = ""
    id_token = ""
    org_id = args.org_id.strip()

    if args.offline_dry_run:
        target_url = args.target_url.strip() or "<discovery-required>"
        report["offline_dry_run"] = True
        report["selected_target_url"] = target_url
        report["would_submit"] = {
            "url": (target_url.rstrip("/") + "/print") if target_url != "<discovery-required>" else "<discovery-required>",
            "title": title,
            "copies": args.copies,
            "duplex": args.duplex,
            "color": args.color,
            "media_width": args.media_width,
            "media_height": args.media_height,
            "file": args.file,
            "file_format": args.file_format,
        }
        text = json.dumps(report, indent=2)
        print(text)
        if args.output_json:
            Path(args.output_json).write_text(text + "\n", encoding="utf-8")
            print(f"Wrote: {args.output_json}")
        return 0

    try:
        if args.user_jwt_stdin:
            user_jwt = read_secret_line_from_stdin("user JWT")

        if not user_jwt:
            if not args.id_token_stdin:
                raise SystemExit("Need one auth source: --user-jwt-stdin or --id-token-stdin")
            id_token = read_secret_line_from_stdin("id token")
            if not id_token:
                raise SystemExit("Empty id token on stdin")
            try:
                claimed_jwt, claimed_org_id, claim_res = claim_user_jwt(
                    pmitc_base, id_token, org_id, client_id, args.timeout, verify
                )
            except Exception as exc:
                msg = f"claim token failed: {exc}"
                print(msg, file=sys.stderr)
                return 11 if is_auth_error_text(str(exc)) else 2
            user_jwt = claimed_jwt
            org_id = claimed_org_id
            report["used_claim"] = True
            report["claim_status"] = claim_res["status"]
            report["claimed_org_id"] = org_id
            id_token = ""

        if not org_id:
            raise SystemExit("org_id is required and was not resolved")

        forced_target = args.target_url.strip()
        if forced_target:
            target_url = forced_target
            report["selected_target_url"] = target_url
            report["selected_target"] = {"nodeType": "FORCED", "addresses": [target_url]}
        else:
            try:
                targets, targets_res = get_targets(
                    pmitc_base, user_jwt, org_id, client_id, args.client_type, args.timeout, verify
                )
            except Exception as exc:
                msg = f"target discovery failed: {exc}"
                print(msg, file=sys.stderr)
                return 11 if is_auth_error_text(str(exc)) else 2
            report["targets_status"] = targets_res["status"]
            report["targets_count"] = len(targets)
            target_url, target_obj = select_target(targets)
            report["selected_target"] = target_obj
            report["selected_target_url"] = target_url

        if args.dry_run:
            report["dry_run"] = True
            report["would_submit"] = {
                "url": target_url.rstrip("/") + "/print",
                "title": title,
                "copies": args.copies,
                "duplex": args.duplex,
                "color": args.color,
                "media_width": args.media_width,
                "media_height": args.media_height,
                "file": args.file,
                "file_format": args.file_format,
            }
            text = json.dumps(report, indent=2)
            print(text)
            if args.output_json:
                Path(args.output_json).write_text(text + "\n", encoding="utf-8")
                print(f"Wrote: {args.output_json}")
            return 0

        try:
            submit_res = submit_print(
                target_url=target_url,
                user_jwt=user_jwt,
                org_id=org_id,
                client_id=client_id,
                client_type=args.client_type,
                file_path=args.file,
                title=title,
                copies=args.copies,
                duplex=args.duplex,
                color=args.color,
                media_width=args.media_width,
                media_height=args.media_height,
                file_format=args.file_format,
                timeout=args.timeout,
                verify=verify,
            )
        except Exception as exc:
            print(f"submit failed: {exc}", file=sys.stderr)
            return 2
        report["submit"] = submit_res

        text = json.dumps(report, indent=2)
        print(text)

        if args.output_json:
            Path(args.output_json).write_text(text + "\n", encoding="utf-8")
            print(f"Wrote: {args.output_json}")

        if submit_res["ok"]:
            return 0
        if submit_res.get("status") in (401, 403):
            return 11
        return 2
    finally:
        user_jwt = ""
        id_token = ""


if __name__ == "__main__":
    sys.exit(main())
