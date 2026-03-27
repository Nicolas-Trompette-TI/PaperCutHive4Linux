#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

from selenium import webdriver
from selenium.common.exceptions import WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By


def ts_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"[{ts_now()}] {msg}", flush=True)


def first_visible(driver, selectors):
    for by, sel in selectors:
        try:
            elems = driver.find_elements(by, sel)
            for elem in elems:
                if elem.is_displayed():
                    return elem, (by, sel)
        except Exception:
            continue
    return None, None


def click_one(driver, selectors):
    elem, used = first_visible(driver, selectors)
    if elem is None:
        return False, None
    try:
        elem.click()
    except Exception:
        driver.execute_script("arguments[0].click();", elem)
    return True, used


def derive_login_url(base_url):
    parsed = urlparse(base_url)
    host_parts = parsed.netloc.split(".")
    product = "hive"
    data_center = "eu"
    if len(host_parts) >= 3:
        data_center = host_parts[0]
        product = host_parts[1]

    q = parse_qs(parsed.query)
    q["returnedFromAuth"] = ["true"]
    q.pop("error", None)
    redirect_url = urlunparse(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path or "/setup-instructions",
            parsed.params,
            urlencode({k: v[-1] for k, v in q.items()}, doseq=False),
            parsed.fragment,
        )
    )

    login_qs = {"product": product, "dataCenter": data_center, "redirectUrl": redirect_url}
    if "orgId" in q and q["orgId"]:
        login_qs["externalEntityId"] = q["orgId"][-1]
    identity_base = os.environ.get("PAPERCUT_IDENTITY_BASE_URL", "https://login.papercut.com").rstrip("/")
    return f"{identity_base}/?{urlencode(login_qs)}"


