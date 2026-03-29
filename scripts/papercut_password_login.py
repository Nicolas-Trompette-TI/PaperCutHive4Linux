#!/usr/bin/env python3
"""Interactive PaperCut Hive/Pocket login (email+password) for CLI setup.

This script performs:
1) tenant discovery from login API
2) Firebase email/password auth (tenant-aware) to obtain an ID token
3) PaperCut PMITC claim-token call to obtain user JWT + org ID
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import sys
import uuid
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import Request, urlopen


KNOWN_FIREBASE_API_KEYS = {
    "login.papercut.com": "AIzaSyAM2EGnVwfkCjUeO0O1rAuuxfMnx33oI94",
    "au-staging.login.papercut.software": "AIzaSyDOPWlV8H25-eqqDHo7nfm9paF84dIXErw",
    "au-test.login.papercut.software": "AIzaSyDqf_Sg1GkXpbds_MRWMP-o66pksZMrKto",
}

FIREBASE_API_KEY_PATTERN = re.compile(r"AIza[0-9A-Za-z_-]{35}")
INVALID_FIREBASE_KEY_ERRORS = {
    "API_KEY_INVALID",
    "INVALID_API_KEY",
    "API_KEY_EXPIRED",
}
HOST_ASSIGNMENT_PATTERN = re.compile(
    r'([A-Za-z_$][A-Za-z0-9_$]{0,40})\s*=\s*"([A-Za-z0-9.-]+\.[A-Za-z]{2,})"'
)
APIKEY_AUTHDOMAIN_PATTERN = re.compile(
    r'apiKey\s*:\s*"(?P<key>AIza[0-9A-Za-z_-]{35})"\s*,\s*'
    r"authDomain\s*:\s*(?P<domain>\"[^\"]+\"|[A-Za-z_$][A-Za-z0-9_$]{0,40})"
)
AUTHDOMAIN_APIKEY_PATTERN = re.compile(
    r"authDomain\s*:\s*(?P<domain>\"[^\"]+\"|[A-Za-z_$][A-Za-z0-9_$]{0,40})\s*,\s*"
    r'apiKey\s*:\s*"(?P<key>AIza[0-9A-Za-z_-]{35})"'
)


class HttpJsonError(RuntimeError):
    def __init__(
        self,
        *,
        method: str,
        url: str,
        status: int,
        data: dict[str, Any] | None,
        text: str,
    ) -> None:
        self.method = method
        self.url = url
        self.status = status
        self.data = data
        self.text = text
        message = f"{method} {url} failed with status={status}"
        if isinstance(data, dict):
            message = f"{message}: {data.get('error') or data}"
        elif text:
            message = f"{message}: {text[:4000]}"
        super().__init__(message)


def normalize_host(host_or_url: str) -> str:
    raw = (host_or_url or "").strip()
    if raw.startswith("http://") or raw.startswith("https://"):
        return (urlparse(raw).netloc or "").strip().lower()
    return raw.lower()


def derive_product(cloud_host: str) -> str:
    host = normalize_host(cloud_host)
    if host.startswith("pocket."):
        return "pocket"
    return "hive"


def derive_pmitc_base(cloud_host: str) -> str:
    host = normalize_host(cloud_host)
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


def die(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def request_json(
    method: str,
    url: str,
    *,
    timeout: int,
    headers: dict[str, str] | None = None,
    params: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    request_url = url
    if params:
        query = urlencode(params)
        request_url = f"{url}{'&' if '?' in url else '?'}{query}"

    request_headers = dict(headers or {})
    request_data: bytes | None = None
    if payload is not None:
        request_data = json.dumps(payload).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")

    req = Request(
        request_url,
        data=request_data,
        headers=request_headers,
        method=method.upper(),
    )

    try:
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
    except HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        data: dict[str, Any] | None
        try:
            parsed = json.loads(body)
            data = parsed if isinstance(parsed, dict) else None
        except Exception:
            data = None
        raise HttpJsonError(
            method=method.upper(),
            url=request_url,
            status=exc.code,
            data=data,
            text=body,
        ) from exc
    except URLError as exc:
        raise RuntimeError(f"{method.upper()} {request_url} failed: {exc}") from exc

    try:
        parsed = json.loads(body)
    except Exception as exc:
        raise RuntimeError(f"{method.upper()} {request_url} returned non-JSON response") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError(f"{method.upper()} {request_url} returned non-JSON response")
    return parsed


def choose_tenant_interactive(tenants: list[dict[str, Any]]) -> dict[str, Any]:
    if len(tenants) == 1:
        return tenants[0]
    print("Multiple organizations found for this account:", file=sys.stderr)
    for idx, tenant in enumerate(tenants, start=1):
        display_name = str(tenant.get("displayName") or tenant.get("id") or f"tenant-{idx}")
        tenant_id = str(tenant.get("id") or "")
        print(f"  {idx}) {display_name} [{tenant_id}]", file=sys.stderr)
    while True:
        print("Choose organization number: ", end="", file=sys.stderr, flush=True)
        choice = sys.stdin.readline().strip()
        if not choice.isdigit():
            print("Enter a number.", file=sys.stderr)
            continue
        i = int(choice)
        if 1 <= i <= len(tenants):
            return tenants[i - 1]
        print("Invalid choice.", file=sys.stderr)


def map_identity_error(err_payload: dict[str, Any]) -> str:
    code = extract_identity_error_code(err_payload)
    friendly = {
        "EMAIL_NOT_FOUND": "Unknown email for selected organization.",
        "INVALID_PASSWORD": "Invalid password.",
        "INVALID_LOGIN_CREDENTIALS": "Invalid email or password.",
        "USER_DISABLED": "Account is disabled.",
        "TENANT_NOT_FOUND": "Tenant not found for this account.",
        "INVALID_TENANT_ID": "Invalid tenant id.",
        "TOO_MANY_ATTEMPTS_TRY_LATER": "Too many attempts. Try again later.",
        "API_KEY_INVALID": "PaperCut login backend key changed (refresh required).",
        "INVALID_API_KEY": "PaperCut login backend key changed (refresh required).",
        "API_KEY_EXPIRED": "PaperCut login backend key changed (refresh required).",
    }
    return friendly.get(code, code or "Authentication failed")


def extract_identity_error_code(err_payload: dict[str, Any]) -> str:
    err_obj = err_payload.get("error") if isinstance(err_payload, dict) else None
    if isinstance(err_obj, dict):
        return str(err_obj.get("message") or "")
    return ""


def is_firebase_api_key(value: str) -> bool:
    return bool(FIREBASE_API_KEY_PATTERN.fullmatch((value or "").strip()))


def firebase_cache_path() -> str:
    cache_home = os.environ.get("XDG_CACHE_HOME", "").strip()
    if not cache_home:
        cache_home = os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(cache_home, "papercut-hive-lite", "firebase_api_keys.json")


def load_cached_firebase_keys(path: str) -> dict[str, str]:
    if not path:
        return {}
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            return {}
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    cleaned: dict[str, str] = {}
    for host, key in data.items():
        if isinstance(host, str) and isinstance(key, str) and is_firebase_api_key(key):
            cleaned[normalize_host(host)] = key.strip()
    return cleaned


def save_cached_firebase_key(path: str, host: str, key: str) -> None:
    if not path or not host or not is_firebase_api_key(key):
        return
    try:
        parent = os.path.dirname(path)
        os.makedirs(parent, mode=0o700, exist_ok=True)
        try:
            os.chmod(parent, 0o700)
        except OSError:
            pass

        data = load_cached_firebase_keys(path)
        data[normalize_host(host)] = key.strip()

        tmp_path = f"{path}.{uuid.uuid4().hex}.tmp"
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle, sort_keys=True)
                handle.write("\n")
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        return


def fetch_text(url: str, *, timeout: int) -> str:
    req = Request(
        url,
        headers={
            "User-Agent": "PaperCutHive4Linux/1.0 (+https://github.com/Nicolas-Trompette-TI/PaperCutHive4Linux)",
            "Accept": "text/html,application/javascript,text/javascript,*/*;q=0.8",
        },
        method="GET",
    )
    with urlopen(req, timeout=timeout) as resp:
        raw = resp.read(2_000_000)
    return raw.decode("utf-8", "replace")


def extract_script_urls(html: str, page_url: str, host: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for match in re.finditer(r"<script[^>]+src=[\"']([^\"']+)[\"']", html, flags=re.IGNORECASE):
        src = match.group(1).strip()
        if not src:
            continue
        absolute = urljoin(page_url, src)
        parsed = urlparse(absolute)
        if parsed.scheme not in {"http", "https"}:
            continue
        if normalize_host(parsed.netloc) != normalize_host(host):
            continue
        if absolute in seen:
            continue
        seen.add(absolute)
        urls.append(absolute)
    return urls


def extract_firebase_keys_from_text(content: str) -> list[str]:
    keys: list[str] = []
    seen: set[str] = set()
    for match in FIREBASE_API_KEY_PATTERN.finditer(content or ""):
        key = match.group(0)
        if key not in seen:
            seen.add(key)
            keys.append(key)
    return keys


def resolve_auth_domain_token(token: str, host_vars: dict[str, str]) -> str:
    raw = (token or "").strip()
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        return normalize_host(raw[1:-1])
    return normalize_host(host_vars.get(raw, ""))


def extract_host_bound_firebase_keys(content: str, login_host: str) -> list[str]:
    host = normalize_host(login_host)
    host_vars: dict[str, str] = {}
    for var_name, domain in HOST_ASSIGNMENT_PATTERN.findall(content or ""):
        host_vars[var_name] = normalize_host(domain)

    matched: list[str] = []
    seen: set[str] = set()

    for pattern in (APIKEY_AUTHDOMAIN_PATTERN, AUTHDOMAIN_APIKEY_PATTERN):
        for match in pattern.finditer(content or ""):
            key = match.group("key")
            domain_token = match.group("domain")
            domain = resolve_auth_domain_token(domain_token, host_vars)
            if domain != host:
                continue
            if key in seen:
                continue
            seen.add(key)
            matched.append(key)
    return matched


def discover_firebase_api_key(
    *,
    login_base: str,
    login_host: str,
    timeout: int,
    verbose: bool = False,
) -> str:
    pages_to_probe = [
        login_base,
        f"{login_base}/login",
        f"{login_base}/signin",
    ]

    for page_url in pages_to_probe:
        try:
            html = fetch_text(page_url, timeout=timeout)
        except Exception:
            continue
        host_keys = extract_host_bound_firebase_keys(html, login_host)
        if host_keys:
            if verbose:
                print(
                    f"Discovered host-bound Firebase API key from {page_url}",
                    file=sys.stderr,
                )
            return host_keys[0]
        keys = extract_firebase_keys_from_text(html)
        if keys:
            if verbose:
                print(
                    f"Discovered Firebase API key from {page_url}",
                    file=sys.stderr,
                )
            return keys[0]
        script_urls = extract_script_urls(html, page_url, login_host)
        for script_url in script_urls[:12]:
            try:
                script_text = fetch_text(script_url, timeout=timeout)
            except Exception:
                continue
            host_keys = extract_host_bound_firebase_keys(script_text, login_host)
            if host_keys:
                if verbose:
                    print(
                        f"Discovered host-bound Firebase API key from script {script_url}",
                        file=sys.stderr,
                    )
                return host_keys[0]
            script_keys = extract_firebase_keys_from_text(script_text)
            if script_keys:
                if verbose:
                    print(
                        f"Discovered Firebase API key from script {script_url}",
                        file=sys.stderr,
                    )
                return script_keys[0]
    return ""


def sign_in_with_password(
    *,
    api_key: str,
    tenant_id: str,
    email: str,
    password: str,
    timeout: int,
) -> dict[str, Any]:
    signin_url = (
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"
        f"?key={api_key}"
    )
    signin_payload = {
        "email": email,
        "password": password,
        "returnSecureToken": True,
        "tenantId": tenant_id,
    }
    return request_json(
        "POST",
        signin_url,
        timeout=timeout,
        headers={"Content-Type": "application/json"},
        payload=signin_payload,
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="PaperCut login via email/password (no browser extension required)"
    )
    ap.add_argument("--cloud-host", default="eu.hive.papercut.com")
    ap.add_argument("--product", default="", help="hive|pocket (default: auto from --cloud-host)")
    ap.add_argument("--login-base-url", default="https://login.papercut.com")
    ap.add_argument("--firebase-api-key", default="")
    ap.add_argument("--org-id", default="", help="optional preferred org-id for claim request")
    ap.add_argument("--tenant-id", default="", help="optional tenant id to skip interactive selection")
    ap.add_argument("--email", default="")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--json", action="store_true", help="print JSON result on stdout")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    cloud_host = normalize_host(args.cloud_host)
    login_base = args.login_base_url.rstrip("/")
    login_host = normalize_host(login_base)
    product = (args.product or derive_product(cloud_host)).strip().lower()
    if product not in {"hive", "pocket"}:
        die(f"Unsupported product '{product}'. Use hive or pocket.")

    cache_path = firebase_cache_path()
    cached_api_keys = load_cached_firebase_keys(cache_path)

    api_key = (args.firebase_api_key or "").strip()
    api_key_source = "arg"
    if not api_key:
        api_key = (cached_api_keys.get(login_host) or "").strip()
        api_key_source = "cache"
    if not api_key:
        api_key = (KNOWN_FIREBASE_API_KEYS.get(login_host) or "").strip()
        api_key_source = "known"
    if not api_key:
        api_key = discover_firebase_api_key(
            login_base=login_base,
            login_host=login_host,
            timeout=args.timeout,
            verbose=args.verbose,
        )
        api_key_source = "discovered"

    if not api_key:
        die(
            "Unable to resolve Firebase API key for this login host. "
            "Provide --firebase-api-key explicitly."
        )
    if args.verbose:
        print(
            f"Firebase API key source: {api_key_source} ({login_host})",
            file=sys.stderr,
        )

    email = (args.email or "").strip()
    if not email:
        print("PaperCut email: ", end="", file=sys.stderr, flush=True)
        email = sys.stdin.readline().strip()
    if not email:
        die("Email is required.")

    password = getpass.getpass("PaperCut password: ").strip()
    if not password:
        die("Password is required.")

    tenants_resp = request_json(
        "GET",
        f"{login_base}/api/tenants",
        timeout=args.timeout,
        params={"email": email, "product": product},
    )
    tenants = tenants_resp.get("tenants")
    if not isinstance(tenants, list) or not tenants:
        die("No organizations found for this account.")

    tenant: dict[str, Any] | None = None
    if args.tenant_id:
        for item in tenants:
            if str(item.get("id") or "") == args.tenant_id:
                tenant = item
                break
        if tenant is None:
            die(f"Tenant id '{args.tenant_id}' is not available for this account.")
    else:
        tenant = choose_tenant_interactive(tenants)

    tenant_id = str(tenant.get("id") or "")
    if not tenant_id:
        die("Selected tenant has no id.")

    try:
        signin_data = sign_in_with_password(
            api_key=api_key,
            tenant_id=tenant_id,
            email=email,
            password=password,
            timeout=args.timeout,
        )
    except HttpJsonError as exc:
        err_data = exc.data if isinstance(exc.data, dict) else {}
        err_code = extract_identity_error_code(err_data)
        should_refresh_key = (
            not args.firebase_api_key and err_code in INVALID_FIREBASE_KEY_ERRORS
        )
        if not should_refresh_key:
            die(f"Login failed: {map_identity_error(err_data)}", code=2)

        refreshed_api_key = discover_firebase_api_key(
            login_base=login_base,
            login_host=login_host,
            timeout=args.timeout,
            verbose=args.verbose,
        )
        if not refreshed_api_key or refreshed_api_key == api_key:
            die(
                "Login failed: Firebase API key appears outdated and auto-refresh failed. "
                "Retry later or provide --firebase-api-key explicitly.",
                code=2,
            )
        api_key = refreshed_api_key
        save_cached_firebase_key(cache_path, login_host, api_key)
        if args.verbose:
            print(
                f"Firebase API key refreshed and cached for host: {login_host}",
                file=sys.stderr,
            )
        try:
            signin_data = sign_in_with_password(
                api_key=api_key,
                tenant_id=tenant_id,
                email=email,
                password=password,
                timeout=args.timeout,
            )
        except HttpJsonError as retry_exc:
            retry_data = retry_exc.data if isinstance(retry_exc.data, dict) else {}
            die(f"Login failed: {map_identity_error(retry_data)}", code=2)

    if not args.firebase_api_key:
        save_cached_firebase_key(cache_path, login_host, api_key)

    id_token = str(signin_data.get("idToken") or "")
    if not id_token:
        die("Login succeeded but no idToken was returned.", code=2)
    password = ""

    pmitc_base = derive_pmitc_base(cloud_host)
    client_id = str(uuid.uuid4())
    claim_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Authorization": f"Bearer {id_token}",
        "X-Correlation-ID": f"CLI-PASSWORD-LOGIN|{uuid.uuid4().hex[:20]}",
        "Client-Id": client_id,
    }
    if args.org_id:
        claim_headers["X-PMITC-OrgId"] = args.org_id

    claim_data = request_json(
        "POST",
        f"{pmitc_base}/print-client/secure/printclient-gateway/claim-printclient-token/v2",
        timeout=args.timeout,
        headers=claim_headers,
        payload={"appInfo": "Ubuntu Hive Lite, version:0.1"},
    )
    claim_headers["Authorization"] = "Bearer [redacted]"
    id_token = ""

    user_jwt = str(claim_data.get("token") or "")
    resolved_org_id = str(claim_data.get("orgId") or args.org_id or "")
    if not user_jwt:
        die("Token claim succeeded but no user JWT was returned.", code=3)
    if not resolved_org_id:
        die("Token claim succeeded but no Org ID was returned.", code=3)

    result = {
        "email": email,
        "tenant_id": tenant_id,
        "tenant_display_name": str(tenant.get("displayName") or ""),
        "product": product,
        "cloud_host": cloud_host,
        "org_id": resolved_org_id,
        "user_jwt": user_jwt,
    }

    if args.json:
        print(json.dumps(result))
    elif args.verbose:
        print(
            f"Login OK: email={email} tenant={tenant_id} org={resolved_org_id} "
            f"pmitc={pmitc_base}"
        )
    else:
        print(f"Login OK: org_id={resolved_org_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
