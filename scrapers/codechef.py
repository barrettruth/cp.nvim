#!/usr/bin/env python3

import asyncio
import json
import re
from pathlib import Path
from typing import Any

import httpx
from curl_cffi import requests as curl_requests

from .base import BaseScraper, extract_precision
from .timeouts import BROWSER_NAV_TIMEOUT, BROWSER_SESSION_TIMEOUT, HTTP_TIMEOUT
from .models import (
    ContestListResult,
    ContestSummary,
    LoginResult,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)

BASE_URL = "https://www.codechef.com"
API_CONTESTS_ALL = "/api/list/contests/all"
API_CONTEST = "/api/contests/{contest_id}"
API_PROBLEM = "/api/contests/{contest_id}/problems/{problem_id}"
PROBLEM_URL = "https://www.codechef.com/problems/{problem_id}"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CONNECTIONS = 8

_COOKIE_PATH = Path.home() / ".cache" / "cp-nvim" / "codechef-cookies.json"

_CC_CHECK_LOGIN_JS = """() => {
    const d = document.getElementById('__NEXT_DATA__');
    if (d) {
        try {
            const p = JSON.parse(d.textContent);
            if (p?.props?.pageProps?.currentUser?.username) return true;
        } catch(e) {}
    }
    return !!document.querySelector('a[href="/logout"]') ||
           !!document.querySelector('[class*="user-name"]');
}"""
MEMORY_LIMIT_RE = re.compile(
    r"Memory\s+[Ll]imit.*?([0-9.]+)\s*(MB|GB)", re.IGNORECASE | re.DOTALL
)


async def fetch_json(client: httpx.AsyncClient, path: str) -> dict[str, Any]:
    r = await client.get(BASE_URL + path, headers=HEADERS, timeout=HTTP_TIMEOUT)
    r.raise_for_status()
    return r.json()


def _extract_memory_limit(html: str) -> float:
    m = MEMORY_LIMIT_RE.search(html)
    if not m:
        return 256.0
    value = float(m.group(1))
    unit = m.group(2).upper()
    if unit == "GB":
        return value * 1024.0
    return value


def _fetch_html_sync(url: str) -> str:
    response = curl_requests.get(url, impersonate="chrome", timeout=HTTP_TIMEOUT)
    response.raise_for_status()
    return response.text


