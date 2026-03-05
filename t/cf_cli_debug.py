#!/usr/bin/env python3
"""Reproduce CLI hang: go through asyncio.to_thread like the real code."""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")

from scrapers.atcoder import _ensure_browser, _solve_turnstile
from scrapers.codeforces import BASE_URL, _wait_for_gate_reload
from scrapers.timeouts import BROWSER_SESSION_TIMEOUT


def _test_submit():
    from scrapling.fetchers import StealthySession

    _ensure_browser()

    cookie_cache = Path.home() / ".cache" / "cp-nvim" / "codeforces-cookies.json"
    saved_cookies = []
    if cookie_cache.exists():
        try:
            saved_cookies = json.loads(cookie_cache.read_text())
        except Exception:
            pass

    logged_in = False

    def check_login(page):
        nonlocal logged_in
        logged_in = page.evaluate(
            "() => Array.from(document.querySelectorAll('a'))"
            ".some(a => a.textContent.includes('Logout'))"
        )
        print(f"logged_in: {logged_in}", flush=True)

    def submit_action(page):
        print(f"ENTERED submit_action: url={page.url}", flush=True)

    with StealthySession(
        headless=True,
        timeout=BROWSER_SESSION_TIMEOUT,
        google_search=False,
        cookies=saved_cookies,
    ) as session:
        print("fetch homepage...", flush=True)
        session.fetch(f"{BASE_URL}/", page_action=check_login, network_idle=True)

        print("fetch submit page...", flush=True)
        session.fetch(
            f"{BASE_URL}/contest/1933/submit",
            page_action=submit_action,
        )
        print("DONE", flush=True)

    return "ok"


async def main():
    print("Running via asyncio.to_thread...", flush=True)
    result = await asyncio.to_thread(_test_submit)
    print(f"Result: {result}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