def wait_for_url_change(driver, previous, timeout_s=20):
    start = time.time()
    while time.time() - start < timeout_s:
        now = driver.current_url
        if now != previous:
            return now
        time.sleep(0.5)
    return driver.current_url


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--login", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--login-url", default="")
    ap.add_argument("--user-data-dir", required=True)
    ap.add_argument("--ext-dir", required=True)
    ap.add_argument("--outputs-dir", required=True)
    ap.add_argument("--chromium-bin", default="/usr/bin/chromium")
    ap.add_argument("--chromedriver-bin", default="/usr/bin/chromedriver")
    args = ap.parse_args()

    os.makedirs(args.outputs_dir, exist_ok=True)
    run_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    screenshot = os.path.join(args.outputs_dir, f"pathA-auth-selenium-{run_ts}.png")
    html_dump = os.path.join(args.outputs_dir, f"pathA-auth-selenium-{run_ts}.html")
    cookies_dump = os.path.join(args.outputs_dir, f"pathA-auth-cookies-{run_ts}.json")
    logs_dump = os.path.join(args.outputs_dir, f"pathA-auth-browserlogs-{run_ts}.json")
    summary_dump = os.path.join(args.outputs_dir, f"pathA-auth-summary-{run_ts}.json")

    log("Starting Selenium auth E2E (controlled mode, single login attempt).")
    log(f"Target URL: {args.base_url}")
    log(f"User data dir: {args.user_data_dir}")
    log(f"Login length: {len(args.login)} | Password length: {len(args.password)}")

    opts = Options()
    opts.binary_location = args.chromium_bin
    opts.add_argument("--headless=new")
    opts.add_argument("--no-sandbox")
    opts.add_argument("--disable-gpu")
    opts.add_argument("--disable-dev-shm-usage")
    opts.add_argument("--window-size=1600,1200")
    opts.add_argument(f"--user-data-dir={args.user_data_dir}")
    opts.add_argument(f"--disable-extensions-except={args.ext_dir}")
    opts.add_argument(f"--load-extension={args.ext_dir}")
    opts.set_capability("goog:loggingPrefs", {"browser": "ALL"})

    driver = None
    summary = {
        "timestamp_utc": run_ts,
        "target_url": args.base_url,
        "login_url": args.login_url or derive_login_url(args.base_url),
        "final_url": None,
        "login_attempted": False,
        "email_step_seen": False,
        "password_step_seen": False,
        "password_submitted": False,
        "auth_cookie_found": False,
        "pc_idtoken_found": False,
        "last_accessed_cookie_found": False,
        "browser_log_keyword_hits": {},
        "artifacts": {
            "screenshot": screenshot,
            "html": html_dump,
            "cookies": cookies_dump,
            "browser_logs": logs_dump,
        },
    }

    try:
        service = Service(executable_path=args.chromedriver_bin)
        driver = webdriver.Chrome(service=service, options=opts)
        driver.set_page_load_timeout(60)

        login_url = args.login_url or derive_login_url(args.base_url)
        log(f"Opening identity page: {login_url}")
        driver.get(login_url)
        time.sleep(3)
        log(f"Current URL after identity load: {driver.current_url}")

        email_selectors = [
            (By.CSS_SELECTOR, "input#email-field"),
            (By.CSS_SELECTOR, "input[type='email']"),
            (By.CSS_SELECTOR, "input[name='loginfmt']"),
            (By.CSS_SELECTOR, "input[name*='email' i]"),
            (By.CSS_SELECTOR, "input[id*='email' i]"),
            (By.CSS_SELECTOR, "input[autocomplete='username']"),
            (By.CSS_SELECTOR, "input[type='text']"),
        ]
        password_selectors = [
            (By.CSS_SELECTOR, "input[type='password']"),
            (By.CSS_SELECTOR, "input[name='passwd']"),
            (By.CSS_SELECTOR, "input[name*='password' i]"),
            (By.CSS_SELECTOR, "input[id*='password' i]"),
            (By.CSS_SELECTOR, "input[autocomplete='current-password']"),
        ]
        submit_selectors = [
            (By.CSS_SELECTOR, "#idSIButton9"),
            (By.CSS_SELECTOR, "button[type='submit']"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'log in')]"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'continue')]"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'submit')]"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'continue')]"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'next')]"),
            (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'sign in')]"),
            (By.XPATH, "//input[@type='submit']"),
        ]

        email_elem, used_email_sel = first_visible(driver, email_selectors)
        if email_elem is not None:
            summary["login_attempted"] = True
            summary["email_step_seen"] = True
            log(f"Email field found with selector {used_email_sel}; typing login.")
            email_elem.clear()
            email_elem.send_keys(args.login)
            clicked, used_submit_sel = click_one(driver, submit_selectors)
            log(f"Submit click after email: {clicked} selector={used_submit_sel}")
            before_url = driver.current_url
            changed_url = wait_for_url_change(driver, before_url, timeout_s=15)
            log(f"URL after email submit wait: {changed_url}")
        else:
            log("No visible email field found on identity page; continuing.")

        used_pw_sel = None
        for _ in range(40):
            pw_elem, used_pw_sel = first_visible(driver, password_selectors)
            if pw_elem is not None and not summary["password_submitted"]:
                summary["password_step_seen"] = True
                log(f"Password field found with selector {used_pw_sel}.")
                pw_elem.clear()
                pw_elem.send_keys(args.password)
                clicked, used_submit_sel = click_one(driver, submit_selectors)
                summary["password_submitted"] = clicked
                log(f"Submit click after password: {clicked} selector={used_submit_sel}")
                before_url = driver.current_url
                changed_url = wait_for_url_change(driver, before_url, timeout_s=15)
                log(f"URL after password submit wait: {changed_url}")

            # Handle common "Stay signed in?" prompt.
            yes_btn_selectors = [
                (By.CSS_SELECTOR, "#idSIButton9"),
                (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'yes')]"),
                (By.XPATH, "//button[contains(translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'continue')]"),
            ]
            clicked_yes, used_yes = click_one(driver, yes_btn_selectors)
            if clicked_yes:
                log(f"Post-auth prompt button clicked: selector={used_yes}")

            cur = driver.current_url
            if "hive.papercut.com/setup-instructions" in cur or "returnedFromAuth=true" in cur:
                log(f"Reached post-auth URL candidate: {cur}")
                break
            time.sleep(1)

        if not summary["password_step_seen"]:
            log("Password field not found in wait window.")

        # Keep this conservative to avoid extra request churn.
        for _ in range(8):
            time.sleep(1)

        log(f"URL after login attempt wait: {driver.current_url}")
        summary["final_url"] = driver.current_url

        log("Reloading setup page once to trigger extension linking if cookie/session is present...")
        driver.get(args.base_url)
        time.sleep(4)
        summary["final_url"] = driver.current_url
        log(f"URL after setup reload: {driver.current_url}")

        cookies = driver.get_cookies()
        redacted = []
        for c in cookies:
            entry = {
                "name": c.get("name"),
                "domain": c.get("domain"),
                "path": c.get("path"),
                "secure": c.get("secure"),
                "httpOnly": c.get("httpOnly"),
                "sameSite": c.get("sameSite"),
                "expiry": c.get("expiry"),
                "value_len": len(c.get("value", "")),
            }
            redacted.append(entry)

        with open(cookies_dump, "w", encoding="utf-8") as f:
            json.dump(redacted, f, indent=2)

        names = {c.get("name", "") for c in cookies}
        summary["auth_cookie_found"] = "auth-token" in names
        summary["pc_idtoken_found"] = "pc-idtoken" in names
        summary["last_accessed_cookie_found"] = "last-accessed-cloud-host-hive" in names

        logs = []
        try:
            logs = driver.get_log("browser")
        except Exception:
            logs = []

        with open(logs_dump, "w", encoding="utf-8") as f:
            json.dump(logs, f, indent=2)

        keywords = [
            "starting printprovider",
            "[linking]",
            "auth-token",
            "application is linked",
            "failed to link",
            "claim print client identity",
            "PMITC Printer",
            "no auth token",
        ]
        hits = {k: 0 for k in keywords}
        for row in logs:
            msg = str(row.get("message", ""))
            for k in keywords:
                if k in msg:
                    hits[k] += 1
        summary["browser_log_keyword_hits"] = hits

        driver.save_screenshot(screenshot)
        with open(html_dump, "w", encoding="utf-8", errors="ignore") as f:
            f.write(driver.page_source)

        log(f"Cookie names found: {sorted(list(names))[:20]}")
        log(f"Summary flags: auth-token={summary['auth_cookie_found']} pc-idtoken={summary['pc_idtoken_found']} last-accessed={summary['last_accessed_cookie_found']}")

    except WebDriverException as exc:
        summary["error"] = f"webdriver_error: {exc}"
        log(f"WebDriver error: {exc}")
    except Exception as exc:  # pragma: no cover
        summary["error"] = f"unexpected_error: {exc}"
        log(f"Unexpected error: {exc}")
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:
                pass

        with open(summary_dump, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)

        log(f"Wrote summary: {summary_dump}")
        log(f"Wrote cookies: {cookies_dump}")
        log(f"Wrote browser logs: {logs_dump}")
        log(f"Wrote screenshot: {screenshot}")
        log(f"Wrote html dump: {html_dump}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
