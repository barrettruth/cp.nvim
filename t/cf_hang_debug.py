#!/usr/bin/env python3
"""Pinpoint where session.fetch hangs on the submit page."""
import json
import sys
import threading
from pathlib import Path

sys.path.insert(0, ".")

from scrapers.atcoder import _ensure_browser
from scrapers.codeforces import BASE_URL
from scrapers.timeouts import BROWSER_SESSION_TIMEOUT


def watchdog(label, timeout=20):
    import time
    time.sleep(timeout)
    print(f"WATCHDOG: {label} timed out after {timeout}s", flush=True)
    import os
    os._exit(1)


def main():
    from scrapling.fetchers import StealthySession

    _ensure_browser()

    cookie_cache = Path.home() / ".cache" / "cp-nvim" / "codeforces-cookies.json"
    saved_cookies = []
    if cookie_cache.exists():
        try:
            saved_cookies = json.loads(cookie_cache.read_text())
        except Exception:
            pass

    def check_login(page):
        logged_in = page.evaluate(
            "() => Array.from(document.querySelectorAll('a'))"
            ".some(a => a.textContent.includes('Logout'))"
        )
        print(f"logged_in: {logged_in}", flush=True)

    def submit_action(page):
        print(f"submit_action ENTERED: url={page.url} title={page.title()}", flush=True)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies,
        ) as session:
            print("1. Homepage...", flush=True)
            session.fetch(f"{BASE_URL}/", page_action=check_login, network_idle=True)

            print("2. Submit page (no network_idle, no solve_cloudflare)...", flush=True)
            t = threading.Thread(target=watchdog, args=("session.fetch submit", 30), daemon=True)
            t.start()

            session.fetch(
                f"{BASE_URL}/contest/1933/submit",
                page_action=submit_action,
            )
            print("3. Done!", flush=True)
    except Exception as e:
        print(f"FATAL: {type(e).__name__}: {e}", flush=True)


if __name__ == "__main__":
    main()
