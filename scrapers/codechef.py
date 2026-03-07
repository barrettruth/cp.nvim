#!/usr/bin/env python3

import asyncio
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx

from .base import (
    BaseScraper,
    clear_platform_cookies,
    load_platform_cookies,
    save_platform_cookies,
)
from .timeouts import BROWSER_SESSION_TIMEOUT, HTTP_TIMEOUT
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
API_CONTESTS_PAST = "/api/list/contests/past"
API_CONTEST = "/api/contests/{contest_id}"
API_PROBLEM = "/api/contests/{contest_id}/problems/{problem_id}"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CONNECTIONS = 8


_CC_CHECK_LOGIN_JS = "() => !!document.querySelector('a[href*=\"/users/\"]')"

_CC_LANG_IDS: dict[str, str] = {
    "C++": "42",
    "PYTH 3": "116",
    "JAVA": "10",
    "PYPY3": "109",
    "GO": "114",
    "rust": "93",
    "KTLN": "47",
    "NODEJS": "56",
    "TS": "35",
}


async def fetch_json(client: httpx.AsyncClient, path: str) -> dict[str, Any]:
    r = await client.get(BASE_URL + path, headers=HEADERS, timeout=HTTP_TIMEOUT)
    r.raise_for_status()
    return r.json()


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

    logged_in = False
    login_error: str | None = None

    def check_login(page):
        nonlocal logged_in
        logged_in = "dashboard" in page.url or page.evaluate(_CC_CHECK_LOGIN_JS)

    def login_action(page):
        nonlocal login_error
        try:
            page.locator('input[name="name"]').fill(credentials.get("username", ""))
            page.locator('input[name="pass"]').fill(credentials.get("password", ""))
            page.locator("input.cc-login-btn").click()
            try:
                page.wait_for_url(lambda url: "/login" not in url, timeout=3000)
            except Exception:
                login_error = "bad_credentials"
                return
        except Exception as e:
            login_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
        ) as session:
            print(json.dumps({"status": "logging_in"}), flush=True)
            session.fetch(f"{BASE_URL}/login", page_action=login_action)
            if login_error:
                return LoginResult(success=False, error=login_error)

            session.fetch(f"{BASE_URL}/", page_action=check_login, network_idle=True)
            if not logged_in:
                return LoginResult(
                    success=False, error="bad_credentials"
                )

            try:
                browser_cookies = session.context.cookies()
                if browser_cookies:
                    save_platform_cookies("codechef", browser_cookies)
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
    _practice: bool = False,
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

    saved_cookies: list[dict[str, Any]] = []
    if not _retried:
        saved_cookies = load_platform_cookies("codechef") or []

    logged_in = bool(saved_cookies)
    login_error: str | None = None
    submit_error: str | None = None
    needs_relogin = False

    def check_login(page):
        nonlocal logged_in
        logged_in = "dashboard" in page.url or page.evaluate(_CC_CHECK_LOGIN_JS)

    def login_action(page):
        nonlocal login_error
        try:
            page.locator('input[name="name"]').fill(credentials.get("username", ""))
            page.locator('input[name="pass"]').fill(credentials.get("password", ""))
            page.locator("input.cc-login-btn").click()
            try:
                page.wait_for_url(lambda url: "/login" not in url, timeout=3000)
            except Exception:
                login_error = "bad_credentials"
                return
        except Exception as e:
            login_error = str(e)

    def submit_action(page):
        nonlocal submit_error, needs_relogin
        if "/login" in page.url:
            needs_relogin = True
            return
        try:
            page.wait_for_selector('[aria-haspopup="listbox"]', timeout=10000)

            page.locator('[aria-haspopup="listbox"]').click()
            page.wait_for_selector('[role="option"]', timeout=5000)
            page.locator(f'[role="option"][data-value="{language_id}"]').click()
            page.wait_for_timeout(250)

            page.locator(".ace_editor").click()
            page.keyboard.press("Control+a")
            page.evaluate(
                """(code) => {
                    const textarea = document.querySelector('.ace_text-input');
                    const dt = new DataTransfer();
                    dt.setData('text/plain', code);
                    textarea.dispatchEvent(new ClipboardEvent('paste', {
                        clipboardData: dt, bubbles: true, cancelable: true
                    }));
                }""",
                source_code,
            )
            page.wait_for_timeout(125)

            page.evaluate(
                "() => document.getElementById('submit_btn').scrollIntoView({block:'center'})"
            )
            page.locator("#submit_btn").dispatch_event("click")
            try:
                page.wait_for_selector('[role="dialog"], .swal2-popup', timeout=5000)
            except Exception:
                pass

            dialog_text = page.evaluate("""() => {
                const d = document.querySelector('[role="dialog"], .swal2-popup');
                return d ? d.textContent.trim() : null;
            }""")
            if dialog_text and "login" in dialog_text.lower():
                needs_relogin = True
            elif dialog_text and (
                "not available for accepting solutions" in dialog_text
                or "not available for submission" in dialog_text
            ):
                submit_error = "PRACTICE_FALLBACK"
            elif dialog_text:
                submit_error = dialog_text
        except Exception as e:
            submit_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies if saved_cookies else [],
        ) as session:
            if not _retried and not _practice:
                print(json.dumps({"status": "checking_login"}), flush=True)
                session.fetch(f"{BASE_URL}/", page_action=check_login)

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(f"{BASE_URL}/login", page_action=login_action)
                if login_error:
                    return SubmitResult(success=False, error=login_error)
                logged_in = True

            if not _practice:
                print(json.dumps({"status": "submitting"}), flush=True)
            submit_url = (
                f"{BASE_URL}/submit/{problem_id}"
                if contest_id == "PRACTICE"
                else f"{BASE_URL}/{contest_id}/submit/{problem_id}"
            )
            session.fetch(submit_url, page_action=submit_action)

            try:
                browser_cookies = session.context.cookies()
                if browser_cookies and logged_in:
                    save_platform_cookies("codechef", browser_cookies)
            except Exception:
                pass

        if needs_relogin and not _retried:
            clear_platform_cookies("codechef")
            return _submit_headless_codechef(
                contest_id,
                problem_id,
                file_path,
                language_id,
                credentials,
                _retried=True,
            )

        if submit_error == "PRACTICE_FALLBACK" and not _practice:
            return _submit_headless_codechef(
                "PRACTICE",
                problem_id,
                file_path,
                language_id,
                credentials,
                _practice=True,
            )

        if submit_error:
            return SubmitResult(success=False, error=submit_error)

        return SubmitResult(success=True, error="", submission_id="")
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
            problems_raw = data.get("problems")
            if not problems_raw and isinstance(data.get("child_contests"), dict):
                for div in ("div_4", "div_3", "div_2", "div_1"):
                    child = data["child_contests"].get(div, {})
                    child_code = child.get("contest_code")
                    if child_code:
                        return await self.scrape_contest_metadata(child_code)
            if not problems_raw:
                return self._metadata_error(
                    f"No problems found for contest {contest_id}"
                )
            problems = []
            for problem_code, problem_data in problems_raw.items():
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
                url=f"{BASE_URL}/problems/%s",
                contest_url=f"{BASE_URL}/{contest_id}",
                standings_url=f"{BASE_URL}/{contest_id}/rankings",
            )
        except Exception as e:
            return self._metadata_error(f"Failed to fetch contest {contest_id}: {e}")

    async def scrape_contest_list(self) -> ContestListResult:
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            try:
                data = await fetch_json(client, API_CONTESTS_ALL)
            except httpx.HTTPStatusError as e:
                return self._contests_error(f"Failed to fetch contests: {e}")

            present = data.get("present_contests", [])
            future = data.get("future_contests", [])

            async def fetch_past_page(offset: int) -> list[dict[str, Any]]:
                r = await client.get(
                    BASE_URL + API_CONTESTS_PAST,
                    params={
                        "sort_by": "START",
                        "sorting_order": "desc",
                        "offset": offset,
                    },
                    headers=HEADERS,
                    timeout=HTTP_TIMEOUT,
                )
                r.raise_for_status()
                return r.json().get("contests", [])

            past: list[dict[str, Any]] = []
            offset = 0
            while True:
                page = await fetch_past_page(offset)
                past.extend(
                    c for c in page if re.match(r"^START\d+", c.get("contest_code", ""))
                )
                if len(page) < 20:
                    break
                offset += 20

            raw: list[dict[str, Any]] = []
            seen_raw: set[str] = set()
            for c in present + future + past:
                code = c.get("contest_code", "")
                if not code or code in seen_raw:
                    continue
                seen_raw.add(code)
                raw.append(c)

            sem = asyncio.Semaphore(CONNECTIONS)

            async def expand(c: dict[str, Any]) -> list[ContestSummary]:
                code = c["contest_code"]
                name = c.get("contest_name", code)
                start_time: int | None = None
                iso = c.get("contest_start_date_iso")
                if iso:
                    try:
                        start_time = int(datetime.fromisoformat(iso).timestamp())
                    except Exception:
                        pass
                base_name = re.sub(r"\s*\(.*?\)\s*$", "", name).strip()
                try:
                    async with sem:
                        detail = await fetch_json(
                            client, API_CONTEST.format(contest_id=code)
                        )
                    children = detail.get("child_contests")
                    if children and isinstance(children, dict):
                        divs: list[ContestSummary] = []
                        for div_key in ("div_1", "div_2", "div_3", "div_4"):
                            child = children.get(div_key)
                            if not child:
                                continue
                            child_code = child.get("contest_code")
                            div_num = child.get("div", {}).get(
                                "div_number", div_key[-1]
                            )
                            if child_code:
                                display = f"{base_name} (Div. {div_num})"
                                divs.append(
                                    ContestSummary(
                                        id=child_code,
                                        name=display,
                                        display_name=display,
                                        start_time=start_time,
                                    )
                                )
                        if divs:
                            return divs
                except Exception:
                    pass
                return [
                    ContestSummary(
                        id=code, name=name, display_name=name, start_time=start_time
                    )
                ]

            results = await asyncio.gather(*[expand(c) for c in raw])

        contests: list[ContestSummary] = []
        seen: set[str] = set()
        for group in results:
            for entry in group:
                if entry.id not in seen:
                    seen.add(entry.id)
                    contests.append(entry)

        if not contests:
            return self._contests_error("No contests found")
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
            if not all_problems and isinstance(
                contest_data.get("child_contests"), dict
            ):
                for div in ("div_4", "div_3", "div_2", "div_1"):
                    child = contest_data["child_contests"].get(div, {})
                    child_code = child.get("contest_code")
                    if child_code:
                        await self.stream_tests_for_category_async(child_code)
                        return
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
                        memory_mb = 256.0
                        interactive = False
                        precision = None
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