def _login_headless_codechef(credentials: dict[str, str]) -> LoginResult:
    try:
        from scrapling.fetchers import StealthySession  # type: ignore[import-untyped,unresolved-import]
    except ImportError:
        return LoginResult(
            success=False,
            error="scrapling is required for CodeChef login",
        )

    from .atcoder import _ensure_browser

    _ensure_browser()

    _COOKIE_PATH.parent.mkdir(parents=True, exist_ok=True)
    saved_cookies: list[dict[str, Any]] = []
    if _COOKIE_PATH.exists():
        try:
            saved_cookies = json.loads(_COOKIE_PATH.read_text())
        except Exception:
            pass

    logged_in = False
    login_error: str | None = None

    def check_login(page):
        nonlocal logged_in
        logged_in = page.evaluate(_CC_CHECK_LOGIN_JS)

    def login_action(page):
        nonlocal login_error
        try:
            page.locator('input[type="email"], input[name="email"]').first.fill(
                credentials.get("username", "")
            )
            page.locator('input[type="password"], input[name="password"]').first.fill(
                credentials.get("password", "")
            )
            page.locator('button[type="submit"]').first.click()
            page.wait_for_url(
                lambda url: "/login" not in url, timeout=BROWSER_NAV_TIMEOUT
            )
        except Exception as e:
            login_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies if saved_cookies else [],
        ) as session:
            if saved_cookies:
                print(json.dumps({"status": "checking_login"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/", page_action=check_login, network_idle=True
                )

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(f"{BASE_URL}/login", page_action=login_action)
                if login_error:
                    return LoginResult(
                        success=False, error=f"Login failed: {login_error}"
                    )

                session.fetch(
                    f"{BASE_URL}/", page_action=check_login, network_idle=True
                )
                if not logged_in:
                    return LoginResult(
                        success=False, error="Login failed (bad credentials?)"
                    )

            try:
                browser_cookies = session.context.cookies()
                if browser_cookies:
                    _COOKIE_PATH.write_text(json.dumps(browser_cookies))
            except Exception:
                pass

        return LoginResult(success=True, error="")
    except Exception as e:
        return LoginResult(success=False, error=str(e))


def _submit_headless_codechef(
    contest_id: str,
    problem_id: str,
    file_path: str,
    language_id: str,
    credentials: dict[str, str],
    _retried: bool = False,
) -> SubmitResult:
    source_code = Path(file_path).read_text()

    try:
        from scrapling.fetchers import StealthySession  # type: ignore[import-untyped,unresolved-import]
    except ImportError:
        return SubmitResult(
            success=False,
            error="scrapling is required for CodeChef submit",
        )

    from .atcoder import _ensure_browser

    _ensure_browser()

    _COOKIE_PATH.parent.mkdir(parents=True, exist_ok=True)
    saved_cookies: list[dict[str, Any]] = []
    if _COOKIE_PATH.exists() and not _retried:
        try:
            saved_cookies = json.loads(_COOKIE_PATH.read_text())
        except Exception:
            pass

    logged_in = bool(saved_cookies) and not _retried
    login_error: str | None = None
    submit_error: str | None = None
    needs_relogin = False

    def check_login(page):
        nonlocal logged_in
        logged_in = page.evaluate(_CC_CHECK_LOGIN_JS)

    def login_action(page):
        nonlocal login_error
        try:
            page.locator('input[type="email"], input[name="email"]').first.fill(
                credentials.get("username", "")
            )
            page.locator('input[type="password"], input[name="password"]').first.fill(
                credentials.get("password", "")
            )
            page.locator('button[type="submit"]').first.click()
            page.wait_for_url(
                lambda url: "/login" not in url, timeout=BROWSER_NAV_TIMEOUT
            )
        except Exception as e:
            login_error = str(e)

    def submit_action(page):
        nonlocal submit_error, needs_relogin
        if "/login" in page.url:
            needs_relogin = True
            return
        try:
            selected = False
            selects = page.locator("select")
            for i in range(selects.count()):
                try:
                    sel = selects.nth(i)
                    opts = sel.locator("option").all_inner_texts()
                    match = next(
                        (o for o in opts if language_id.lower() in o.lower()), None
                    )
                    if match:
                        sel.select_option(label=match)
                        selected = True
                        break
                except Exception:
                    pass

            if not selected:
                lang_trigger = page.locator(
                    '[class*="language"] button, [data-testid*="language"] button'
                ).first
                lang_trigger.click()
                page.wait_for_timeout(500)
                page.locator(
                    f'[role="option"]:has-text("{language_id}"), '
                    f'li:has-text("{language_id}")'
                ).first.click()

            page.evaluate(
                """(code) => {
                    if (typeof monaco !== 'undefined') {
                        const models = monaco.editor.getModels();
                        if (models.length > 0) { models[0].setValue(code); return; }
                    }
                    const cm = document.querySelector('.CodeMirror');
                    if (cm && cm.CodeMirror) { cm.CodeMirror.setValue(code); return; }
                    const ta = document.querySelector('textarea');
                    if (ta) { ta.value = code; ta.dispatchEvent(new Event('input', {bubbles: true})); }
                }""",
                source_code,
            )

            page.locator(
                'button[type="submit"]:has-text("Submit"), button:has-text("Submit Code")'
            ).first.click()
            page.wait_for_url(
                lambda url: "/submit/" not in url or "submission" in url,
                timeout=BROWSER_NAV_TIMEOUT * 2,
            )
        except Exception as e:
            submit_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies if (saved_cookies and not _retried) else [],
        ) as session:
            if not logged_in:
                print(json.dumps({"status": "checking_login"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/", page_action=check_login, network_idle=True
                )

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(f"{BASE_URL}/login", page_action=login_action)
                if login_error:
                    return SubmitResult(
                        success=False, error=f"Login failed: {login_error}"
                    )

            print(json.dumps({"status": "submitting"}), flush=True)
            session.fetch(
                f"{BASE_URL}/{contest_id}/submit/{problem_id}",
                page_action=submit_action,
            )

            try:
                browser_cookies = session.context.cookies()
                if browser_cookies and logged_in:
                    _COOKIE_PATH.write_text(json.dumps(browser_cookies))
            except Exception:
                pass

        if needs_relogin and not _retried:
            _COOKIE_PATH.unlink(missing_ok=True)
            return _submit_headless_codechef(
                contest_id,
                problem_id,
                file_path,
                language_id,
                credentials,
                _retried=True,
            )

        if submit_error:
            return SubmitResult(success=False, error=submit_error)

        return SubmitResult(
            success=True, error="", submission_id="", verdict="submitted"
        )
    except Exception as e:
        return SubmitResult(success=False, error=str(e))


class CodeChefScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "codechef"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            async with httpx.AsyncClient() as client:
                data = await fetch_json(
                    client, API_CONTEST.format(contest_id=contest_id)
                )
            if not data.get("problems"):
                return self._metadata_error(
                    f"No problems found for contest {contest_id}"
                )
            problems = []
            for problem_code, problem_data in data["problems"].items():
                if problem_data.get("category_name") == "main":
                    problems.append(
                        ProblemSummary(
                            id=problem_code,
                            name=problem_data.get("name", problem_code),
                        )
                    )
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=problems,
                url=f"{BASE_URL}/{contest_id}",
            )
        except Exception as e:
            return self._metadata_error(f"Failed to fetch contest {contest_id}: {e}")

    async def scrape_contest_list(self) -> ContestListResult:
        async with httpx.AsyncClient() as client:
            try:
                data = await fetch_json(client, API_CONTESTS_ALL)
            except httpx.HTTPStatusError as e:
                return self._contests_error(f"Failed to fetch contests: {e}")
            all_contests = data.get("future_contests", []) + data.get(
                "past_contests", []
            )
            max_num = 0
            for contest in all_contests:
                contest_code = contest.get("contest_code", "")
                if contest_code.startswith("START"):
                    match = re.match(r"START(\d+)", contest_code)
                    if match:
                        num = int(match.group(1))
                        max_num = max(max_num, num)
            if max_num == 0:
                return self._contests_error("No Starters contests found")
            contests = []
            sem = asyncio.Semaphore(CONNECTIONS)

            async def fetch_divisions(i: int) -> list[ContestSummary]:
                parent_id = f"START{i}"
                async with sem:
                    try:
                        parent_data = await fetch_json(
                            client, API_CONTEST.format(contest_id=parent_id)
                        )
                    except Exception as e:
                        import sys

                        print(f"Error fetching {parent_id}: {e}", file=sys.stderr)
                        return []
                child_contests = parent_data.get("child_contests", {})
                if not child_contests:
                    return []
                base_name = f"Starters {i}"
                divisions = []
                for div_key, div_data in child_contests.items():
                    div_code = div_data.get("contest_code", "")
                    div_num = div_data.get("div", {}).get("div_number", "")
                    if div_code and div_num:
                        divisions.append(
                            ContestSummary(
                                id=div_code,
                                name=base_name,
                                display_name=f"{base_name} (Div. {div_num})",
                            )
                        )
                return divisions

            tasks = [fetch_divisions(i) for i in range(1, max_num + 1)]
            for coro in asyncio.as_completed(tasks):
                divisions = await coro
                contests.extend(divisions)
        return ContestListResult(success=True, error="", contests=contests)

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            try:
                contest_data = await fetch_json(
                    client, API_CONTEST.format(contest_id=category_id)
                )
            except Exception as e:
                print(
                    json.dumps(
                        {"error": f"Failed to fetch contest {category_id}: {str(e)}"}
                    ),
                    flush=True,
                )
                return
            all_problems = contest_data.get("problems", {})
            if not all_problems:
                print(
                    json.dumps(
                        {"error": f"No problems found for contest {category_id}"}
                    ),
                    flush=True,
                )
                return
            problems = {
                code: data
                for code, data in all_problems.items()
                if data.get("category_name") == "main"
            }
            if not problems:
                print(
                    json.dumps(
                        {"error": f"No main problems found for contest {category_id}"}
                    ),
                    flush=True,
                )
                return
            sem = asyncio.Semaphore(CONNECTIONS)

            async def run_one(problem_code: str) -> dict[str, Any]:
                async with sem:
                    try:
                        problem_data = await fetch_json(
                            client,
                            API_PROBLEM.format(
                                contest_id=category_id, problem_id=problem_code
                            ),
                        )
                        sample_tests = (
                            problem_data.get("problemComponents", {}).get(
                                "sampleTestCases", []
                            )
                            or []
                        )
                        tests = [
                            TestCase(
                                input=t.get("input", "").strip(),
                                expected=t.get("output", "").strip(),
                            )
                            for t in sample_tests
                            if not t.get("isDeleted", False)
                        ]
                        time_limit_str = problem_data.get("max_timelimit", "1")
                        timeout_ms = int(float(time_limit_str) * 1000)
                        problem_url = PROBLEM_URL.format(problem_id=problem_code)
                        loop = asyncio.get_event_loop()
                        html = await loop.run_in_executor(
                            None, _fetch_html_sync, problem_url
                        )
                        memory_mb = _extract_memory_limit(html)
                        interactive = False
                        precision = extract_precision(html)
                    except Exception:
                        tests = []
                        timeout_ms = 1000
                        memory_mb = 256.0
                        interactive = False
                        precision = None
                    combined_input = "\n".join(t.input for t in tests) if tests else ""
                    combined_expected = (
                        "\n".join(t.expected for t in tests) if tests else ""
                    )
                    return {
                        "problem_id": problem_code,
                        "combined": {
                            "input": combined_input,
                            "expected": combined_expected,
                        },
                        "tests": [
                            {"input": t.input, "expected": t.expected} for t in tests
                        ],
                        "timeout_ms": timeout_ms,
                        "memory_mb": memory_mb,
                        "interactive": interactive,
                        "multi_test": False,
                        "precision": precision,
                    }

            tasks = [run_one(problem_code) for problem_code in problems.keys()]
            for coro in asyncio.as_completed(tasks):
                payload = await coro
                print(json.dumps(payload), flush=True)

    async def submit(
        self,
        contest_id: str,
        problem_id: str,
        file_path: str,
        language_id: str,
        credentials: dict[str, str],
    ) -> SubmitResult:
        if not credentials.get("username") or not credentials.get("password"):
            return self._submit_error("Missing credentials. Use :CP codechef login")
        return await asyncio.to_thread(
            _submit_headless_codechef,
            contest_id,
            problem_id,
            file_path,
            language_id,
            credentials,
        )

    async def login(self, credentials: dict[str, str]) -> LoginResult:
        if not credentials.get("username") or not credentials.get("password"):
            return self._login_error("Missing username or password")
        return await asyncio.to_thread(_login_headless_codechef, credentials)


if __name__ == "__main__":
    CodeChefScraper().run_cli()
